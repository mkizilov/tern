open Runtime

type target = {
  parameters : Core.name list;
  action : Closed.expr;
  values : Closed.expr Runtime.value Ids.t;
}

module Keys = Map.Make (struct
  type t = Anf.key

  let compare left right =
    match (left, right) with
    | Anf.Tag left, Anf.Tag right -> Int.compare left.id right.id
    | Anf.Constant left, Anf.Constant right -> Stdlib.compare left right
    | Anf.Tag _, Anf.Constant _ -> -1
    | Anf.Constant _, Anf.Tag _ -> 1
end)

let atom environment = function
  | Anf.Name name -> Ids.find name.value.id environment
  | Literal literal -> Runtime.literal literal

let environment value =
  match value with Environment fields -> fields | _ -> assert false

let switch_key = function
  | Variant (tag, _) -> Anf.Tag tag
  | Integer value -> Anf.Constant (Ast.Int value)
  | Boolean value -> Anf.Constant (Ast.Bool value)
  | String value -> Anf.Constant (Ast.String value)
  | Unit -> Anf.Constant Ast.Unit
  | _ -> assert false

let rec evaluate context functions values joins callsite (source : Closed.expr)
    =
  context.current <- source.span;
  match source.value with
  | Return value -> atom values value
  | Let (name, rhs, body) ->
      let value = right_hand_side context functions values joins callsite rhs in
      evaluate context functions
        (Ids.add name.value.id value values)
        joins callsite body
  | Joins (definitions, body) ->
      let joins =
        List.fold_left
          (fun joins (join : Closed.join) ->
            Ids.add join.value.label.value.id
              {
                parameters = join.value.parameters;
                action = join.value.action;
                values;
              }
              joins)
          joins definitions
      in
      evaluate context functions values joins callsite body
  | Jump (label, arguments) ->
      let target = Ids.find label.value.id joins in
      let arguments = List.map (atom values) arguments in
      let values =
        List.fold_left2
          (fun values (name : Core.name) argument ->
            Ids.add name.value.id argument values)
          target.values target.parameters arguments
      in
      evaluate context functions values joins callsite target.action
  | If (condition, yes, no) -> (
      match atom values condition with
      | Boolean true -> evaluate context functions values joins callsite yes
      | Boolean false -> evaluate context functions values joins callsite no
      | _ -> assert false)
  | Switch (subject, arms, default) ->
      let dispatch =
        List.fold_left
          (fun map (key, body) -> Keys.add key body map)
          Keys.empty arms
      in
      let body =
        Option.value
          (Keys.find_opt (switch_key (atom values subject)) dispatch)
          ~default
      in
      evaluate context functions values joins callsite body
  | Fail message -> Diagnostic.fail source.span message

and right_hand_side context functions values joins callsite
    (source : Closed.rhs) =
  context.current <- source.span;
  match source.value with
  | Alias value -> atom values value
  | Closure_call (callee, argument) -> (
      match atom values callee with
      | Closure_record (index, fields) ->
          invoke context functions source.span index fields
            (atom values argument)
      | _ -> assert false)
  | Direct_call (index, env, argument) ->
      invoke context functions source.span index
        (environment (atom values env))
        (atom values argument)
  | Primitive (operator, arguments) ->
      Runtime.primitive context operator (List.map (atom values) arguments)
  | Tuple fields -> Runtime.Tuple (List.map (atom values) fields)
  | Variant (name, payload) ->
      Runtime.Variant (name.value, Option.map (atom values) payload)
  | Field (value, index) -> (
      match atom values value with
      | Runtime.Tuple fields -> List.nth fields index
      | _ -> assert false)
  | Payload value -> (
      match atom values value with
      | Runtime.Variant (_, Some payload) -> payload
      | _ -> assert false)
  | Block body -> evaluate context functions values joins callsite body
  | Environment fields ->
      Runtime.Environment
        (Array.of_list
           (List.map (fun value -> Some (atom values value)) fields))
  | Allocate_environment size -> Runtime.Environment (Array.make size None)
  | Environment_set (env, index, value) ->
      let fields = environment (atom values env) in
      fields.(index) <- Some (atom values value);
      Unit
  | Environment_get (env, index) -> (
      match (environment (atom values env)).(index) with
      | Some value -> value
      | None -> assert false)
  | Closure (index, env) -> Closure_record (index, environment (atom values env))
  | Closure_environment value -> (
      match atom values value with
      | Closure_record (_, fields) -> Runtime.Environment fields
      | _ -> assert false)
  | Builtin_apply (builtin, argument) ->
      Runtime.apply context callsite
        ~call:(fun _ _ -> assert false)
        (Builtin builtin) (atom values argument)

and invoke context functions span index fields argument =
  let definition : Closed.function_desc =
    (Ids.find index functions).Ast.value
  in
  let values =
    Ids.empty
    |> Ids.add definition.Closed.environment.value.id
         (Runtime.Environment fields)
    |> Ids.add definition.parameter.value.id argument
  in
  evaluate context functions values Ids.empty span definition.body

let program ~write (program : Closed.program) =
  let context = Runtime.create ~write program.span in
  Runtime.protect context (fun () ->
      ignore (Runtime.initialize context program.value.types []);
      let functions =
        List.fold_left
          (fun map (definition : Closed.function_definition) ->
            Ids.add definition.value.index definition map)
          Ids.empty program.value.functions
      in
      let values =
        List.fold_left
          (fun values ((name : Core.name), index) ->
            Ids.add name.value.id (Closure_record (index, [||])) values)
          Ids.empty program.value.builtins
      in
      match
        evaluate context functions values Ids.empty program.span
          program.value.body
      with
      | Unit -> ()
      | _ -> assert false)
