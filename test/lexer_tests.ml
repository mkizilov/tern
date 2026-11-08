open Tern

let token_label = function
  | Token.Identifier name -> Printf.sprintf "Identifier(%s)" name
  | Constructor name -> Printf.sprintf "Constructor(%s)" name
  | Type_variable name -> Printf.sprintf "Type_variable(%s)" name
  | Integer value -> Printf.sprintf "Integer(%Ld)" value
  | String value -> Printf.sprintf "String(%S)" value
  | token -> Token.show_kind token

let print_span (span : Ast.span) =
  Printf.printf "%s:%d:%d-%d:%d bytes=%d-%d" span.file
    span.start_pos.line span.start_pos.column span.end_pos.line
    span.end_pos.column span.start_pos.byte_offset span.end_pos.byte_offset

let print_error (error : Lexer.error) =
  let message =
    match error.kind with
    | Unterminated_string -> "unterminated string"
    | Unterminated_comment -> "unterminated comment"
    | Invalid_escape escape -> Printf.sprintf "invalid escape %S" escape
    | Control_character code -> Printf.sprintf "control character U+%04X" code
    | Invalid_character character -> Printf.sprintf "invalid character %S" character
    | Integer_out_of_range -> "integer out of range"
    | Invalid_utf8 -> "invalid UTF-8"
  in
  Printf.printf "%s at " message;
  print_span error.span;
  print_newline ()

let dump ?(positions = false) source =
  match Lexer.lex ~file:"test.tern" source with
  | Error error -> print_error error
  | Ok tokens ->
      List.iter
        (fun (token : Token.t) ->
          print_string (token_label token.value);
          if positions then (
            print_string " at ";
            print_span token.span);
          print_newline ())
        tokens

