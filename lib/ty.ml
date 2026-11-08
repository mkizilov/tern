type t =
  | Variable of variable ref
  | Arrow of t * t
  | Tuple of t list
  | Constructor of Core.symbol * t list

and variable = Unbound of int * int | Link of t | Generic of int

type context = { mutable next_id : int }
type unification_error = Mismatch | Occurs_check
exception Unification_error of unification_error

let create () = { next_id = 0 }

let fresh context level =
  let id = context.next_id in
  context.next_id <- id + 1;
  Variable (ref (Unbound (id, level)))

let generic context =
  let id = context.next_id in
  context.next_id <- id + 1;
  Variable (ref (Generic id))

let rec repr = function
  | Variable ({ contents = Link typ } as variable) ->
      let typ = repr typ in
      variable := Link typ;
      typ
  | typ -> typ

(* Linking an older variable must also move its reachable variables outward. *)
let rec occurs_and_lower variable level typ =
  match repr typ with
  | Variable other when variable == other ->
      raise (Unification_error Occurs_check)
  | Variable ({ contents = Unbound (id, other_level) } as other) ->
      if other_level > level then other := Unbound (id, level)
  | Variable { contents = Generic _ } -> raise (Unification_error Mismatch)
  | Variable { contents = Link _ } -> assert false
  | Arrow (argument, result) ->
      occurs_and_lower variable level argument;
      occurs_and_lower variable level result
  | Tuple fields | Constructor (_, fields) ->
      List.iter (occurs_and_lower variable level) fields

let rec unify expected actual =
  let expected = repr expected and actual = repr actual in
  if expected == actual then ()
  else
    match expected, actual with
    | Variable left, Variable right when left == right -> ()
    | Variable ({ contents = Unbound (_, level) } as variable), typ
    | typ, Variable ({ contents = Unbound (_, level) } as variable) ->
        occurs_and_lower variable level typ;
        variable := Link typ
    | Arrow (left_argument, left_result), Arrow (right_argument, right_result) ->
        unify left_argument right_argument;
        unify left_result right_result
    | Tuple left, Tuple right when List.length left = List.length right ->
        List.iter2 unify left right
    | Constructor (left, left_args), Constructor (right, right_args)
      when left.id = right.id && List.length left_args = List.length right_args ->
        List.iter2 unify left_args right_args
    | _ -> raise (Unification_error Mismatch)

let rec generalize level typ =
  match repr typ with
  | Variable ({ contents = Unbound (id, owner) } as variable) when owner > level ->
      variable := Generic id
  | Variable _ -> ()
  | Arrow (argument, result) ->
      generalize level argument;
      generalize level result
  | Tuple fields | Constructor (_, fields) -> List.iter (generalize level) fields

let instantiate context level scheme =
  let variables = Hashtbl.create 8 in
  let rec copy typ =
    match repr typ with
    | Variable { contents = Generic id } ->
        (match Hashtbl.find_opt variables id with
        | Some variable -> variable
        | None ->
            let variable = fresh context level in
            Hashtbl.add variables id variable;
            variable)
    | Variable _ as typ -> typ
    | Arrow (argument, result) ->
        let argument = copy argument in
        let result = copy result in
        Arrow (argument, result)
    | Tuple fields -> Tuple (List.map copy fields)
    | Constructor (name, arguments) -> Constructor (name, List.map copy arguments)
  in
  copy scheme

let format_many types =
  let variables = Hashtbl.create 8 in
  let variable id =
    match Hashtbl.find_opt variables id with
    | Some name -> name
    | None ->
        let index = Hashtbl.length variables in
        let letter = String.make 1 (Char.chr (Char.code 'a' + (index mod 26))) in
        let suffix = if index < 26 then "" else string_of_int (index / 26) in
        let name = "'" ^ letter ^ suffix in
        Hashtbl.add variables id name;
        name
  in
  let parentheses needed text = if needed then "(" ^ text ^ ")" else text in
  let rec print precedence typ =
    match repr typ with
    | Variable { contents = (Unbound (id, _) | Generic id) } -> variable id
    | Variable { contents = Link _ } -> assert false
    | Arrow (argument, result) ->
        let argument = print 1 argument in
        let result = print 0 result in
        parentheses (precedence > 0) (argument ^ " -> " ^ result)
    | Tuple fields ->
        parentheses (precedence > 1) (String.concat " * " (List.map (print 2) fields))
    | Constructor (name, []) -> name.spelling
    | Constructor (name, [ argument ]) -> print 2 argument ^ " " ^ name.spelling
    | Constructor (name, arguments) ->
        "(" ^ String.concat ", " (List.map (print 0) arguments) ^ ") " ^ name.spelling
  in
  List.map (print 0) types

let show typ = List.hd (format_many [ typ ])

let show_pair expected actual =
  match format_many [ expected; actual ] with
  | [ expected; actual ] -> expected, actual
  | _ -> assert false
