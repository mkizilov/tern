open Opt_util

let rec size (source : Anf.expr) =
  match source.value with
  | Let (_, rhs, body) -> 1 + size_rhs rhs + size body
  | Let_rec _ -> 1000
  | Joins (joins, body) ->
      1 + size body
      + List.fold_left (fun n (j : Anf.join) -> n + size j.value.action) 0 joins
  | If (_, yes, no) -> 1 + size yes + size no
  | Switch (_, arms, default) ->
      1 + size default
      + List.fold_left (fun n (_, body) -> n + size body) 0 arms
  | _ -> 1

and size_rhs (rhs : Anf.rhs) =
  match rhs.value with Lambda (_, body) | Block body -> size body | _ -> 1

let clone next (parameter : Core.name) argument source =
  let fresh (name : Core.name) =
    let id = !next in
    incr next;
    { name with value = { name.value with id } }
  in
  let bind names name =
    let local = fresh name in
    (local, Ids.add name.Ast.value.id (Anf.Name local) names)
  in
  let bind_all names values =
    List.fold_left
      (fun (locals, names) name ->
        let local, names = bind names name in
        (locals @ [ local ], names))
      ([], names) values
  in
  let rec expression names (source : Anf.expr) =
    let map = atom names in
    let label name =
      match map (Anf.Name name) with Anf.Name name -> name | _ -> assert false
    in
    let value =
      match source.value with
      | Return a -> Anf.Return (map a)
      | Let (name, rhs, body) ->
          let rhs = rhs_value names rhs in
          let name, names = bind names name in
          Let (name, rhs, expression names body)
      | Let_rec (functions, body) ->
          let locals, names =
            bind_all names
              (List.map
                 (fun (f : Anf.function_binding) -> f.value.function_name)
                 functions)
          in
          let functions =
            List.map2
              (fun (f : Anf.function_binding) name ->
                let parameter, scope = bind names f.value.parameter in
                {
                  f with
                  value =
                    {
                      Anf.function_name = name;
                      parameter;
                      body = expression scope f.value.body;
                    };
                })
              functions locals
          in
          Let_rec (functions, expression names body)
      | Joins (joins, body) ->
          let locals, names =
            bind_all names
              (List.map (fun (j : Anf.join) -> j.value.label) joins)
          in
          let joins =
            List.map2
              (fun (j : Anf.join) label ->
                let parameters, scope = bind_all names j.value.parameters in
                {
                  j with
                  value =
                    {
                      Anf.label;
                      parameters;
                      action = expression scope j.value.action;
                    };
                })
              joins locals
          in
          Joins (joins, expression names body)
      | Jump (name, args) -> Jump (label name, List.map map args)
      | If (c, a, b) -> If (map c, expression names a, expression names b)
      | Switch (a, arms, default) ->
          Switch
            ( map a,
              List.map (fun (key, body) -> (key, expression names body)) arms,
              expression names default )
      | Fail message -> Fail message
    in
    { source with value }
  and rhs_value names (source : Anf.rhs) =
    match source.value with
    | Lambda (parameter, body) ->
        let parameter, names = bind names parameter in
        { source with value = Lambda (parameter, expression names body) }
    | _ -> Opt_util.rhs (atom names) (expression names) source
  in
  expression (Ids.singleton parameter.Ast.value.id argument) source

let program (source : Anf.program) =
  let next = ref source.value.next_id in
  let rec expression known (source : Anf.expr) =
    let recurse = expression known in
    let value =
      match source.value with
      | Let (name, rhs, body) ->
          let rhs = Opt_util.rhs Fun.id recurse rhs in
          let rhs =
            match rhs.value with
            | Apply (Anf.Name callee, argument) -> (
                match Ids.find_opt callee.value.id known with
                | Some (parameter, body) ->
                    {
                      rhs with
                      value = Anf.Block (clone next parameter argument body);
                    }
                | None -> rhs)
            | _ -> rhs
          in
          let known =
            match rhs.value with
            | Lambda (parameter, body) when size body <= 20 ->
                Ids.add name.value.id (parameter, body) known
            | Alias (Anf.Name original) -> (
                match Ids.find_opt original.value.id known with
                | Some body -> Ids.add name.value.id body known
                | None -> known)
            | _ -> known
          in
          Anf.Let (name, rhs, expression known body)
      | Let_rec (functions, body) ->
          Let_rec
            ( List.map
                (fun (f : Anf.function_binding) ->
                  {
                    f with
                    value = { f.value with body = recurse f.value.body };
                  })
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
      | If (c, a, b) -> If (c, recurse a, recurse b)
      | Switch (a, arms, default) ->
          Switch
            ( a,
              List.map (fun (key, body) -> (key, recurse body)) arms,
              recurse default )
      | value -> value
    in
    { source with value }
  in
  let body = expression Ids.empty source.value.body in
  { source with value = { source.value with body; next_id = !next } }
