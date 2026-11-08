module Ids = Map.Make (Int)

type head = Literal of Ast.literal | Tuple of int | Constructor of Core.symbol
type pattern = Any | Node of head * pattern list
type descriptor = { head : head; arguments : Ty.t list }

type catalog = {
  variants : Core.type_decl Ids.t;
  primitives : Core.builtin_type Ids.t;
}

type site = { span : Ast.span; subject_type : Ty.t; cases : Core.case list }

let catalog (program : Core.program) =
  let variants =
    List.fold_left
      (fun map (declaration : Core.type_decl) ->
        Ids.add declaration.value.type_name.value.id declaration map)
      Ids.empty program.value.types
  in
  let primitives =
    List.fold_left
      (fun map ((name : Core.name), kind) -> Ids.add name.value.id kind map)
      Ids.empty program.value.builtin_types
  in
  { variants; primitives }

let equal_head left right =
  match (left, right) with
  | Literal left, Literal right -> left = right
  | Tuple left, Tuple right -> left = right
  | Constructor left, Constructor right -> left.id = right.id
  | _ -> false

let rec normalize (source : Core.pattern) =
  match source.value with
  | Wildcard | Bind _ -> Any
  | Literal_pattern literal -> Node (Literal literal, [])
  | Tuple_pattern fields ->
      Node (Tuple (List.length fields), List.map normalize fields)
  | Constructor_pattern (name, payload) ->
      let payload =
        match payload with None -> [] | Some payload -> [ normalize payload ]
      in
      Node (Constructor name.value, payload)

let signature catalog typ =
  match Ty.repr typ with
  | Ty.Variable _ | Ty.Arrow _ -> None
  | Ty.Tuple fields ->
      Some [ { head = Tuple (List.length fields); arguments = fields } ]
  | Ty.Constructor (name, arguments) -> (
      match Ids.find_opt name.id catalog.primitives with
      | Some Core.Bool_type ->
          Some
            [
              { head = Literal (Ast.Bool false); arguments = [] };
              { head = Literal (Ast.Bool true); arguments = [] };
            ]
      | Some Unit_type -> Some [ { head = Literal Ast.Unit; arguments = [] } ]
      | Some Int_type | Some String_type -> None
      | None ->
          let definition = (Ids.find name.id catalog.variants).value in
          let parameters =
            List.fold_left2
              (fun map (name : Core.name) argument ->
                Ids.add name.value.id argument map)
              Ids.empty definition.type_parameters arguments
          in
          let rec substitute (source : Core.type_expr) =
            match source.value with
            | Type_variable name -> Ids.find name.value.id parameters
            | Type_constructor (name, arguments) ->
                Ty.Constructor (name.value, List.map substitute arguments)
            | Type_arrow (argument, result) ->
                Ty.Arrow (substitute argument, substitute result)
            | Type_tuple fields -> Ty.Tuple (List.map substitute fields)
          in
          Some
            (List.map
               (fun (constructor : Core.constructor_decl) ->
                 let arguments =
                   match constructor.value.constructor_payload with
                   | None -> []
                   | Some payload -> [ substitute payload ]
                 in
                 {
                   head = Constructor constructor.value.constructor_name.value;
                   arguments;
                 })
               definition.type_constructors))

let heads matrix =
  List.fold_left
    (fun heads row ->
      match row with
      | Node (head, _) :: _ when not (List.exists (equal_head head) heads) ->
          head :: heads
      | _ -> heads)
    [] matrix

let specialize descriptor matrix =
  List.filter_map
    (function
      | Any :: rest -> Some (List.map (fun _ -> Any) descriptor.arguments @ rest)
      | Node (head, arguments) :: rest when equal_head head descriptor.head ->
          Some (arguments @ rest)
      | _ -> None)
    matrix

let default matrix =
  List.filter_map (function Any :: rest -> Some rest | _ -> None) matrix

let argument_types catalog typ head =
  match signature catalog typ with
  | Some signature ->
      (List.find (fun descriptor -> equal_head descriptor.head head) signature)
        .arguments
  | None -> []

