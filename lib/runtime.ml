module Ids = Map.Make (Int)

type 'code value =
  | Integer of int32
  | Boolean of bool
  | String of string
  | Unit
  | Tuple of 'code value list
  | Variant of Core.symbol * 'code value option
  | Closure of 'code closure
  | Builtin of Core.builtin
  | Constructor_function of Core.symbol

and 'code closure = {
  parameter : Core.name;
  body : 'code;
  environment : 'code value Ids.t ref;
}

type context = {
  write : string -> unit;
  mutable constructors : bool Ids.t;
  mutable current : Ast.span;
}

let create ~write span = { write; constructors = Ids.empty; current = span }

let initialize context types builtins =
  context.constructors <-
    List.fold_left
      (fun map (definition : Core.type_decl) ->
        List.fold_left
          (fun map (constructor : Core.constructor_decl) ->
            Ids.add constructor.value.constructor_name.value.id
              (Option.is_some constructor.value.constructor_payload) map)
          map definition.value.type_constructors)
      Ids.empty types;
  List.fold_left
    (fun environment ((name : Core.name), builtin) -> Ids.add name.value.id (Builtin builtin) environment)
    Ids.empty builtins

let literal = function
  | Ast.Int value -> Integer value
  | Ast.Bool value -> Boolean value
  | Ast.String value -> String value
  | Ast.Unit -> Unit

let equal_literal literal value =
  match literal, value with
  | Ast.Int left, Integer right -> Int32.equal left right
  | Ast.Bool left, Boolean right -> Bool.equal left right
  | Ast.String left, String right -> String.equal left right
  | Ast.Unit, Unit -> true
  | _ -> false

let constructor context (name : Core.name) =
  if Ids.find name.value.id context.constructors then Constructor_function name.value
  else Variant (name.value, None)

let emit context span text =
  context.current <- span;
  try context.write text with Sys_error message -> Diagnostic.fail span ("output error: " ^ message)

let primitive context (operator : Core.primitive Ast.located) values =
  context.current <- operator.span;
  match operator.value, values with
  | Core.Negate, [ Integer value ] -> Integer (Int32.neg value)
  | Add, [ Integer left; Integer right ] -> Integer (Int32.add left right)
  | Subtract, [ Integer left; Integer right ] -> Integer (Int32.sub left right)
  | Multiply, [ Integer left; Integer right ] -> Integer (Int32.mul left right)
  | ((Core.Divide | Core.Remainder) as operation), [ Integer left; Integer right ] ->
      let name = if operation = Core.Divide then "division" else "remainder" in
      if right = 0l then Diagnostic.fail operator.span ("integer " ^ name ^ " by zero");
      if left = Int32.min_int && right = -1l then Diagnostic.fail operator.span ("integer " ^ name ^ " overflow");
      Integer (if operation = Core.Divide then Int32.div left right else Int32.rem left right)
  | Concat, [ String left; String right ] -> String (left ^ right)
  | Equal, [ Integer left; Integer right ] -> Boolean (Int32.equal left right)
  | Not_equal, [ Integer left; Integer right ] -> Boolean (not (Int32.equal left right))
  | Less, [ Integer left; Integer right ] -> Boolean (Int32.compare left right < 0)
  | Less_equal, [ Integer left; Integer right ] -> Boolean (Int32.compare left right <= 0)
  | Greater, [ Integer left; Integer right ] -> Boolean (Int32.compare left right > 0)
  | Greater_equal, [ Integer left; Integer right ] -> Boolean (Int32.compare left right >= 0)
  | _ -> assert false

let apply context span ~call callee argument =
  context.current <- span;
  match callee, argument with
  | Closure closure, argument ->
      call (Ids.add closure.parameter.value.id argument !(closure.environment)) closure.body
  | Constructor_function constructor, payload -> Variant (constructor, Some payload)
  | Builtin Core.Print_int, Integer value -> emit context span (Int32.to_string value); Unit
  | Builtin Print_string, String value -> emit context span value; Unit
  | _ -> assert false

let protect context action =
  try Ok (action ()) with
  | Diagnostic.Raised diagnostic -> Error diagnostic
  | Stack_overflow -> Error (Diagnostic.make context.current "interpreter stack exhausted")
  | Out_of_memory -> Error (Diagnostic.make context.current "interpreter allocation failed")
