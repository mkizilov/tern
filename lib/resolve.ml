module Names = Map.Make (String)

type type_info = { type_name : Core.name; arity : int }
type constructor_info = { constructor_name : Core.name; has_payload : bool }

type context = {
  mutable next_id : int;
  mutable types : type_info Names.t;
  mutable constructors : constructor_info Names.t;
}

let node span value : _ Ast.located = { value; span }

let fresh context (name : Ast.name) : Core.name =
  let id = context.next_id in
  context.next_id <- id + 1;
  node name.span { Core.id = id; spelling = name.value }

let reference (name : Ast.name) (definition : Core.name) : Core.name =
  node name.span definition.value

let duplicate kind (name : Ast.name) (previous : Core.name) =
  let secondary : Diagnostic.label =
    { span = previous.span; message = Some ("previous " ^ kind ^ " declaration") }
  in
  Diagnostic.fail ~secondary:[ secondary ] name.span
    ("duplicate " ^ kind ^ " `" ^ name.value ^ "`")

let lookup namespace definitions (name : Ast.name) =
  match Names.find_opt name.value definitions with
  | Some definition -> reference name definition
  | None -> Diagnostic.fail name.span ("unbound " ^ namespace ^ " `" ^ name.value ^ "`")

let constructor context (name : Ast.name) =
  match Names.find_opt name.value context.constructors with
  | Some definition -> definition
  | None -> Diagnostic.fail name.span ("unbound constructor `" ^ name.value ^ "`")

let pattern context pattern =
  let seen = ref Names.empty in
  let rec visit (pattern : Ast.pattern) : Core.pattern =
    let value =
      match pattern.value with
      | Ast.P_wildcard -> Core.Wildcard
      | P_variable name ->
          (match Names.find_opt name.value !seen with
          | Some previous -> duplicate "pattern variable" name previous
          | None -> ());
          let binder = fresh context name in
          seen := Names.add name.value binder !seen;
          Core.Bind binder
      | P_literal value -> Core.Literal_pattern value
      | P_tuple fields -> Core.Tuple_pattern (List.map visit fields)
      | P_constructor (name, payload) ->
          let definition = constructor context name in
          if definition.has_payload <> Option.is_some payload then (
            let secondary : Diagnostic.label =
              { span = definition.constructor_name.span;
                message = Some "constructor declared here" }
            in
            let expectation =
              if definition.has_payload then "expects a payload pattern" else "has no payload"
            in
            Diagnostic.fail ~secondary:[ secondary ] name.span
              ("constructor `" ^ name.value ^ "` " ^ expectation));
          let payload = Option.map visit payload in
          Core.Constructor_pattern (reference name definition.constructor_name, payload)
    in
    node pattern.span value
  in
  let pattern = visit pattern in
  pattern, !seen

let extend environment bindings = Names.fold Names.add bindings environment

let primitive = function
  | Ast.Add -> Core.Add
  | Ast.Subtract -> Core.Subtract
  | Ast.Multiply -> Core.Multiply
  | Ast.Divide -> Core.Divide
  | Ast.Remainder -> Core.Remainder
  | Ast.Concat -> Core.Concat
  | Ast.Equal -> Core.Equal
  | Ast.Not_equal -> Core.Not_equal
  | Ast.Less -> Core.Less
  | Ast.Less_equal -> Core.Less_equal
  | Ast.Greater -> Core.Greater
  | Ast.Greater_equal -> Core.Greater_equal
  | And | Or -> assert false

