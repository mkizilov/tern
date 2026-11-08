type typ = Int | Bool | Arrow of typ * typ | Option of typ | Pair of typ * typ

type term = { typ : typ; node : node }

and node =
  | Integer of int32
  | Boolean of bool
  | Variable of int
  | Binary of string * term * term
  | Negate of term
  | Let of int * term * term
  | If of term * term * term
  | Lambda of int * typ * term
  | Apply of term * term
  | None_value
  | Some_value of term
  | Match_option of term * int * term * term
  | Tuple of term * term
  | Match_pair of term * int * int * term
  | Trace of int * term

let make typ node = { typ; node }
let name id = if id < 0 then "ignored" else "x" ^ string_of_int id

let rec expression term =
  let expr = expression in
  match term.node with
  | Integer value -> "(" ^ Int32.to_string value ^ ")"
  | Boolean value -> string_of_bool value
  | Variable id -> name id
  | Binary (op, a, b) -> "(" ^ expr a ^ " " ^ op ^ " " ^ expr b ^ ")"
  | Negate a -> "(-" ^ expr a ^ ")"
  | Let (id, a, b) -> "(let " ^ name id ^ " = " ^ expr a ^ " in " ^ expr b ^ ")"
  | If (c, a, b) ->
      "(if " ^ expr c ^ " then " ^ expr a ^ " else " ^ expr b ^ ")"
  | Lambda (id, _, body) -> "(fun " ^ name id ^ " -> " ^ expr body ^ ")"
  | Apply (f, a) -> "(" ^ expr f ^ " " ^ expr a ^ ")"
  | None_value -> "None"
  | Some_value a -> "(Some " ^ expr a ^ ")"
  | Match_option (a, id, none, some) ->
      "(match " ^ expr a ^ " with None -> " ^ expr none ^ " | Some " ^ name id
      ^ " -> " ^ expr some ^ ")"
  | Tuple (a, b) -> "(" ^ expr a ^ ", " ^ expr b ^ ")"
  | Match_pair (a, x, y, body) ->
      "(match " ^ expr a ^ " with (" ^ name x ^ ", " ^ name y ^ ") -> "
      ^ expr body ^ ")"
  | Trace (marker, body) ->
      "(print_int " ^ string_of_int marker ^ "; print_string \":\"; "
      ^ expr body ^ ")"

let source term =
  "type 'a option = None | Some of 'a;;\nlet () = print_int " ^ expression term
  ^ "; print_string \"\\n\";;\n"

let children term =
  match term.node with
  | Binary (_, a, b) | Let (_, a, b) | Apply (a, b) | Tuple (a, b) -> [ a; b ]
  | Negate a
  | Lambda (_, _, a)
  | Some_value a
  | Trace (_, a)
  | Match_pair (a, _, _, _) -> (
      match term.node with
      | Match_pair (_, _, _, body) -> [ a; body ]
      | _ -> [ a ])
  | If (a, b, c) | Match_option (a, _, b, c) -> [ a; b; c ]
  | _ -> []

let rec size term =
  1 + List.fold_left (fun total child -> total + size child) 0 (children term)

let rec cost term =
  let own =
    match term.node with
    | Integer n -> Int64.abs (Int64.of_int32 n)
    | Boolean true -> 1L
    | _ -> 0L
  in
  List.fold_left
    (fun total child -> Int64.add total (cost child))
    own (children term)

let rec features term =
  let own =
    match term.node with
    | Lambda (_, Arrow _, _) -> [ "closure"; "higher-order" ]
    | Apply (_, { typ = Arrow _; _ }) -> [ "closure"; "higher-order" ]
    | Lambda _ | Apply _ -> [ "closure" ]
    | Match_option _ | Match_pair _ -> [ "match" ]
    | Some_value _ | None_value -> [ "variant" ]
    | Let _ -> [ "let" ]
    | If _ -> [ "if" ]
    | Trace _ -> [ "effect" ]
    | _ -> []
  in
  List.sort_uniq String.compare (own @ List.concat_map features (children term))

