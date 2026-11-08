open Tern

let prepare source =
  match Check.prepare ~file:"interp.tern" source with
  | Ok checked -> checked
  | Error diagnostic -> failwith (Diagnostic.show diagnostic)

let execute source =
  let checked = prepare source in
  let output = Buffer.create 64 in
  let result = Interp.program ~write:(Buffer.add_string output) checked in
  Buffer.contents output, result

let show source =
  match execute source with
  | output, Ok () -> Printf.printf "%S\n" output
  | _, Error diagnostic -> failwith (Diagnostic.show diagnostic)

let error ~at source =
  match execute source with
  | _, Ok () -> failwith "expected a runtime error"
  | output, Error diagnostic ->
      assert (diagnostic.severity = Diagnostic.Error);
      let span = diagnostic.primary in
      assert (String.sub source span.start_pos.byte_offset
                (span.end_pos.byte_offset - span.start_pos.byte_offset) = at);
      Printf.printf "stdout=%S\n%s\n" output diagnostic.message

let%expect_test "printing is exact and never adds a newline" =
  show {|let () = print_string "hello"; print_int 42; print_string "!\n";;|};
  [%expect {| "hello42!\n" |}]

let%expect_test "closures capture lexical bindings, not later shadows" =
  show "let x = 100;; let make n = fun y -> x + n + y;; let add = make 7;; let x = 900;; let () = print_int (add 35);;";
  [%expect {| "142" |}]

let%expect_test "nonrecursive RHS reads the old binding" =
  show "let x = 1;; let x = x + 1;; let () = print_int x;;";
  [%expect {| "2" |}]

let%expect_test "partial application and higher-order arguments" =
  show "let add x y = x + y;; let twice f x = f (f x);; let plus3 = add 3;; let () = print_int (twice plus3 10);;";
  [%expect {| "16" |}]

let%expect_test "recursive closures call themselves" =
  show "let rec factorial n = if n = 0 then 1 else n * factorial (n - 1);; let () = print_int (factorial 6);;";
  [%expect {| "720" |}]

let%expect_test "escaping mutual closures share the complete group and outer bindings" =
  show
    "let make base =\n\
       let rec even n = if n = 0 then base else odd (n - 1)\n\
       and odd n = if n = 0 then base + 1 else even (n - 1)\n\
       in (even, odd);;\n\
     let (even, odd) = make 40;;\n\
     let () = print_int (even 2); print_string \" \"; print_int (odd 2);;";
  [%expect {| "40 41" |}]

let%expect_test "separate closure groups do not share invocation state" =
  show
    "let make base = let rec f n = if n = 0 then base else f (n - 1) in f;;\n\
     let first = make 10;; let second = make 20;;\n\
     let () = print_int (first 2); print_string \" \"; print_int (second 2);;";
  [%expect {| "10 20" |}]

let%expect_test "tail-recursive evaluation does not retain caller activations" =
  show "let rec loop n acc = if n = 0 then acc else loop (n - 1) (acc + 1);; let () = print_int (loop 10000 0);;";
  [%expect {| "10000" |}]

let%expect_test "callee effects precede argument effects" =
  show
    {|let make () = print_string "callee "; fun x -> print_int x;;
      let argument () = print_string "argument "; 7;;
      let () = make () (argument ());;|};
  [%expect {| "callee argument 7" |}]

let%expect_test "tuple fields are evaluated left to right" =
  show "let mark n = print_int n; n;; let _ = (mark 1, mark 2, mark 3);;";
  [%expect {| "123" |}]

let%expect_test "constructor payloads are evaluated left to right" =
  show "type pair = Pair of (int * int);; let mark n = print_int n; n;; let _ = Pair (mark 1, mark 2);;";
  [%expect {| "12" |}]

let%expect_test "primitive operands are evaluated left to right" =
  show "let mark n = print_int n; n;; let () = print_int (mark 1 + mark 2);;";
  [%expect {| "123" |}]