let%expect_test "every keyword, payload, punctuation, operator, and EOF" =
  dump
    {|let rec and in fun if then else type of match with true false mod
hello _x x2 x' Hello Some 'a '_item _ 0 42 "hello" ""
( ) , ; ;; -> | + - * / ^ = <> < <= > >= && |||};
  [%expect
    {|
    Let
    Rec
    And
    In
    Fun
    If
    Then
    Else
    Type
    Of
    Match
    With
    True
    False
    Mod
    Identifier(hello)
    Identifier(_x)
    Identifier(x2)
    Identifier(x')
    Constructor(Hello)
    Constructor(Some)
    Type_variable(a)
    Type_variable(_item)
    Underscore
    Integer(0)
    Integer(42)
    String("hello")
    String("")
    Lparen
    Rparen
    Comma
    Semicolon
    Double_semicolon
    Arrow
    Bar
    Plus
    Minus
    Star
    Slash
    Caret
    Equal
    Not_equal
    Less
    Less_equal
    Greater
    Greater_equal
    And_and
    Or_or
    Eof
    |}]

let%expect_test "maximal munch, keyword prefixes, subtraction, and unit" =
  dump "letter let' rec2 _ _name x-1 x - 1 (-1) () ;;; <=<>->&&|||";
  [%expect
    {|
    Identifier(letter)
    Identifier(let')
    Identifier(rec2)
    Underscore
    Identifier(_name)
    Identifier(x)
    Minus
    Integer(1)
    Identifier(x)
    Minus
    Integer(1)
    Lparen
    Minus
    Integer(1)
    Rparen
    Lparen
    Rparen
    Double_semicolon
    Semicolon
    Less_equal
    Not_equal
    Arrow
    And_and
    Or_or
    Bar
    Eof
    |}]

let%expect_test "positions are half-open and include file and byte offsets" =
  dump ~positions:true "let x = 1\n  x + 2;;\n";
  [%expect
    {|
    Let at test.tern:1:0-1:3 bytes=0-3
    Identifier(x) at test.tern:1:4-1:5 bytes=4-5
    Equal at test.tern:1:6-1:7 bytes=6-7
    Integer(1) at test.tern:1:8-1:9 bytes=8-9
    Identifier(x) at test.tern:2:2-2:3 bytes=12-13
    Plus at test.tern:2:4-2:5 bytes=14-15
    Integer(2) at test.tern:2:6-2:7 bytes=16-17
    Double_semicolon at test.tern:2:7-2:9 bytes=17-19
    Eof at test.tern:3:0-3:0 bytes=20-20
    |}]

let%expect_test "CRLF, lone CR, LF, tabs, and whitespace at EOF" =
  dump ~positions:true "a\r\n\tb\rc\nd \011\012";
  [%expect
    {|
    Identifier(a) at test.tern:1:0-1:1 bytes=0-1
    Identifier(b) at test.tern:2:1-2:2 bytes=4-5
    Identifier(c) at test.tern:3:0-3:1 bytes=6-7
    Identifier(d) at test.tern:4:0-4:1 bytes=8-9
    Eof at test.tern:4:4-4:4 bytes=12-12
    |}]

let%expect_test "nested comments preserve multiline positions" =
  dump ~positions:true "x(* outer\n(* inner *)\n*)y";
  [%expect
    {|
    Identifier(x) at test.tern:1:0-1:1 bytes=0-1
    Identifier(y) at test.tern:3:2-3:3 bytes=24-25
    Eof at test.tern:3:3-3:3 bytes=25-25
    |}]

let%expect_test "comment contents are not strings or tokens" =
  dump "(**)(* \" \\ @ (* nested *) \" *)(**)let";
  dump ~positions:true "(*\r\n nested\r *)x";
  [%expect
    {|
    Let
    Eof
    Identifier(x) at test.tern:3:3-3:4 bytes=15-16
    Eof at test.tern:3:4-3:4 bytes=16-16
    |}]

let%expect_test "all string escapes decode; delimiters in strings stay literal" =
  dump {|"\n\r\t\"\\" "(* not a comment *)"|};
  dump ~positions:true {|"a\nb" x|};
  [%expect
    {|
    String("\n\r\t\"\\")
    String("(* not a comment *)")
    Eof
    String("a\nb") at test.tern:1:0-1:6 bytes=0-6
    Identifier(x) at test.tern:1:7-1:8 bytes=7-8
    Eof at test.tern:1:8-1:8 bytes=8-8
    |}]

let%expect_test "UTF-8 columns count scalars rather than bytes" =
  dump ~positions:true "\"é🦅\" x\n(* é *)y";
  [%expect
    {|
    String("\195\169\240\159\166\133") at test.tern:1:0-1:4 bytes=0-8
    Identifier(x) at test.tern:1:5-1:6 bytes=9-10
    Identifier(y) at test.tern:2:7-2:8 bytes=19-20
    Eof at test.tern:2:8-2:8 bytes=20-20
    |}]

let%expect_test "unterminated strings point to the opening quote" =
  dump "let x =\n  \"unfinished";
  dump "\n\"unfinished\\";
  [%expect
    {|
    unterminated string at test.tern:2:2-2:3 bytes=10-11
    unterminated string at test.tern:2:0-2:1 bytes=1-2
    |}]

let%expect_test "unterminated nested comments point to the outer opener" =
  dump "x\n  (* outer\n (* inner *)";
  dump "(* outer (* inner";
  [%expect
    {|
    unterminated comment at test.tern:2:2-2:4 bytes=4-6
    unterminated comment at test.tern:1:0-1:2 bytes=0-2
    |}]

let%expect_test "invalid escapes highlight the backslash and following scalar" =
  dump "\n  \"a\\q\"";
  dump "\"\\é\"";
  dump "\"\\\n\"";
  [%expect
    {|
    invalid escape "\\q" at test.tern:2:4-2:6 bytes=5-7
    invalid escape "\\\195\169" at test.tern:1:1-1:3 bytes=1-4
    invalid escape "\\\n" at test.tern:1:1-2:0 bytes=1-3
    |}]

let%expect_test "raw control characters are not allowed in strings" =
  List.iter dump
    [ "\"a\nb\""; "\"\t\""; "\"\r\""; "\"\000\""; "\"\127\""; "\"\194\133\"" ];
  [%expect
    {|
    control character U+000A at test.tern:1:2-2:0 bytes=2-3
    control character U+0009 at test.tern:1:1-1:2 bytes=1-2
    control character U+000D at test.tern:1:1-2:0 bytes=1-2
    control character U+0000 at test.tern:1:1-1:2 bytes=1-2
    control character U+007F at test.tern:1:1-1:2 bytes=1-2
    control character U+0085 at test.tern:1:1-1:2 bytes=1-3
    |}]

let%expect_test "invalid characters have exact locations" =
  List.iter dump [ "let x =\n  @"; "&"; ":"; "'"; "é"; "\000" ];
  [%expect
    {|
    invalid character "@" at test.tern:2:2-2:3 bytes=10-11
    invalid character "&" at test.tern:1:0-1:1 bytes=0-1
    invalid character ":" at test.tern:1:0-1:1 bytes=0-1
    invalid character "'" at test.tern:1:0-1:1 bytes=0-1
    invalid character "\195\169" at test.tern:1:0-1:1 bytes=0-2
    invalid character "\000" at test.tern:1:0-1:1 bytes=0-1
    |}]

let%expect_test "integer magnitudes are bounded without host integer overflow" =
  dump "00042 2147483647 -2147483648";
  List.iter dump [ "2147483649"; "999999999999999999999999999999" ];
  dump (String.make 1000 '0' ^ "1");
  [%expect
    {|
    Integer(42)
    Integer(2147483647)
    Minus
    Integer(2147483648)
    Eof
    integer out of range at test.tern:1:0-1:10 bytes=0-10
    integer out of range at test.tern:1:0-1:30 bytes=0-30
    Integer(1)
    Eof
    |}]

let%expect_test "malformed UTF-8 is a located error, including in comments" =
  List.iter dump [ "\n \255"; "\"é\"\r\n(*\237\160\128*)"; "\240\159" ];
  [%expect
    {|
    invalid UTF-8 at test.tern:2:1-2:2 bytes=2-3
    invalid UTF-8 at test.tern:2:2-2:3 bytes=8-9
    invalid UTF-8 at test.tern:1:0-1:1 bytes=0-1
    |}]

let%expect_test "empty input and incremental calls give stable EOF spans" =
  dump ~positions:true "";
  let lexer = Lexer.create ~file:"empty.tern" "" in
  let first = Lexer.next lexer in
  let second = Lexer.next lexer in
  assert (first = second);
  print_span second.span;
  print_newline ();
  [%expect
    {|
    Eof at test.tern:1:0-1:0 bytes=0-0
    empty.tern:1:0-1:0 bytes=0-0
    |}]

let%expect_test "long lexemes and skipped comments survive Sedlex refills" =
  let name = String.make 2000 'x' in
  let source =
    "(*" ^ String.make 3000 ' ' ^ "\n*)" ^ name ^ " \"" ^ name ^ "\""
  in
  match Lexer.lex ~file:"long.tern" source with
  | Error error -> print_error error
  | Ok [ identifier; string; eof ] ->
      assert (identifier.value = Token.Identifier name);
      assert (string.value = Token.String name);
      List.iter
        (fun (token : Token.t) -> print_span token.span; print_newline ())
        [ identifier; string; eof ];
      [%expect
        {|
        long.tern:2:2-2:2002 bytes=3005-5005
        long.tern:2:2003-2:4005 bytes=5006-7008
        long.tern:2:4005-2:4005 bytes=7008-7008
        |}]
  | Ok _ -> assert false

let%expect_test "the complete example corpus lexes without errors" =
  let directory = "../examples" in
  let files =
    Sys.readdir directory |> Array.to_list
    |> List.filter (fun name -> Filename.extension name = ".tern")
    |> List.sort String.compare
  in
  assert (List.length files = 15);
  List.iter
    (fun name ->
      let path = Filename.concat directory name in
      let source = In_channel.with_open_bin path In_channel.input_all in
      match Lexer.lex ~file:name source with
      | Error error -> print_error error; assert false
      | Ok tokens ->
          assert (List.length tokens > 1);
          assert ((List.hd (List.rev tokens)).value = Token.Eof))
    files;
  Printf.printf "lexed %d example files\n" (List.length files);
  [%expect {| lexed 15 example files |}]
