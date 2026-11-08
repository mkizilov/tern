let name (name : Core.name) =
  Printf.sprintf "%s#%d" name.value.spelling name.value.id

let atom = function
  | Anf.Name value -> name value
  | Literal value -> Pretty.literal value

let arguments values = String.concat ", " (List.map atom values)

let key = function
  | Anf.Tag tag -> Printf.sprintf "%s#%d" tag.spelling tag.id
  | Constant value -> Pretty.literal value

let program (program : Anf.program) =
  let buffer = Buffer.create 512 in
  let line indent text =
    Buffer.add_string buffer (String.make (indent * 2) ' ' ^ text ^ "\n")
  in
  let rec expression indent (source : Anf.expr) =
    match source.value with
    | Return value -> line indent ("return " ^ atom value)
    | Let (binder, rhs, body) ->
        right_hand_side indent ("let " ^ name binder ^ " = ") rhs;
        expression indent body
    | Let_rec (functions, body) ->
        List.iter
          (fun (definition : Anf.function_binding) ->
            line indent
              ("rec "
              ^ name definition.value.function_name
              ^ "("
              ^ name definition.value.parameter
              ^ ") {");
            expression (indent + 1) definition.value.body;
            line indent "}")
          functions;
        expression indent body
    | Joins (joins, body) ->
        List.iter
          (fun (join : Anf.join) ->
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
          (fun (tag, body) ->
            line (indent + 1) (key tag ^ " => {");
            expression (indent + 2) body;
            line (indent + 1) "}")
          arms;
        line (indent + 1) "default => {";
        expression (indent + 2) default;
        line (indent + 1) "}";
        line indent "}"
    | Fail message -> line indent ("fail " ^ Printf.sprintf "%S" message)
  and right_hand_side indent prefix (source : Anf.rhs) =
    match source.value with
    | Alias value -> line indent (prefix ^ atom value)
    | Apply (callee, argument) ->
        line indent (prefix ^ "call " ^ atom callee ^ "(" ^ atom argument ^ ")")
    | Primitive (operator, values) ->
        line indent
          (prefix
          ^ Core.show_primitive operator.value
          ^ "(" ^ arguments values ^ ")")
    | Tuple values -> line indent (prefix ^ "tuple(" ^ arguments values ^ ")")
    | Constructor constructor ->
        line indent (prefix ^ "constructor " ^ name constructor)
    | Field (value, index) ->
        line indent (prefix ^ "field " ^ atom value ^ "." ^ string_of_int index)
    | Payload value -> line indent (prefix ^ "payload " ^ atom value)
    | Lambda (parameter, body) ->
        line indent (prefix ^ "fn(" ^ name parameter ^ ") {");
        expression (indent + 1) body;
        line indent "}"
    | Block body ->
        line indent (prefix ^ "block {");
        expression (indent + 1) body;
        line indent "}"
  in
  List.iter
    (fun ((binder : Core.name), _) -> line 0 ("builtin " ^ name binder))
    program.value.builtins;
  expression 0 program.value.body;
  Buffer.contents buffer