let rec expression context environment (source : Ast.expr) : Core.expr =
  let value =
    match source.value with
    | Ast.E_literal value -> Core.Literal value
    | E_variable name -> Core.Variable (lookup "variable" environment name)
    | E_constructor name ->
        let definition = constructor context name in
        Core.Constructor (reference name definition.constructor_name)
    | E_lambda (parameter, body) ->
        (match parameter.value with
        | P_variable name ->
            let binder = fresh context name in
            let body = expression context (Names.add name.value binder environment) body in
            Core.Lambda (binder, body)
        | _ ->
            let argument = fresh context (node parameter.span "$arg") in
            let parameter, bindings = pattern context parameter in
            let body = expression context (extend environment bindings) body in
            let body =
              match parameter.value with
              | Core.Wildcard -> body
              | _ ->
                  let argument = node argument.span (Core.Variable argument) in
                  node source.span (Core.Let (parameter, argument, body))
            in
            Core.Lambda (argument, body))
    | E_apply (callee, argument) ->
        let callee = expression context environment callee in
        let argument = expression context environment argument in
        Core.Apply (callee, argument)
    | E_let (flag, bindings, body) ->
        let environment, wrap = binding_group context environment flag bindings in
        let body = expression context environment body in
        wrap body
    | E_if (condition, yes, no) ->
        let condition = expression context environment condition in
        let yes = expression context environment yes in
        let no = expression context environment no in
        Core.If (condition, yes, no)
    | E_tuple fields ->
        Core.Tuple (List.map (expression context environment) fields)
    | E_match (subject, cases) ->
        let subject = expression context environment subject in
        let cases =
          List.map
            (fun (case : Ast.case) ->
              let case_pattern, bindings = pattern context case.value.case_pattern in
              let case_body =
                expression context (extend environment bindings) case.value.case_body
              in
              node case.span { Core.case_pattern; case_body })
            cases
        in
        Core.Match (subject, cases)
    | E_unary (operator, operand) ->
        let operand = expression context environment operand in
        let primitive = match operator.value with Ast.Negate -> Core.Negate in
        Core.Primitive (node operator.span primitive, [ operand ])
    | E_binary (operator, left, right) ->
        let left = expression context environment left in
        let right = expression context environment right in
        (match operator.value with
        | Ast.And ->
            Core.If (left, right, node operator.span (Core.Literal (Ast.Bool false)))
        | Or -> Core.If (left, node operator.span (Core.Literal (Ast.Bool true)), right)
        | operator_value ->
            Core.Primitive (node operator.span (primitive operator_value), [ left; right ]))
    | E_sequence (left, right) ->
        let left = expression context environment left in
        let right = expression context environment right in
        let unit = node left.span (Core.Literal_pattern Ast.Unit) in
        Core.Let (unit, left, right)
  in
  node source.span value

and binding_group context environment flag bindings =
  match flag, bindings with
  | Ast.Nonrecursive, [ binding ] ->
      let pattern, bound = pattern context binding.Ast.value.binding_pattern in
      let rhs = expression context environment binding.value.binding_body in
      extend environment bound, (fun body -> Core.Let (pattern, rhs, body))
  | Recursive, bindings ->
      let seen = ref Names.empty in
      let named =
        List.map
          (fun (binding : Ast.binding) ->
            let name =
              match binding.value.binding_pattern.value with
              | Ast.P_variable name -> name
              | _ -> assert false
            in
            (match Names.find_opt name.value !seen with
            | Some previous -> duplicate "recursive binding" name previous
            | None -> ());
            let binder = fresh context name in
            seen := Names.add name.value binder !seen;
            binding, binder)
          bindings
      in
      let environment = extend environment !seen in
      let bindings =
        List.map
          (fun ((binding : Ast.binding), binder) ->
            let recursive_body = expression context environment binding.value.binding_body in
            node binding.span { Core.recursive_name = binder; recursive_body })
          named
      in
      environment, (fun body -> Core.Let_rec (bindings, body))
  | Nonrecursive, _ -> assert false

let rec type_expression context parameters (typ : Ast.type_expr) : Core.type_expr =
  let value =
    match typ.value with
    | Ast.Type_variable name ->
        Core.Type_variable (lookup "type variable" parameters name)
    | Type_constructor (name, arguments) ->
        let definition =
          match Names.find_opt name.value context.types with
          | Some definition -> definition
          | None -> Diagnostic.fail name.span ("unbound type `" ^ name.value ^ "`")
        in
        if definition.arity <> List.length arguments then
          Diagnostic.fail name.span
            (Printf.sprintf "type `%s` expects %d type argument%s, but got %d"
               name.value definition.arity (if definition.arity = 1 then "" else "s")
               (List.length arguments));
        let arguments = List.map (type_expression context parameters) arguments in
        Core.Type_constructor (reference name definition.type_name, arguments)
    | Type_arrow (argument, result) ->
        let argument = type_expression context parameters argument in
        let result = type_expression context parameters result in
        Core.Type_arrow (argument, result)
    | Type_tuple fields ->
        Core.Type_tuple (List.map (type_expression context parameters) fields)
  in
  node typ.span value

