module Ids = Map.Make (Int)

type binding = { name : Core.name; scheme : Ty.t }
type result = {
  bindings : binding list;
  body_type : Ty.t;
  warnings : Diagnostic.t list;
}

type context = {
  variables : Ty.context;
  constructors : Ty.t Ids.t;
  int_type : Ty.t;
  bool_type : Ty.t;
  string_type : Ty.t;
  unit_type : Ty.t;
  mutable reported : binding list;
  mutable matches : Coverage.site list;
}

let constrain span expected actual =
  try Ty.unify expected actual with
  | Ty.Unification_error reason ->
      let expected, actual = Ty.show_pair expected actual in
      let prefix, notes =
        match reason with
        | Ty.Mismatch -> "type mismatch", []
        | Occurs_check ->
            "infinite type", [ "occurs check: a type variable would contain itself" ]
      in
      Diagnostic.fail ~notes span
        (prefix ^ ": expected " ^ expected ^ ", but got " ^ actual)

let literal context = function
  | Ast.Int _ -> context.int_type
  | Bool _ -> context.bool_type
  | String _ -> context.string_type
  | Unit -> context.unit_type

let instance context level environment (name : Core.name) =
  Ty.instantiate context.variables level (Ids.find name.value.id environment)

let rec pattern context level span (source : Core.pattern) actual : binding list =
  match source.value with
  | Core.Wildcard -> []
  | Bind name -> [ { name; scheme = actual } ]
  | Literal_pattern value -> constrain span (literal context value) actual; []
  | Tuple_pattern fields ->
      let types = List.map (fun _ -> Ty.fresh context.variables level) fields in
      constrain span (Ty.Tuple types) actual;
      List.concat (List.map2 (pattern context level span) fields types)
  | Constructor_pattern (name, payload) ->
      let signature = instance context level context.constructors name in
      (match payload, Ty.repr signature with
      | None, result -> constrain span result actual; []
      | Some payload, Ty.Arrow (argument, result) ->
          constrain span result actual;
          pattern context level span payload argument
      | _ -> assert false)

let extend environment bindings =
  List.fold_left
    (fun environment binding -> Ids.add binding.name.value.id binding.scheme environment)
    environment bindings

let publish context level top bindings =
  List.iter (fun binding -> Ty.generalize level binding.scheme) bindings;
  if top then context.reported <- List.rev_append bindings context.reported

let rec expression context environment level top (source : Core.expr) : Ty.t =
  match source.value with
  | Core.Literal value -> literal context value
  | Variable name -> instance context level environment name
  | Constructor name -> instance context level context.constructors name
  | Lambda (name, body) ->
      let argument = Ty.fresh context.variables level in
      let environment = Ids.add name.value.id argument environment in
      let result = expression context environment level false body in
      Ty.Arrow (argument, result)
  | Apply (callee, argument) ->
      let callee_type = expression context environment level false callee in
      let parameter = Ty.fresh context.variables level in
      let result = Ty.fresh context.variables level in
      constrain callee.span (Ty.Arrow (parameter, result)) callee_type;
      let actual = expression context environment level false argument in
      constrain argument.span parameter actual;
      result
  | Let (binding_pattern, rhs, body) ->
      let rhs_type = expression context environment (level + 1) false rhs in
      let bindings = pattern context (level + 1) rhs.span binding_pattern rhs_type in
      publish context level top bindings;
      expression context (extend environment bindings) level top body
  | Let_rec (group, body) ->
      let bindings =
        List.map
          (fun (binding : Core.recursive_binding) ->
            { name = binding.value.recursive_name;
              scheme = Ty.fresh context.variables (level + 1) })
          group
      in
      let recursive_environment = extend environment bindings in
      List.iter2
        (fun (binding : Core.recursive_binding) placeholder ->
          let actual =
            expression context recursive_environment (level + 1) false
              binding.value.recursive_body
          in
          constrain binding.value.recursive_body.span placeholder.scheme actual)
        group bindings;
      (* No member may become polymorphic until the whole group is checked. *)
      publish context level top bindings;
      expression context (extend environment bindings) level top body
  | If (condition, yes, no) ->
      let condition_type = expression context environment level false condition in
      constrain condition.span context.bool_type condition_type;
      let expected = expression context environment level false yes in
      let actual = expression context environment level false no in
      constrain no.span expected actual;
      expected
  | Tuple fields -> Ty.Tuple (List.map (expression context environment level false) fields)
  | Match (subject, cases) ->
      let subject_type = expression context environment level false subject in
      context.matches <- { Coverage.span = source.span; subject_type; cases } :: context.matches;
      let result = Ty.fresh context.variables level in
      List.iter
        (fun (case : Core.case) ->
          let bindings =
            pattern context level case.value.case_pattern.span
              case.value.case_pattern subject_type
          in
          let actual =
            expression context (extend environment bindings) level false case.value.case_body
          in
          constrain case.value.case_body.span result actual)
        cases;
      result
  | Primitive (operator, operands) ->
      let arguments, result =
        match operator.value with
        | Core.Negate -> [ context.int_type ], context.int_type
        | Add | Subtract | Multiply | Divide | Remainder ->
            [ context.int_type; context.int_type ], context.int_type
        | Concat -> [ context.string_type; context.string_type ], context.string_type
        | Equal | Not_equal | Less | Less_equal | Greater | Greater_equal ->
            [ context.int_type; context.int_type ], context.bool_type
      in
      List.iter2
        (fun (operand : Core.expr) expected ->
          let actual = expression context environment level false operand in
          constrain operand.span expected actual)
        operands arguments;
      result