let missing catalog typ seen =
  match signature catalog typ with
  | Some signature ->
      let descriptor =
        List.find
          (fun descriptor ->
            not (List.exists (equal_head descriptor.head) seen))
          signature
      in
      Node (descriptor.head, List.map (fun _ -> Any) descriptor.arguments)
  | None -> (
      match Ty.repr typ with
      | Ty.Constructor (name, _) -> (
          match Ids.find_opt name.id catalog.primitives with
          | Some Core.Int_type ->
              let rec fresh value =
                let head = Literal (Ast.Int value) in
                if List.exists (equal_head head) seen then
                  fresh (Int32.succ value)
                else Node (head, [])
              in
              fresh 0l
          | Some String_type ->
              let rec fresh value =
                let head = Literal (Ast.String value) in
                if List.exists (equal_head head) seen then fresh (value ^ "x")
                else Node (head, [])
              in
              fresh ""
          | _ -> assert false)
      | _ -> Any)

let rec split count values =
  if count = 0 then ([], values)
  else
    match values with
    | first :: rest ->
        let prefix, rest = split (count - 1) rest in
        (first :: prefix, rest)
    | [] -> assert false

(* U(P, q), carrying a witness vector when q adds values not covered by P. *)
let rec useful catalog types matrix query =
  if List.exists (List.for_all (function Any -> true | _ -> false)) matrix
  then None
  else
    match (query, types) with
    | [], [] -> Some []
    | Node (head, arguments) :: rest, typ :: remaining_types ->
        let descriptor =
          { head; arguments = argument_types catalog typ head }
        in
        Option.map
          (fun witness ->
            let arguments, rest =
              split (List.length descriptor.arguments) witness
            in
            Node (head, arguments) :: rest)
          (useful catalog
             (descriptor.arguments @ remaining_types)
             (specialize descriptor matrix)
             (arguments @ rest))
    | Any :: rest, typ :: remaining_types -> (
        let seen = heads matrix in
        match signature catalog typ with
        | Some signature
          when List.for_all
                 (fun descriptor ->
                   List.exists (equal_head descriptor.head) seen)
                 signature ->
            List.find_map
              (fun descriptor ->
                let arguments = List.map (fun _ -> Any) descriptor.arguments in
                Option.map
                  (fun witness ->
                    let arguments, rest =
                      split (List.length descriptor.arguments) witness
                    in
                    Node (descriptor.head, arguments) :: rest)
                  (useful catalog
                     (descriptor.arguments @ remaining_types)
                     (specialize descriptor matrix)
                     (arguments @ rest)))
              signature
        | _ ->
            Option.map
              (fun witness -> missing catalog typ seen :: witness)
              (useful catalog remaining_types (default matrix) rest))
    | _ -> assert false

let rec show = function
  | Any -> "_"
  | Node (Literal literal, []) -> Pretty.literal literal
  | Node (Tuple _, fields) ->
      "(" ^ String.concat ", " (List.map show fields) ^ ")"
  | Node (Constructor name, []) -> name.spelling
  | Node (Constructor name, [ payload ]) ->
      let payload =
        match payload with
        | Node (Constructor _, _ :: _) -> "(" ^ show payload ^ ")"
        | _ -> show payload
      in
      name.spelling ^ " " ^ payload
  | _ -> assert false

let site catalog site =
  let matrix, redundant =
    List.fold_left
      (fun (matrix, warnings) (case : Core.case) ->
        let pattern = normalize case.value.case_pattern in
        let warnings =
          match useful catalog [ site.subject_type ] matrix [ pattern ] with
          | Some _ -> warnings
          | None ->
              Diagnostic.make ~severity:Diagnostic.Warning
                ~notes:[ "this pattern is covered by earlier cases" ]
                case.value.case_pattern.span "unreachable match case"
              :: warnings
        in
        ([ pattern ] :: matrix, warnings))
      ([], []) site.cases
  in
  let missing =
    match useful catalog [ site.subject_type ] matrix [ Any ] with
    | None -> []
    | Some [ witness ] ->
        [
          Diagnostic.make ~severity:Diagnostic.Warning
            ~notes:[ "example of an unmatched value: " ^ show witness ]
            site.span "non-exhaustive pattern match";
        ]
    | Some _ -> assert false
  in
  missing @ List.rev redundant

let check program sites =
  let catalog = catalog program in
  let warnings = List.concat (List.map (site catalog) sites) in
  List.stable_sort
    (fun (left : Diagnostic.t) (right : Diagnostic.t) ->
      let file = String.compare left.primary.file right.primary.file in
      if file <> 0 then file
      else
        Int.compare left.primary.start_pos.byte_offset
          right.primary.start_pos.byte_offset)
    warnings
