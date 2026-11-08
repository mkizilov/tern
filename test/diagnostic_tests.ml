open Tern

let source_file file source requested =
  if requested = file then Some source else None

let syntax source =
  match Parse.program ~file:"syntax.tern" source with
  | Ok _ -> failwith "expected a syntax diagnostic"
  | Error diagnostic ->
      assert (diagnostic.severity = Diagnostic.Error);
      print_string
        (Diagnostic.render ~color:false
           ~source:(source_file "syntax.tern" source)
           diagnostic)

let%expect_test "01 missing binding pattern" =
  syntax "let = 1;;";
  [%expect
    {|
    error: expected a binding pattern after `let`
     --> syntax.tern:1:5
      |
    1 | let = 1;;
      |     ^
    |}]

let%expect_test "02 missing in after a local let binding" =
  syntax "let x = let y = 1;;";
  [%expect
    {|
    error: expected `in` after let binding
     --> syntax.tern:1:18
      |
    1 | let x = let y = 1;;
      |                  ^^
    |}]

let%expect_test "03 missing then" =
  syntax "let x = if true";
  [%expect
    {|
    error: expected `then` after the condition
     --> syntax.tern:1:16
      |
    1 | let x = if true
      |                ^
    |}]

let%expect_test "04 missing else" =
  syntax "let x = if true then 1;;";
  [%expect
    {|
    error: expected `else` after the then branch
     --> syntax.tern:1:23
      |
    1 | let x = if true then 1;;
      |                       ^^
    |}]

let%expect_test "05 missing function arrow" =
  syntax "let f = fun x = x;;";
  [%expect
    {|
    error: expected `->` after function parameters
     --> syntax.tern:1:15
      |
    1 | let f = fun x = x;;
      |               ^
    |}]

let%expect_test "06 missing with" =
  syntax "let x = match y";
  [%expect
    {|
    error: expected `with` after the match subject
     --> syntax.tern:1:16
      |
    1 | let x = match y
      |                ^
    |}]

let%expect_test "07 missing match arrow" =
  syntax "let x = match y with _;;";
  [%expect
    {|
    error: expected `->` after the match pattern
     --> syntax.tern:1:23
      |
    1 | let x = match y with _;;
      |                       ^^
    |}]

