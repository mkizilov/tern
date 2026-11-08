open Tern

let parse ?(file = "parse.tern") source =
  match Parse.program ~file source with
  | Ok program -> program
  | Error error -> failwith (Parse.show_error error)

let print source = print_string (Pretty.program (parse source))

let only_body source =
  match (parse source).value with
  | [ { value = Ast.D_let (_, [ binding ]); _ } ] -> binding.value.binding_body
  | _ -> assert false

let print_error source =
  match Parse.program ~file:"error.tern" source with
  | Ok _ -> print_endline "unexpected success"
  | Error error ->
      assert (error.severity = Diagnostic.Error);
      Printf.printf "%s at %d:%d-%d:%d\n" error.message
        error.primary.start_pos.line error.primary.start_pos.column
        error.primary.end_pos.line error.primary.end_pos.column

let round_trip source =
  let original = parse ~file:"original.tern" source in
  let printed = Pretty.program original in
  let reparsed = parse ~file:"printed.tern" printed in
  assert (Ast.equal_program original reparsed);
  assert (original <> reparsed);
  printed

let%expect_test "operator precedence, associativity, application, and negation"
    =
  print "let x = 1 + 2 * 3 - 4 / 2;;";
  print "let x = f a b + g (-2);;";
  print "let x = -f x;;";
  print "let x = 9 - 3 - 1;;";
  print {|let x = "a" ^ "b" ^ "c";;|};
  print "let x = true || false && true;;";
  print "let x = a; b; c;;";
  [%expect
    {|
    let x = ((1 + (2 * 3)) - (4 / 2));;
    let x = (((f a) b) + (g (-2)));;
    let x = (-((f x)));;
    let x = ((9 - 3) - 1);;
    let x = ("a" ^ ("b" ^ "c"));;
    let x = (true || (false && true));;
    let x = (a; (b; c));;
    |}]

let%expect_test "control bodies consume operators and sequencing to the right" =
  print "let x = if true then 1 else 2; 3;;";
  print "let x = (if true then 1 else 2); 3;;";
  print "let x = 1 + if true then 2 else 3;;";
  print "let f = fun x -> x + 1;;";
  print "let x = let y = 1 in y + 2;;";
  [%expect
    {|
    let x = (if true then 1 else (2; 3));;
    let x = ((if true then 1 else 2); 3);;
    let x = (1 + (if true then 2 else 3));;
    let f = (fun x -> (x + 1));;
    let x = (let y = 1 in (y + 2));;
    |}]

let%expect_test "nested matches bind a bare bar to the innermost match" =
  let inspect source =
    match (only_body source).value with
    | Ast.E_match (_, first :: rest) -> (
        match first.value.case_body.value with
        | E_match (_, inner) ->
            Printf.printf "outer arms=%d inner arms=%d\n"
              (1 + List.length rest)
              (List.length inner)
        | _ -> assert false)
    | _ -> assert false
  in
  inspect "let x = match a with A -> match b with B -> 1 | C -> 2;;";
  inspect "let x = match a with A -> (match b with B -> 1) | C -> 2;;";
  inspect "let x = match a with A -> match b with B -> 1 | C -> 2 | D -> 3;;";
  [%expect
    {|
    outer arms=1 inner arms=2
    outer arms=2 inner arms=1
    outer arms=1 inner arms=3
    |}]

let%expect_test "if branches, nested let, and local mutual recursion" =
  print "let x = if a then if b then 1 else 2 else 3;;";
  print "let x = let rec f n = g n and g n = n in f 1;;";
  print "let f (a, b) () = a;;";
  [%expect
    {|
    let x = (if a then (if b then 1 else 2) else 3);;
    let x = (let rec f = (fun n -> (g n)) and g = (fun n -> n) in (f 1));;
    let f = (fun (a, b) -> (fun () -> a));;
    |}]

let%expect_test "tuple and nested constructor patterns, wildcard and literals" =
  print
    {|let f x = match x with
      | Some (Cons ((-1, true), _)) -> (1, "yes")
      | Some _ -> (2, "other")
      | None -> (3, "none");;|};
  print {|let f x = match x with "yes" -> true | _ -> false;;|};
  print "let f x = match x with () -> ();;";
  [%expect
    {|
    let f = (fun x -> (match x with | Some (Cons ((((-1), true), _))) -> (1, "yes") | Some (_) -> (2, "other") | None -> (3, "none")));;
    let f = (fun x -> (match x with | "yes" -> true | _ -> false));;
    let f = (fun x -> (match x with | () -> ()));;
    |}]

let%expect_test "parametric variants, postfix types, products, and right arrows"
    =
  print "type 'a list = Nil | Cons of ('a * 'a list);;";
  print "type ('a, 'b) result = | Ok of 'a | Error of 'b;;";
  print "type 'a fn = F of int -> 'a * bool -> string;;";
  print "type 'a nested = N of ('a, int) result list;;";
  [%expect
    {|
    type 'a list = Nil | Cons of ('a * ('a) list);;
    type ('a, 'b) result = Ok of 'a | Error of 'b;;
    type 'a fn = F of (int -> (('a * bool) -> string));;
    type 'a nested = N of (('a, int) result) list;;
    |}]

let%expect_test "minimum integers and unary AST nodes survive printing" =
  List.iter
    (fun source -> print_string (round_trip source))
    [
      "let x = -2147483648;;";
      "let x = -1;;";
      "let x = -(1);;";
      "let x = --1;;";
      "let f x = match x with -2147483648 -> 1 | _ -> 0;;";
    ];
  [%expect
    {|
    let x = (-2147483648);;
    let x = (-1);;
    let x = (-(1));;
    let x = (-((-1)));;
    let f = (fun x -> (match x with | (-2147483648) -> 1 | _ -> 0));;
    |}]

