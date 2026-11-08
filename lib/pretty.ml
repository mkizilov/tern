open Ast

let string_literal value =
  let buffer = Buffer.create (String.length value + 2) in
  Buffer.add_char buffer '"';
  String.iter
    (function
      | '\n' -> Buffer.add_string buffer "\\n"
      | '\r' -> Buffer.add_string buffer "\\r"
      | '\t' -> Buffer.add_string buffer "\\t"
      | '"' -> Buffer.add_string buffer "\\\""
      | '\\' -> Buffer.add_string buffer "\\\\"
      | character -> Buffer.add_char buffer character)
    value;
  Buffer.add_char buffer '"';
  Buffer.contents buffer

let literal = function
  | Int value when value < 0l -> Printf.sprintf "(%ld)" value
  | Int value -> Int32.to_string value
  | Bool value -> string_of_bool value
  | String value -> string_literal value
  | Unit -> "()"

let rec pattern pat =
  match pat.value with
  | P_wildcard -> "_"
  | P_variable name -> name.value
  | P_literal value -> literal value
  | P_tuple fields -> "(" ^ String.concat ", " (List.map pattern fields) ^ ")"
  | P_constructor (name, None) -> name.value
  | P_constructor (name, Some payload) ->
      name.value ^ " (" ^ pattern payload ^ ")"

let operator = function
  | Add -> "+"
  | Subtract -> "-"
  | Multiply -> "*"
  | Divide -> "/"
  | Remainder -> "mod"
  | Concat -> "^"
  | Equal -> "="
  | Not_equal -> "<>"
  | Less -> "<"
  | Less_equal -> "<="
  | Greater -> ">"
  | Greater_equal -> ">="
  | And -> "&&"
  | Or -> "||"

let rec expression expr =
  match expr.value with
  | E_literal value -> literal value
  | E_variable name | E_constructor name -> name.value
  | E_lambda (parameter, body) ->
      "(fun " ^ pattern parameter ^ " -> " ^ expression body ^ ")"
  | E_apply (callee, argument) ->
      "(" ^ expression callee ^ " " ^ expression argument ^ ")"
  | E_let (flag, bindings, body) ->
      "(let " ^ binding_group flag bindings ^ " in " ^ expression body ^ ")"
  | E_if (condition, yes, no) ->
      "(if " ^ expression condition ^ " then " ^ expression yes ^ " else "
      ^ expression no ^ ")"
  | E_tuple fields ->
      "(" ^ String.concat ", " (List.map expression fields) ^ ")"
  | E_match (subject, cases) ->
      "(match " ^ expression subject ^ " with "
      ^ String.concat " " (List.map case cases)
      ^ ")"
  | E_unary (operator, operand) ->
      let symbol = match operator.value with Negate -> "-" in
      "(" ^ symbol ^ "(" ^ expression operand ^ "))"
  | E_binary (op, left, right) ->
      "(" ^ expression left ^ " " ^ operator op.value ^ " " ^ expression right
      ^ ")"
  | E_sequence (left, right) ->
      "(" ^ expression left ^ "; " ^ expression right ^ ")"

and binding binding =
  pattern binding.value.binding_pattern
  ^ " = "
  ^ expression binding.value.binding_body

and binding_group flag bindings =
  let prefix = match flag with Nonrecursive -> "" | Recursive -> "rec " in
  prefix ^ String.concat " and " (List.map binding bindings)

and case case =
  "| "
  ^ pattern case.value.case_pattern
  ^ " -> "
  ^ expression case.value.case_body

let rec type_expression typ =
  match typ.value with
  | Type_variable name -> "'" ^ name.value
  | Type_constructor (name, []) -> name.value
  | Type_constructor (name, arguments) ->
      "("
      ^ String.concat ", " (List.map type_expression arguments)
      ^ ") " ^ name.value
  | Type_arrow (argument, result) ->
      "(" ^ type_expression argument ^ " -> " ^ type_expression result ^ ")"
  | Type_tuple fields ->
      "(" ^ String.concat " * " (List.map type_expression fields) ^ ")"

let constructor constructor =
  constructor.value.constructor_name.value
  ^
  match constructor.value.constructor_payload with
  | None -> ""
  | Some payload -> " of " ^ type_expression payload

let declaration declaration =
  (match declaration.value with
    | D_let (flag, bindings) -> "let " ^ binding_group flag bindings
    | D_type definition ->
        let definition = definition.value in
        let parameters =
          List.map (fun name -> "'" ^ name.value) definition.type_parameters
        in
        let parameters =
          match parameters with
          | [] -> ""
          | [ parameter ] -> parameter ^ " "
          | parameters -> "(" ^ String.concat ", " parameters ^ ") "
        in
        "type " ^ parameters ^ definition.type_name.value ^ " = "
        ^ String.concat " | "
            (List.map constructor definition.type_constructors))
  ^ ";;"

let program program =
  match program.value with
  | [] -> ""
  | declarations ->
      String.concat "\n" (List.map declaration declarations) ^ "\n"
