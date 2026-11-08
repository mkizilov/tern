module Names = Map.Make (Int)

let union left right = Names.union (fun _ left _ -> Some left) left right

let atom = function
  | Anf.Literal _ -> Names.empty
  | Name name -> Names.singleton name.value.id name

let atoms values =
  List.fold_left
    (fun names value -> union names (atom value))
    Names.empty values

let remove (name : Core.name) names = Names.remove name.value.id names

let remove_all names values =
  List.fold_left (fun values name -> remove name values) values names

let rec expression (source : Anf.expr) =
  match source.value with
  | Return value -> atom value
  | Let (name, rhs, body) ->
      union (right_hand_side rhs) (remove name (expression body))
  | Let_rec (functions, body) ->
      let names =
        List.map
          (fun (f : Anf.function_binding) -> f.value.function_name)
          functions
      in
      let functions =
        List.fold_left
          (fun names (f : Anf.function_binding) ->
            union names (remove f.value.parameter (expression f.value.body)))
          Names.empty functions
      in
      remove_all names (union functions (expression body))
  | Joins (joins, body) ->
      List.fold_left
        (fun names (join : Anf.join) ->
          union names
            (remove_all join.value.parameters (expression join.value.action)))
        (expression body) joins
  | Jump (_, arguments) -> atoms arguments
  | If (condition, yes, no) ->
      union (atom condition) (union (expression yes) (expression no))
  | Switch (subject, arms, default) ->
      List.fold_left
        (fun names (_, branch) -> union names (expression branch))
        (union (atom subject) (expression default))
        arms
  | Fail _ -> Names.empty

and right_hand_side (source : Anf.rhs) =
  match source.value with
  | Alias value | Payload value | Field (value, _) -> atom value
  | Apply (callee, argument) -> union (atom callee) (atom argument)
  | Primitive (_, arguments) | Tuple arguments -> atoms arguments
  | Constructor _ -> Names.empty
  | Lambda (parameter, body) -> remove parameter (expression body)
  | Block body -> expression body

let function_body parameter body =
  Names.bindings (remove parameter (expression body)) |> List.map snd
