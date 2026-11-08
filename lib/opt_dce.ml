module Labels = Set.Make (Int)

let rec jumps (source : Anf.expr) =
  let union = Labels.union in
  match source.value with
  | Jump (label, _) -> Labels.singleton label.value.id
  | Let (_, rhs, body) ->
      let inner =
        match rhs.value with
        | Anf.Lambda (_, body) | Block body -> jumps body
        | _ -> Labels.empty
      in
      union inner (jumps body)
  | Let_rec (functions, body) ->
      List.fold_left
        (fun all (f : Anf.function_binding) -> union all (jumps f.value.body))
        (jumps body) functions
  | Joins (joins, body) ->
      List.fold_left
        (fun all (j : Anf.join) -> union all (jumps j.value.action))
        (jumps body) joins
  | If (_, yes, no) -> union (jumps yes) (jumps no)
  | Switch (_, arms, default) ->
      List.fold_left
        (fun all (_, body) -> union all (jumps body))
        (jumps default) arms
  | _ -> Labels.empty

let removable (source : Anf.rhs) =
  match source.value with
  | Alias _ | Lambda _ -> true
  | Primitive
      ( {
          value =
            ( Core.Negate | Add | Subtract | Multiply | Equal | Not_equal | Less
            | Less_equal | Greater | Greater_equal );
          _;
        },
        _ ) ->
      true
  | _ -> false

let rec expression (source : Anf.expr) =
  let value =
    match source.value with
    | Let (name, rhs, body) ->
        let body = expression body in
        let rhs = Opt_util.rhs Fun.id expression rhs in
        if
          (not (Free_vars.Names.mem name.value.id (Free_vars.expression body)))
          && removable rhs
        then body.value
        else Anf.Let (name, rhs, body)
    | Let_rec (functions, body) ->
        let body = expression body in
        let functions =
          List.map
            (fun (f : Anf.function_binding) ->
              { f with value = { f.value with body = expression f.value.body } })
            functions
        in
        let rec reachable live =
          let next =
            List.fold_left
              (fun live (f : Anf.function_binding) ->
                if Free_vars.Names.mem f.value.function_name.value.id live then
                  Free_vars.union live
                    (Free_vars.remove f.value.parameter
                       (Free_vars.expression f.value.body))
                else live)
              live functions
          in
          if Free_vars.Names.cardinal next = Free_vars.Names.cardinal live then
            live
          else reachable next
        in
        let live = reachable (Free_vars.expression body) in
        let functions =
          List.filter
            (fun (f : Anf.function_binding) ->
              Free_vars.Names.mem f.value.function_name.value.id live)
            functions
        in
        if functions = [] then body.value else Let_rec (functions, body)
    | Joins (joins, body) ->
        let body = expression body in
        let joins =
          List.map
            (fun (j : Anf.join) ->
              {
                j with
                value = { j.value with action = expression j.value.action };
              })
            joins
        in
        let rec reachable live =
          let next =
            List.fold_left
              (fun live (j : Anf.join) ->
                if Labels.mem j.value.label.value.id live then
                  Labels.union live (jumps j.value.action)
                else live)
              live joins
          in
          if Labels.equal live next then live else reachable next
        in
        let live = reachable (jumps body) in
        let joins =
          List.filter
            (fun (j : Anf.join) -> Labels.mem j.value.label.value.id live)
            joins
        in
        if joins = [] then body.value else Joins (joins, body)
    | If (c, yes, no) -> If (c, expression yes, expression no)
    | Switch (a, arms, default) ->
        Switch
          ( a,
            List.map (fun (key, body) -> (key, expression body)) arms,
            expression default )
    | value -> value
  in
  { source with value }

let program = Opt_util.program expression