let constructor_schemes variables declarations =
  List.fold_left
    (fun environment (declaration : Core.type_decl) ->
      let definition = declaration.value in
      let parameters =
        List.map
          (fun (name : Core.name) -> name.value.id, Ty.generic variables)
          definition.type_parameters
      in
      let parameter_map =
        List.fold_left (fun map (id, typ) -> Ids.add id typ map) Ids.empty parameters
      in
      let rec translate (source : Core.type_expr) =
        match source.value with
        | Type_variable name -> Ids.find name.value.id parameter_map
        | Type_constructor (name, arguments) ->
            Ty.Constructor (name.value, List.map translate arguments)
        | Type_arrow (argument, result) ->
            let argument = translate argument in
            let result = translate result in
            Ty.Arrow (argument, result)
        | Type_tuple fields -> Ty.Tuple (List.map translate fields)
      in
      let result = Ty.Constructor (definition.type_name.value, List.map snd parameters) in
      List.fold_left
        (fun environment (constructor : Core.constructor_decl) ->
          let scheme =
            match constructor.value.constructor_payload with
            | None -> result
            | Some payload -> Ty.Arrow (translate payload, result)
          in
          Ids.add constructor.value.constructor_name.value.id scheme environment)
        environment definition.type_constructors)
    Ids.empty declarations

let program (program : Core.program) : (result, Diagnostic.t) Stdlib.result =
  let variables = Ty.create () in
  let builtin kind =
    let name, _ = List.find (fun (_, value) -> value = kind) program.value.builtin_types in
    Ty.Constructor (name.value, [])
  in
  let context =
    { variables;
      constructors = constructor_schemes variables program.value.types;
      int_type = builtin Core.Int_type;
      bool_type = builtin Core.Bool_type;
      string_type = builtin Core.String_type;
      unit_type = builtin Core.Unit_type;
      reported = [];
      matches = [] }
  in
  let environment =
    List.fold_left
      (fun environment ((name : Core.name), builtin) ->
        let argument =
          match builtin with
          | Core.Print_int -> context.int_type
          | Print_string -> context.string_type
        in
        Ids.add name.value.id (Ty.Arrow (argument, context.unit_type)) environment)
      Ids.empty program.value.builtins
  in
  try
    let body_type = expression context environment 0 true program.value.body in
    let warnings = Coverage.check program (List.rev context.matches) in
    Ok { bindings = List.rev context.reported; body_type; warnings }
  with Diagnostic.Raised diagnostic -> Error diagnostic

let format_bindings result =
  String.concat ""
    (List.map
       (fun binding ->
         "val " ^ binding.name.value.spelling ^ " : " ^ Ty.show binding.scheme ^ "\n")
       result.bindings)