let type_declaration context (declaration : Ast.type_decl) : Core.type_decl =
  let definition = declaration.value in
  (match Names.find_opt definition.type_name.value context.types with
  | Some previous -> duplicate "type name" definition.type_name previous.type_name
  | None -> ());
  let type_name = fresh context definition.type_name in
  context.types <- Names.add type_name.value.spelling
      { type_name; arity = List.length definition.type_parameters } context.types;
  let parameters = ref Names.empty in
  let type_parameters =
    List.map
      (fun (name : Ast.name) ->
        (match Names.find_opt name.value !parameters with
        | Some previous -> duplicate "type parameter" name previous
        | None -> ());
        let parameter = fresh context name in
        parameters := Names.add name.value parameter !parameters;
        parameter)
      definition.type_parameters
  in
  let type_constructors =
    List.map
      (fun (constructor : Ast.constructor_decl) ->
        let definition = constructor.value in
        let name = definition.constructor_name in
        (match Names.find_opt name.value context.constructors with
        | Some previous -> duplicate "constructor name" name previous.constructor_name
        | None -> ());
        let constructor_name = fresh context name in
        context.constructors <- Names.add name.value
            { constructor_name; has_payload = Option.is_some definition.constructor_payload }
            context.constructors;
        let constructor_payload =
          Option.map (type_expression context !parameters) definition.constructor_payload
        in
        node constructor.span { Core.constructor_name; constructor_payload })
      definition.type_constructors
  in
  node declaration.span { Core.type_name; type_parameters; type_constructors }

let program (program : Ast.program) : (Core.program, Diagnostic.t) result =
  let context = { next_id = 0; types = Names.empty; constructors = Names.empty } in
  let position : Ast.position = { line = 1; column = 0; byte_offset = 0 } in
  let builtin_span : Ast.span =
    { file = "<builtin>"; start_pos = position; end_pos = position }
  in
  let builtin_name spelling = fresh context (node builtin_span spelling) in
  let builtins =
    List.map
      (fun (spelling, value) -> builtin_name spelling, value)
      [ "print_int", Core.Print_int; "print_string", Core.Print_string ]
  in
  let builtin_types =
    List.map
      (fun (spelling, value) ->
        let name = builtin_name spelling in
        context.types <- Names.add spelling { type_name = name; arity = 0 } context.types;
        name, value)
      [ "int", Core.Int_type; "bool", Core.Bool_type;
        "string", Core.String_type; "unit", Core.Unit_type ]
  in
  let environment =
    List.fold_left
      (fun env ((name : Core.name), _) -> Names.add name.value.spelling name env)
      Names.empty builtins
  in
  let endpoint : Ast.span =
    { program.span with start_pos = program.span.end_pos }
  in
  let rec declarations environment = function
    | [] -> node endpoint (Core.Literal Ast.Unit), []
    | (declaration : Ast.declaration) :: rest ->
        (match declaration.value with
        | Ast.D_type definition ->
            let definition = type_declaration context definition in
            let body, types = declarations environment rest in
            body, definition :: types
        | D_let (flag, bindings) ->
            let environment, wrap = binding_group context environment flag bindings in
            let body, types = declarations environment rest in
            let span = { declaration.span with end_pos = body.span.end_pos } in
            node span (wrap body), types)
  in
  try
    let body, types = declarations environment program.value in
    Ok (node program.span { Core.builtins; builtin_types; types; body })
  with Diagnostic.Raised diagnostic -> Error diagnostic
