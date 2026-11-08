open Tern

let%expect_test "AST nodes and names retain spans and have derived printers" =
  let start_pos : Ast.position = { line = 2; column = 3; byte_offset = 10 } in
  let end_pos : Ast.position = { line = 2; column = 4; byte_offset = 11 } in
  let span : Ast.span = { file = "ast.tern"; start_pos; end_pos } in
  let located value : _ Ast.located = { value; span } in
  let name = located "x" in
  let pattern = located (Ast.P_variable name) in
  let body = located (Ast.E_variable name) in
  let lambda = located (Ast.E_lambda (pattern, body)) in
  let binding = located { Ast.binding_pattern = pattern; binding_body = lambda } in
  let declaration = located (Ast.D_let (Ast.Recursive, [ binding ])) in
  let program = located [ declaration ] in
  let printers =
    [ Ast.show_position start_pos;
      Ast.show_span span;
      Ast.show_name name;
      Ast.show_literal (Ast.Int 42l);
      Ast.show_pattern pattern;
      Ast.show_expr lambda;
      Ast.show_binding binding;
      Ast.show_declaration declaration;
      Ast.show_program program;
      Format.asprintf "%a" Ast.pp_program program ]
  in
  assert (List.for_all (fun printed -> String.length printed > 0) printers);
  assert (program.span = declaration.span && name.span = body.span);
  Printf.printf "derived printers: %d\n" (List.length printers);
  Printf.printf "%s:%d:%d-%d:%d\n" program.span.file
    program.span.start_pos.line program.span.start_pos.column
    program.span.end_pos.line program.span.end_pos.column;
  [%expect
    {|
    derived printers: 10
    ast.tern:2:3-2:4
    |}]

let%expect_test "variant type declarations, nested patterns, and matches are located" =
  let position : Ast.position = { line = 1; column = 0; byte_offset = 0 } in
  let span : Ast.span =
    { file = "variant.tern"; start_pos = position; end_pos = position }
  in
  let located value : _ Ast.located = { value; span } in
  let name value = located value in
  let parameter = name "a" in
  let payload = located (Ast.Type_variable parameter) in
  let constructor =
    located
      { Ast.constructor_name = name "Some"; constructor_payload = Some payload }
  in
  let type_decl =
    located
      { Ast.type_name = name "option";
        type_parameters = [ parameter ];
        type_constructors = [ constructor ] }
  in
  let pattern =
    located (Ast.P_constructor (name "Some", Some (located Ast.P_wildcard)))
  in
  let literal = located (Ast.E_literal Ast.Unit) in
  let case = located { Ast.case_pattern = pattern; case_body = literal } in
  let expression = located (Ast.E_match (literal, [ case ])) in
  let declaration = located (Ast.D_type type_decl) in
  List.iter
    (fun printed -> assert (String.length printed > 0))
    [ Ast.show_type_expr payload;
      Ast.show_constructor_decl constructor;
      Ast.show_type_decl type_decl;
      Ast.show_pattern pattern;
      Ast.show_case case;
      Ast.show_expr expression;
      Ast.show_declaration declaration ];
  assert (constructor.span = parameter.span && case.span = expression.span);
  print_endline "located variant declaration and nested match; 7 derived printers";
  [%expect {| located variant declaration and nested match; 7 derived printers |}]
