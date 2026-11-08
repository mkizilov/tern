open Opt_util

let fold (operator : Core.primitive Ast.located) arguments =
  let constants =
    List.filter_map
      (function Anf.Literal value -> Some value | _ -> None)
      arguments
  in
  if List.length constants <> List.length arguments then None
  else
    let safe =
      match (operator.value, constants) with
      | (Core.Divide | Remainder), [ Ast.Int a; Int b ] ->
          b <> 0l && not (a = Int32.min_int && b = -1l)
      | Concat, [ Ast.String a; String b ] ->
          String.length a + String.length b <= 16777215
      | _ -> true
    in
    if not safe then None
    else
      let context =
        Runtime.create ~write:(fun _ -> assert false) operator.span
      in
      match
        Runtime.primitive context operator (List.map Runtime.literal constants)
      with
      | Integer value -> Some (Ast.Int value)
      | Boolean value -> Some (Ast.Bool value)
      | String value -> Some (Ast.String value)
      | _ -> assert false

let rec expression values (source : Anf.expr) =
  let map = atom values in
  let recurse = expression values in
  let value =
    match source.value with
    | Return a -> Anf.Return (map a)
    | Let (name, rhs, body) ->
        let rhs = Opt_util.rhs map recurse rhs in
        let rhs =
          match rhs.value with
          | Block { value = Return a; _ } -> { rhs with value = Anf.Alias a }
          | Primitive (operator, arguments) -> (
              match fold operator arguments with
              | None -> rhs
              | Some literal -> { rhs with value = Alias (Literal literal) })
          | _ -> rhs
        in
        let values =
          match rhs.value with
          | Alias a -> Ids.add name.value.id a values
          | _ -> values
        in
        Let (name, rhs, expression values body)
    | Let_rec (functions, body) ->
        Let_rec
          ( List.map
              (fun (f : Anf.function_binding) ->
                { f with value = { f.value with body = recurse f.value.body } })
              functions,
            recurse body )
    | Joins (joins, body) ->
        Joins
          ( List.map
              (fun (j : Anf.join) ->
                {
                  j with
                  value = { j.value with action = recurse j.value.action };
                })
              joins,
            recurse body )
    | Jump (label, args) -> Jump (label, List.map map args)
    | If (condition, yes, no) -> (
        match map condition with
        | Literal (Ast.Bool true) -> (recurse yes).value
        | Literal (Ast.Bool false) -> (recurse no).value
        | condition -> If (condition, recurse yes, recurse no))
    | Switch (subject, arms, default) ->
        Switch
          ( map subject,
            List.map (fun (key, body) -> (key, recurse body)) arms,
            recurse default )
    | Fail message -> Fail message
  in
  { source with value }

let program = Opt_util.program (expression Ids.empty)
