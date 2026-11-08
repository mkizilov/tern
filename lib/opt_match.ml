open Opt_util

type fact =
  | Constant of Ast.literal
  | Tuple of Anf.atom list
  | Constructor of Core.name
  | Variant of Core.name * Anf.atom option

let fact values = function
  | Anf.Literal literal -> Some (Constant literal)
  | Name name -> Ids.find_opt name.value.id values

let rec expression payloads values (source : Anf.expr) =
  let recurse = expression payloads values in
  let value =
    match source.value with
    | Let (name, rhs, body) ->
        let rhs = Opt_util.rhs Fun.id recurse rhs in
        let known =
          match rhs.value with
          | Anf.Alias a -> fact values a
          | Tuple fields -> Some (Tuple fields)
          | Constructor name ->
              Some
                (if Ids.find name.value.id payloads then Constructor name
                 else Variant (name, None))
          | Apply (callee, argument) -> (
              match fact values callee with
              | Some (Constructor name) -> Some (Variant (name, Some argument))
              | _ -> None)
          | Field (a, index) -> (
              match fact values a with
              | Some (Tuple fields) -> fact values (List.nth fields index)
              | _ -> None)
          | Payload a -> (
              match fact values a with
              | Some (Variant (_, Some payload)) -> fact values payload
              | _ -> None)
          | _ -> None
        in
        let rhs =
          match rhs.value with
          | Field (a, index) -> (
              match fact values a with
              | Some (Tuple fields) ->
                  { rhs with value = Anf.Alias (List.nth fields index) }
              | _ -> rhs)
          | Payload a -> (
              match fact values a with
              | Some (Variant (_, Some payload)) ->
                  { rhs with value = Anf.Alias payload }
              | _ -> rhs)
          | _ -> rhs
        in
        let values =
          match known with
          | None -> values
          | Some known -> Ids.add name.value.id known values
        in
        Anf.Let (name, rhs, expression payloads values body)
    | Switch (subject, arms, default) -> (
        let key =
          match fact values subject with
          | Some (Variant (name, _)) -> Some (Anf.Tag name.value)
          | Some (Constant literal) -> Some (Anf.Constant literal)
          | _ -> None
        in
        match key with
        | None ->
            Switch
              ( subject,
                List.map (fun (key, body) -> (key, recurse body)) arms,
                recurse default )
        | Some key ->
            let equal candidate =
              match (key, candidate) with
              | Anf.Tag a, Anf.Tag b -> a.id = b.id
              | Anf.Constant a, Anf.Constant b -> a = b
              | _ -> false
            in
            let selected =
              List.find_opt (fun (candidate, _) -> equal candidate) arms
            in
            (recurse
               (match selected with Some (_, body) -> body | None -> default))
              .value)
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
    | If (c, yes, no) -> If (c, recurse yes, recurse no)
    | value -> value
  in
  { source with value }

let program (source : Anf.program) =
  let payloads =
    List.fold_left
      (fun map (t : Core.type_decl) ->
        List.fold_left
          (fun map (c : Core.constructor_decl) ->
            Ids.add c.value.constructor_name.value.id
              (Option.is_some c.value.constructor_payload)
              map)
          map t.value.type_constructors)
      Ids.empty source.value.types
  in
  Opt_util.program (expression payloads Ids.empty) source
