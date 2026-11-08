open Runtime

type target = {
  parameters : Core.name list;
  action : Anf.expr;
  environment : Anf.expr Runtime.value Ids.t;
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
  | Anf.Literal value -> Runtime.literal value
  | Name name -> Ids.find name.value.id environment

let switch_key = function
  | Variant (tag, _) -> Anf.Tag tag
  | Integer value -> Anf.Constant (Ast.Int value)
  | Boolean value -> Anf.Constant (Ast.Bool value)
  | String value -> Anf.Constant (Ast.String value)
  | Unit -> Anf.Constant Ast.Unit
  | _ -> assert false

let rec evaluate context environment joins (source : Anf.expr) =
  context.current <- source.span;
  match source.value with
  | Anf.Return value -> atom environment value
  | Let (name, rhs, body) ->
      let value = right_hand_side context environment joins rhs in
      evaluate context (Ids.add name.value.id value environment) joins body
  | Let_rec (functions, body) ->
      let shared = ref environment in
      let environment =
        List.fold_left
          (fun environment (definition : Anf.function_binding) ->
            let definition = definition.value in
            let value =
              Closure
                {
                  parameter = definition.parameter;
                  body = definition.body;
                  environment = shared;
                }
            in
            Ids.add definition.function_name.value.id value environment)
          environment functions
      in
      shared := environment;
      evaluate context environment joins body
  | Joins (definitions, body) ->
      let joins =
        List.fold_left
          (fun joins (definition : Anf.join) ->
            let target =
              {
                parameters = definition.value.parameters;
                action = definition.value.action;
                environment;
              }
            in
            Ids.add definition.value.label.value.id target joins)
          joins definitions
      in
      evaluate context environment joins body
  | Jump (label, arguments) ->
      let target = Ids.find label.value.id joins in
      let arguments = List.map (atom environment) arguments in
      let environment =
        List.fold_left2
          (fun environment (name : Core.name) value ->
            Ids.add name.value.id value environment)
          target.environment target.parameters arguments
      in
      evaluate context environment joins target.action
  | If (condition, yes, no) -> (
      match atom environment condition with
      | Boolean true -> evaluate context environment joins yes
      | Boolean false -> evaluate context environment joins no
      | _ -> assert false)
  | Switch (subject, arms, default) ->
      let dispatch =
        List.fold_left
          (fun map (key, body) -> Keys.add key body map)
          Keys.empty arms
      in
      let selected =
        Keys.find_opt (switch_key (atom environment subject)) dispatch
      in
      evaluate context environment joins (Option.value selected ~default)
  | Fail message -> Diagnostic.fail source.span message

and right_hand_side context environment joins (source : Anf.rhs) =
  context.current <- source.span;
  match source.value with
  | Anf.Alias value -> atom environment value
  | Apply (callee, argument) ->
      Runtime.apply context source.span
        ~call:(fun environment body ->
          evaluate context environment Ids.empty body)
        (atom environment callee)
        (atom environment argument)
  | Primitive (operator, arguments) ->
      Runtime.primitive context operator (List.map (atom environment) arguments)
  | Tuple fields -> Runtime.Tuple (List.map (atom environment) fields)
  | Constructor name -> Runtime.constructor context name
  | Lambda (parameter, body) ->
      Closure { parameter; body; environment = ref environment }
  | Field (subject, index) -> (
      match atom environment subject with
      | Tuple fields -> List.nth fields index
      | _ -> assert false)
  | Payload subject -> (
      match atom environment subject with
      | Variant (_, Some payload) -> payload
      | _ -> assert false)
  | Block body -> evaluate context environment joins body

let program ~write (program : Anf.program) =
  let context = Runtime.create ~write program.span in
  Runtime.protect context (fun () ->
      let environment =
        Runtime.initialize context program.value.types program.value.builtins
      in
      match evaluate context environment Ids.empty program.value.body with
      | Unit -> ()
      | _ -> assert false)

let closed = Closed_interp.program