let rec substitute id value term =
  let sub = substitute id value in
  let node =
    match term.node with
    | Variable found when found = id -> value.node
    | Binary (op, a, b) -> Binary (op, sub a, sub b)
    | Negate a -> Negate (sub a)
    | Let (bound, a, b) -> Let (bound, sub a, if bound = id then b else sub b)
    | If (a, b, c) -> If (sub a, sub b, sub c)
    | Lambda (bound, typ, body) ->
        Lambda (bound, typ, if bound = id then body else sub body)
    | Apply (f, a) -> Apply (sub f, sub a)
    | Some_value a -> Some_value (sub a)
    | Match_option (a, bound, none, some) ->
        Match_option
          (sub a, bound, sub none, if bound = id then some else sub some)
    | Tuple (a, b) -> Tuple (sub a, sub b)
    | Match_pair (a, x, y, body) ->
        Match_pair (sub a, x, y, if x = id || y = id then body else sub body)
    | Trace (marker, body) -> Trace (marker, sub body)
    | node -> node
  in
  { term with node }

let rec default = function
  | Int -> make Int (Integer 0l)
  | Bool -> make Bool (Boolean false)
  | Option typ -> make (Option typ) None_value
  | Pair (a, b) -> make (Pair (a, b)) (Tuple (default a, default b))
  | Arrow (a, b) -> make (Arrow (a, b)) (Lambda (-1, a, default b))

let rec shrink term yield =
  let candidate value =
    if value.typ = term.typ && (size value, cost value) < (size term, cost term)
    then yield value
  in
  candidate (default term.typ);
  (match term.node with
  | Integer value ->
      QCheck.Shrink.int32 value (fun value ->
          candidate (make Int (Integer value)))
  | Binary (_, a, b) ->
      candidate a;
      candidate b
  | Negate a | Trace (_, a) -> candidate a
  | If (_, a, b) ->
      candidate a;
      candidate b
  | Let (id, value, body) -> candidate (substitute id value body)
  | Apply ({ node = Lambda (id, _, body); _ }, argument) ->
      candidate (substitute id argument body)
  | Match_option ({ node = None_value; _ }, _, none, _) -> candidate none
  | Match_option ({ node = Some_value value; _ }, id, _, some) ->
      candidate (substitute id value some)
  | Match_pair ({ node = Tuple (a, b); _ }, x, y, body) ->
      candidate (substitute y b (substitute x a body))
  | _ -> ());
  let visit rebuild child =
    shrink child (fun smaller -> candidate (rebuild smaller))
  in
  match term.node with
  | Binary (op, a, b) ->
      visit (fun a -> { term with node = Binary (op, a, b) }) a;
      visit (fun b -> { term with node = Binary (op, a, b) }) b
  | Let (id, a, b) ->
      visit (fun a -> { term with node = Let (id, a, b) }) a;
      visit (fun b -> { term with node = Let (id, a, b) }) b
  | If (c, a, b) ->
      visit (fun c -> { term with node = If (c, a, b) }) c;
      visit (fun a -> { term with node = If (c, a, b) }) a;
      visit (fun b -> { term with node = If (c, a, b) }) b
  | Lambda (id, typ, body) ->
      visit (fun body -> { term with node = Lambda (id, typ, body) }) body
  | Apply (f, a) ->
      visit (fun f -> { term with node = Apply (f, a) }) f;
      visit (fun a -> { term with node = Apply (f, a) }) a
  | Negate a -> visit (fun a -> { term with node = Negate a }) a
  | Trace (marker, body) ->
      visit (fun body -> { term with node = Trace (marker, body) }) body
  | Some_value a -> visit (fun a -> { term with node = Some_value a }) a
  | Tuple (a, b) ->
      visit (fun a -> { term with node = Tuple (a, b) }) a;
      visit (fun b -> { term with node = Tuple (a, b) }) b
  | Match_option (a, id, none, some) ->
      visit (fun a -> { term with node = Match_option (a, id, none, some) }) a;
      visit
        (fun none -> { term with node = Match_option (a, id, none, some) })
        none;
      visit
        (fun some -> { term with node = Match_option (a, id, none, some) })
        some
  | Match_pair (a, x, y, body) ->
      visit (fun a -> { term with node = Match_pair (a, x, y, body) }) a;
      visit (fun body -> { term with node = Match_pair (a, x, y, body) }) body
  | _ -> ()

