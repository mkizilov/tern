let name = Ir_pretty.name
let atom = Ir_pretty.atom
let arguments = Ir_pretty.arguments

let program (program : Closed.program) =
  let buffer = Buffer.create 512 in
  let line indent text =
    Buffer.add_string buffer (String.make (2 * indent) ' ' ^ text ^ "\n")
  in
  let rec expression indent (source : Closed.expr) =
    match source.value with
    | Return value -> line indent ("return " ^ atom value)
    | Let (binder, rhs, body) ->
        right_hand_side indent ("let " ^ name binder ^ " = ") rhs;
        expression indent body
    | Joins (joins, body) ->
        List.iter
          (fun (join : Closed.join) ->
            line indent
              ("join " ^ name join.value.label ^ "("
              ^ String.concat ", " (List.map name join.value.parameters)
              ^ ") {");
            expression (indent + 1) join.value.action;
            line indent "}")
          joins;
        expression indent body
    | Jump (label, values) ->
        line indent ("jump " ^ name label ^ "(" ^ arguments values ^ ")")
    | If (condition, yes, no) ->
        line indent ("if " ^ atom condition ^ " {");
        expression (indent + 1) yes;
        line indent "} else {";
        expression (indent + 1) no;
        line indent "}"
    | Switch (subject, arms, default) ->
        let kind =
          match arms with
          | (Anf.Tag _, _) :: _ -> "switch-tag "
          | _ -> "switch-literal "
        in
        line indent (kind ^ atom subject ^ " {");
        List.iter
          (fun (key, body) ->
            line (indent + 1) (Ir_pretty.key key ^ " => {");
            expression (indent + 2) body;
            line (indent + 1) "}")
          arms;
        line (indent + 1) "default => {";
        expression (indent + 2) default;
        line (indent + 1) "}";
        line indent "}"
    | Fail message -> line indent ("fail " ^ Printf.sprintf "%S" message)
  and right_hand_side indent prefix (source : Closed.rhs) =
    let simple value = line indent (prefix ^ value) in
    match source.value with
    | Alias value -> simple (atom value)
    | Closure_call (callee, argument) ->
        simple ("call-closure " ^ atom callee ^ "(" ^ atom argument ^ ")")
    | Direct_call (index, environment, argument) ->
        simple
          (Printf.sprintf "call-direct @%d(%s, %s)" index (atom environment)
             (atom argument))
    | Primitive (operator, values) ->
        simple
          (Core.show_primitive operator.value ^ "(" ^ arguments values ^ ")")
    | Tuple fields -> simple ("tuple(" ^ arguments fields ^ ")")
    | Variant (constructor, payload) ->
        simple
          ("variant " ^ name constructor ^ "("
          ^ (match payload with None -> "" | Some value -> atom value)
          ^ ")")
    | Field (value, index) ->
        simple ("field " ^ atom value ^ "." ^ string_of_int index)
    | Payload value -> simple ("payload " ^ atom value)
    | Environment fields -> simple ("environment[" ^ arguments fields ^ "]")
    | Allocate_environment size ->
        simple ("allocate-environment " ^ string_of_int size)
    | Environment_set (environment, slot, value) ->
        simple
          (Printf.sprintf "set-environment %s[%d] = %s" (atom environment) slot
             (atom value))
    | Environment_get (environment, slot) ->
        simple (Printf.sprintf "environment %s[%d]" (atom environment) slot)
    | Closure (index, environment) ->
        simple (Printf.sprintf "closure(@%d, %s)" index (atom environment))
    | Closure_environment value -> simple ("closure-environment " ^ atom value)
    | Builtin_apply (builtin, value) ->
        simple ("builtin " ^ Core.show_builtin builtin ^ "(" ^ atom value ^ ")")
    | Block body ->
        line indent (prefix ^ "block {");
        expression (indent + 1) body;
        line indent "}"
  in
  List.iter
    (fun (definition : Closed.function_definition) ->
      let f = definition.value in
      line 0
        (Printf.sprintf "function @%d %s(%s, %s) captures [%s] layout [%s] {"
           f.index (name f.name) (name f.environment) (name f.parameter)
           (String.concat ", " (List.map name f.captures))
           (String.concat ", " (List.map name f.layout)));
      expression 1 f.body;
      line 0 "}")
    program.value.functions;
  line 0 "entry {";
  expression 1 program.value.body;
  line 0 "}";
  Buffer.contents buffer