let%expect_test "strings print only Tern escapes, preserving raw UTF-8" =
  print_string (round_trip {|let x = "é\n\r\t\"\\";;|});
  [%expect {| let x = "é\n\r\t\"\\";; |}]

let%expect_test "all syntax data participates in equality, but no spans do" =
  let first = parse ~file:"one.tern" "let x = fun y -> y + 1;;" in
  let same = parse ~file:"two.tern" "\nlet x = (fun y -> (y + 1));;\n" in
  let changed = parse "let x = fun y -> y + 2;;" in
  Printf.printf "same syntax=%b changed literal=%b spans differ=%b\n"
    (Ast.equal_program first same)
    (Ast.equal_program first changed)
    (first.span <> same.span);
  [%expect {| same syntax=true changed literal=false spans differ=true |}]

let%expect_test
    "located nodes include keyword delimiters and exact Unicode bytes" =
  let program = parse ~file:"unicode.tern" "let x = \"é\";;\n" in
  let show label (span : Ast.span) =
    Printf.printf "%s %s:%d:%d-%d:%d bytes=%d-%d\n" label span.file
      span.start_pos.line span.start_pos.column span.end_pos.line
      span.end_pos.column span.start_pos.byte_offset span.end_pos.byte_offset
  in
  show "program" program.span;
  (match program.value with
  | [ { value = Ast.D_let (_, [ binding ]); span } ] ->
      show "declaration" span;
      show "binding" binding.span;
      show "pattern" binding.value.binding_pattern.span;
      show "body" binding.value.binding_body.span
  | _ -> assert false);
  [%expect
    {|
    program unicode.tern:1:0-2:0 bytes=0-15
    declaration unicode.tern:1:0-1:13 bytes=0-14
    binding unicode.tern:1:4-1:11 bytes=4-12
    pattern unicode.tern:1:4-1:5 bytes=4-5
    body unicode.tern:1:8-1:11 bytes=8-12
    |}]

let%expect_test "syntax, range, and recursive-binding errors have locations" =
  List.iter print_error
    [
      "let x = 1";
      "let x = if true then 1;;";
      "let x = 1 < 2 < 3;;";
      "let x = 2147483648;;";
      "let x = -(2147483648);;";
      "let rec x = 1;;";
      "let x = 1 and y = 2;;";
      "let x =\n @;;";
    ];
  [%expect
    {|
    expected `;;` after top-level declaration at 1:9-1:9
    expected `else` after the then branch at 1:22-1:24
    comparison operators do not chain; parenthesize each comparison at 1:14-1:15
    positive integer literal exceeds 2147483647 at 1:8-1:18
    positive integer literal exceeds 2147483647 at 1:10-1:20
    recursive bindings require a name and a function at 1:8-1:13
    `and` requires a recursive binding group; use `let rec ... and ...` at 1:10-1:13
    invalid character "@" at 2:1-2:2
    |}]

let%expect_test "malformed tuples, patterns, and type declarations are rejected"
    =
  List.iter
    (fun source ->
      match Parse.program ~file:"invalid.tern" source with
      | Error _ -> print_endline "rejected"
      | Ok _ -> failwith source)
    [
      "let x = (1,);;";
      "let Some x = 1;;";
      "let rec (x, y) = fun z -> z;;";
      "let x = match y with;;";
      "type t = ;;";
      "type t = C of;;";
    ];
  [%expect
    {|
    rejected
    rejected
    rejected
    rejected
    rejected
    rejected
    |}]

let%expect_test
    "all examples parse, print, and reparse with span-free AST equality" =
  let directory = "../examples" in
  let files =
    Sys.readdir directory |> Array.to_list
    |> List.filter (fun name -> Filename.extension name = ".tern")
    |> List.sort String.compare
  in
  assert (List.length files = 15);
  List.iter
    (fun name ->
      let source =
        In_channel.with_open_bin
          (Filename.concat directory name)
          In_channel.input_all
      in
      let first = parse ~file:name source in
      let printed = Pretty.program first in
      let second = parse ~file:("printed/" ^ name) printed in
      assert (Ast.equal_program first second);
      assert (first <> second);
      assert (Pretty.program second = printed);
      Printf.printf "%s: declarations=%d round-trip=ok\n" name
        (List.length first.value))
    files;
  [%expect
    {|
    01_hello.tern: declarations=1 round-trip=ok
    02_arithmetic.tern: declarations=1 round-trip=ok
    03_booleans.tern: declarations=3 round-trip=ok
    04_strings.tern: declarations=2 round-trip=ok
    05_unit_and_sequence.tern: declarations=2 round-trip=ok
    06_let_and_shadowing.tern: declarations=3 round-trip=ok
    07_factorial.tern: declarations=2 round-trip=ok
    08_mutual_recursion.tern: declarations=2 round-trip=ok
    09_closures.tern: declarations=5 round-trip=ok
    10_higher_order.tern: declarations=5 round-trip=ok
    11_polymorphic_tuples.tern: declarations=5 round-trip=ok
    12_options.tern: declarations=4 round-trip=ok
    13_nested_patterns.tern: declarations=4 round-trip=ok
    14_variant_tree.tern: declarations=5 round-trip=ok
    15_list_library.tern: declarations=11 round-trip=ok
    |}]

let%expect_test "empty and comment-only programs round-trip" =
  List.iter
    (fun source ->
      let ast = parse source in
      assert (ast.value = []);
      assert (Pretty.program ast = "");
      assert (Ast.equal_program ast (parse ""));
      print_endline "empty program")
    [ ""; "(* just a comment *)\n" ];
  [%expect {|
    empty program
    empty program
    |}]