let generator ~variants random =
  let next = ref 0 in
  let fresh () =
    let id = !next in
    incr next;
    id
  in
  let pick values =
    List.nth values (Random.State.int random (List.length values))
  in
  let integer () =
    pick
      [
        0l;
        1l;
        -1l;
        2l;
        42l;
        Int32.min_int;
        Int32.max_int;
        Int32.of_int (Random.State.int random 2001 - 1000);
      ]
  in
  let kinds =
    [ Int; Bool; Arrow (Int, Int) ]
    @
    if variants then [ Option Int; Pair (Int, Bool); Option (Arrow (Int, Int)) ]
    else []
  in
  let rec generate env typ depth =
    let recurse typ = generate env typ (depth / 2) in
    let vars = List.filter (fun (_, t) -> t = typ) env in
    let leaf () =
      if vars <> [] && Random.State.bool random then
        make typ (Variable (fst (pick vars)))
      else
        match typ with
        | Int -> make typ (Integer (integer ()))
        | Bool -> make typ (Boolean (Random.State.bool random))
        | Option _ -> make typ None_value
        | Pair (a, b) -> make typ (Tuple (generate env a 0, generate env b 0))
        | Arrow (a, b) ->
            let id = fresh () in
            make typ
              (Lambda (id, a, generate ((id, a) :: env) b (max 0 (depth - 1))))
    in
    if depth = 0 then leaf ()
    else
      let choices =
        [
          (fun () -> leaf ());
          (fun () ->
            let binding = pick kinds in
            let id = fresh () in
            let rhs = recurse binding in
            make typ
              (Let (id, rhs, generate ((id, binding) :: env) typ (depth - 1))));
          (fun () -> make typ (If (recurse Bool, recurse typ, recurse typ)));
          (fun () ->
            let argument = pick [ Int; Bool; Arrow (Int, Int) ] in
            make typ (Apply (recurse (Arrow (argument, typ)), recurse argument)));
          (fun () -> make typ (Trace (Random.State.int random 10, recurse typ)));
        ]
      in
      let choices =
        match typ with
        | Int ->
            (fun () ->
              make Int
                (Binary (pick [ "+"; "-"; "*" ], recurse Int, recurse Int)))
            :: (fun () -> make Int (Negate (recurse Int)))
            :: choices
        | Bool ->
            (fun () ->
              make Bool
                (Binary
                   ( pick [ "="; "<>"; "<"; "<="; ">"; ">=" ],
                     recurse Int,
                     recurse Int )))
            :: choices
        | Option payload ->
            (fun () -> make typ (Some_value (recurse payload))) :: choices
        | Pair (a, b) ->
            (fun () -> make typ (Tuple (recurse a, recurse b))) :: choices
        | Arrow (a, b) ->
            (fun () ->
              let id = fresh () in
              make typ (Lambda (id, a, generate ((id, a) :: env) b (depth - 1))))
            :: choices
      in
      let choices =
        if variants then
          (fun () ->
            let payload = pick [ Int; Arrow (Int, Int); Option Int ] in
            let id = fresh () in
            make typ
              (Match_option
                 ( recurse (Option payload),
                   id,
                   recurse typ,
                   generate ((id, payload) :: env) typ (depth / 2) )))
          :: (fun () ->
            let x = fresh () and y = fresh () in
            make typ
              (Match_pair
                 ( recurse (Pair (Int, Bool)),
                   x,
                   y,
                   generate ((x, Int) :: (y, Bool) :: env) typ (depth / 2) )))
          :: choices
        else choices
      in
      pick choices ()
  in
  generate [] Int (3 + Random.State.int random 6)

let arbitrary ~variants =
  QCheck.make ~print:source ~small:size ~shrink (generator ~variants)