let%expect_test "only the selected conditional branch runs" =
  show {|let () = if true then print_string "yes" else print_int (1 / 0);;|};
  [%expect {| "yes" |}]

let%expect_test "short-circuit operators do not evaluate an unused operand" =
  show
    {|let () =
        (if true || (1 / 0 = 0) then print_string "or" else print_string "bad");
        (if false && (1 / 0 = 0) then print_string "bad" else print_string "and");;|};
  [%expect {| "orand" |}]

let%expect_test "a used short-circuit right operand is evaluated exactly once" =
  show
    {|let right () = print_string "r"; true;;
      let _ = true && right ();;
      let _ = false || right ();;|};
  [%expect {| "rr" |}]

let%expect_test "nested tuple and unit parameter patterns" =
  show "let f (x, ((), y)) = x + y;; let () = print_int (f (1, ((), 41)));;";
  [%expect {| "42" |}]

let%expect_test "first-class constructors and closure payloads" =
  show
    "type 'a option = None | Some of 'a;;\n\
     let some = Some;; let make x = some (fun y -> x + y);;\n\
     let () = match make 10 with Some f -> print_int (f 32) | None -> ();;";
  [%expect {| "42" |}]

let%expect_test "nested cases choose the first matching pattern" =
  show
    "type 'a option = None | Some of 'a;;\n\
     let f x = match x with Some (0, y) -> y | Some (_, y) -> y + 1 | None -> 0;;\n\
     let () = print_int (f (Some (0, 41))); print_string \" \"; print_int (f (Some (9, 41)));;";
  [%expect {| "41 42" |}]

let%expect_test "failed pattern bindings do not shadow the next case's outer names" =
  show
    "let x = 100;; type pair = Pair of (int * int);;\n\
     let f value = match value with Pair (x, 0) -> x | Pair (_, _) -> x;;\n\
     let () = print_int (f (Pair (1, 2)));;";
  [%expect {| "100" |}]

let%expect_test "string and literal pattern matching uses exact bytes" =
  show
    {|let f text = match text with "a\n" -> 1 | "a" -> 2 | _ -> 3;;
      let () = print_int (f "a\n"); print_int (f "a"); print_int (f "é");;|};
  [%expect {| "123" |}]

let%expect_test "builtin shadowing follows resolved IDs" =
  show
    {|let original = print_int;; let print_int x = x + 1;;
      let () = original (print_int 41);;|};
  [%expect {| "42" |}]

let%expect_test "arithmetic is signed int32 with wrapping, not host-int arithmetic" =
  show
    {|let () =
        print_int (2147483647 + 1); print_string " ";
        print_int (-2147483648 - 1); print_string " ";
        print_int (65536 * 65536); print_string " ";
        print_int (-(-2147483648));;|};
  [%expect {| "-2147483648 2147483647 0 -2147483648" |}]

let%expect_test "division truncates toward zero and remainder has dividend sign" =
  show
    {|let () =
        print_int (-17 / 5); print_string " "; print_int (-17 mod 5); print_string " ";
        print_int (17 / (-5)); print_string " "; print_int (17 mod (-5));;|};
  [%expect {| "-3 -2 -3 2" |}]

let%expect_test "all six integer comparisons are signed" =
  show
    {|let mark value = if value then print_string "t" else print_string "f";;
      let () =
        mark (-2147483648 < 0); mark (-1 <= -1); mark (1 > -1);
        mark (1 >= 1); mark (42 = 42); mark (42 <> 7);;|};
  [%expect {| "tttttt" |}]

let%expect_test "all invalid division and remainder operand pairs are located errors" =
  error ~at:"/" "let x = 1 / 0;;";
  error ~at:"mod" "let x = 1 mod 0;;";
  error ~at:"/" "let x = -2147483648 / (-1);;";
  error ~at:"mod" "let x = -2147483648 mod (-1);;";
  [%expect
    {|
    stdout=""
    integer division by zero
    stdout=""
    integer remainder by zero
    stdout=""
    integer division overflow
    stdout=""
    integer remainder overflow
    |}]