let%expect_test "08 unclosed parentheses" =
  syntax "let x = (1";
  [%expect
    {|
    error: expected `)` to close the expression, or `,` for a tuple
     --> syntax.tern:1:11
      |
    1 | let x = (1
      |           ^
    |}]

let%expect_test "09 missing tuple element" =
  syntax "let x = (1,);;";
  [%expect
    {|
    error: expected a tuple element after `,`
     --> syntax.tern:1:12
      |
    1 | let x = (1,);;
      |            ^
    |}]

let%expect_test "10 missing declaration terminator" =
  syntax "let x = 1";
  [%expect
    {|
    error: expected `;;` after top-level declaration
     --> syntax.tern:1:10
      |
    1 | let x = 1
      |          ^
    |}]

let span ?(file = "primary.tern") first_line first_column last_line last_column
    =
  let start_pos : Ast.position =
    { line = first_line; column = first_column; byte_offset = 0 }
  in
  let end_pos : Ast.position =
    { line = last_line; column = last_column; byte_offset = 0 }
  in
  { Ast.file; start_pos; end_pos }

let%expect_test "unterminated lexer constructs retain opening spans and notes" =
  syntax "let x = \"hello";
  syntax "let x = (* outer (* inner *)";
  [%expect
    {|
    error: unterminated string
     --> syntax.tern:1:9
      |
    1 | let x = "hello
      |         ^
     = note: close the string with a double quote
    error: unterminated comment
     --> syntax.tern:1:9
      |
    1 | let x = (* outer (* inner *)
      |         ^^
     = note: close every nested comment with `*)`
    |}]

let%expect_test "secondary spans, optional labels, severities, and notes" =
  let diagnostic =
    Diagnostic.make ~severity:Warning
      ~secondary:
        [
          {
            Diagnostic.span = span ~file:"binding.tern" 1 4 1 5;
            message = Some "binding declared here";
          };
          { Diagnostic.span = span 1 4 1 5; message = None };
        ]
      ~notes:[ "names are resolved in lexical scope" ]
      (span 1 8 1 9) "unbound value y"
  in
  let source = function
    | "primary.tern" -> Some "let x = y;;"
    | "binding.tern" -> Some "let y = 0;;"
    | _ -> None
  in
  print_string (Diagnostic.render ~source diagnostic);
  [%expect
    {|
    warning: unbound value y
     --> primary.tern:1:9
      |
    1 | let x = y;;
      |         ^
     ::: binding.tern:1:5
      |
    1 | let y = 0;;
      |     - binding declared here
     ::: primary.tern:1:5
      |
    1 | let x = y;;
      |     -
     = note: names are resolved in lexical scope
    |}]

let%expect_test
    "multiline spans elide middle lines and honor exclusive line ends" =
  let source _ = Some "begin\nmiddle\nend\n" in
  let diagnostic = Diagnostic.make (span 1 2 4 0) "multiline example" in
  print_string (Diagnostic.render ~source diagnostic);
  [%expect
    {|
    error: multiline example
     --> primary.tern:1:3
      |
    1 | begin
      |   ^^^
      | ...
    3 | end
      | ^^^
    |}]

let%expect_test "Unicode display columns, combining characters, and tabs" =
  let line, columns = Diagnostic.display_line "\t\"é界é\" @" in
  print_endline line;
  print_endline
    (String.concat "," (Array.to_list (Array.map string_of_int columns)));
  [%expect {|
        "é界é" @
    0,4,5,6,8,9,9,10,11,12
    |}]

let%expect_test
    "malformed source bytes are safe to render with their lexer diagnostic" =
  let source = "\255" in
  match Lexer.lex ~file:"bytes.tern" source with
  | Ok _ -> assert false
  | Error diagnostic ->
      print_string
        (Diagnostic.render ~source:(source_file "bytes.tern" source) diagnostic);
      [%expect
        {|
        error: invalid UTF-8
         --> bytes.tern:1:1
          |
        1 | \xFF
          | ^^^^
         = note: source files must be valid UTF-8
        |}]

let%expect_test "terminal control sequences cannot escape source excerpts" =
  let text, _ = Diagnostic.display_line "\027[31m\000" in
  assert (not (String.contains text '\027'));
  print_endline text;
  [%expect {| \u{1b}[31m\u{0} |}]

let%expect_test
    "missing source, EOF after a newline, and out-of-range source lines" =
  print_string
    (Diagnostic.render
       ~source:(fun _ -> None)
       (Diagnostic.make ~severity:Note (span 1 0 1 0) "no source available"));
  let source _ = Some "x\n" in
  print_string
    (Diagnostic.render ~source (Diagnostic.make (span 2 0 2 0) "EOF"));
  print_string
    (Diagnostic.render ~source (Diagnostic.make (span 3 0 3 0) "missing line"));
  [%expect
    {|
    note: no source available
     --> primary.tern:1:1
     = note: source unavailable
    error: EOF
     --> primary.tern:2:1
      |
    2 |
      | ^
    error: missing line
     --> primary.tern:3:1
     = note: source line unavailable
    |}]

let%expect_test
    "color is explicit for snapshots and automatic emission respects \
     redirection" =
  let diagnostic = Diagnostic.make (span 1 0 1 1) "example" in
  let source _ = Some "x" in
  let plain = Diagnostic.render ~color:false ~source diagnostic in
  let colored = Diagnostic.render ~color:true ~source diagnostic in
  assert (not (String.contains plain '\027'));
  assert (String.starts_with ~prefix:"\027[1;31merror\027[0m" colored);
  let file = Filename.temp_file "tern-diagnostic-" ".txt" in
  Fun.protect
    ~finally:(fun () -> Sys.remove file)
    (fun () ->
      Out_channel.with_open_bin file (fun channel ->
          Diagnostic.emit ~channel ~source diagnostic);
      let actual = In_channel.with_open_bin file In_channel.input_all in
      assert (actual = plain));
  print_endline
    "plain snapshots; forced color rendering; redirected output stays plain";
  [%expect
    {| plain snapshots; forced color rendering; redirected output stays plain |}]