let%expect_test "already written output is retained on runtime failure" =
  error ~at:"/" {|let () = print_string "before"; print_int (1 / 0);;|};
  [%expect
    {|
    stdout="before"
    integer division by zero
    |}]

let%expect_test "an uncovered match fails instead of returning an invented value" =
  error ~at:"match value with Some n -> n"
    "type option = None | Some of int;; let get value = match value with Some n -> n;; let () = print_int (get None);;";
  [%expect
    {|
    stdout=""
    pattern match failed
    |}]

let%expect_test "runtime diagnostics underline the operator" =
  let source = "let x = 1 / 0;;" in
  match execute source with
  | _, Ok () -> assert false
  | _, Error diagnostic ->
      print_string
        (Diagnostic.render
           ~source:(fun file -> if file = "interp.tern" then Some source else None)
           diagnostic);
      [%expect
        {|
        error: integer division by zero
         --> interp.tern:1:11
          |
        1 | let x = 1 / 0;;
          |           ^
        |}]

let%expect_test "sink failures are reported at the write call" =
  let checked = prepare {|let () = print_string "x";;|} in
  match Interp.program ~write:(fun _ -> raise (Sys_error "sink closed")) checked with
  | Ok () -> assert false
  | Error diagnostic ->
      print_endline diagnostic.message;
      [%expect {| output error: sink closed |}]

let%expect_test "checking succeeds before any program effect is permitted" =
  let source = {|let () = print_string "must not run";; let bad = 1 + true;;|} in
  match Check.prepare ~file:"interp.tern" source with
  | Ok _ -> assert false
  | Error diagnostic ->
      print_endline diagnostic.message;
      [%expect {| type mismatch: expected int, but got bool |}]

let%expect_test "each invocation has a fresh environment" =
  let source = "let x = 42;; let () = print_int x;;" in
  show source;
  show source;
  [%expect
    {|
    "42"
    "42"
    |}]

let%expect_test "every example produces exactly the bytes in its out file" =
  let directory = "../examples" in
  let files =
    Sys.readdir directory |> Array.to_list
    |> List.filter (fun file -> Filename.extension file = ".tern")
    |> List.sort String.compare
  in
  assert (List.length files = 15);
  List.iter
    (fun file ->
      let source = In_channel.with_open_bin (Filename.concat directory file) In_channel.input_all in
      let out = Filename.remove_extension file ^ ".out" in
      let expected = In_channel.with_open_bin (Filename.concat directory out) In_channel.input_all in
      match execute source with
      | actual, Ok () ->
          if actual <> expected then
            failwith (Printf.sprintf "%s: expected %S, got %S" file expected actual);
          Printf.printf "%s: exact stdout matches %s\n" file out
      | _, Error diagnostic -> failwith (Diagnostic.show diagnostic))
    files;
  [%expect
    {|
    01_hello.tern: exact stdout matches 01_hello.out
    02_arithmetic.tern: exact stdout matches 02_arithmetic.out
    03_booleans.tern: exact stdout matches 03_booleans.out
    04_strings.tern: exact stdout matches 04_strings.out
    05_unit_and_sequence.tern: exact stdout matches 05_unit_and_sequence.out
    06_let_and_shadowing.tern: exact stdout matches 06_let_and_shadowing.out
    07_factorial.tern: exact stdout matches 07_factorial.out
    08_mutual_recursion.tern: exact stdout matches 08_mutual_recursion.out
    09_closures.tern: exact stdout matches 09_closures.out
    10_higher_order.tern: exact stdout matches 10_higher_order.out
    11_polymorphic_tuples.tern: exact stdout matches 11_polymorphic_tuples.out
    12_options.tern: exact stdout matches 12_options.out
    13_nested_patterns.tern: exact stdout matches 13_nested_patterns.out
    14_variant_tree.tern: exact stdout matches 14_variant_tree.out
    15_list_library.tern: exact stdout matches 15_list_library.out
    |}]
