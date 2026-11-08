open Tern

let prepare source =
  match Check.prepare ~file:"wasm.tern" source with
  | Ok checked -> checked
  | Error diagnostic -> failwith (Diagnostic.show diagnostic)

let emit source =
  match Wasm_build.emit (prepare source) with
  | Ok wat -> wat
  | Error diagnostic -> failwith (Diagnostic.show diagnostic)

let contains text pattern =
  let rec scan offset =
    offset + String.length pattern <= String.length text
    && (String.sub text offset (String.length pattern) = pattern
       || scan (offset + 1))
  in
  scan 0

let run source =
  match Wasm_build.run (prepare source) with
  | Ok status -> Printf.printf "status=%d\n" status
  | Error diagnostic -> failwith (Diagnostic.show diagnostic)

let%expect_test "readable source function comments and direct Wasm calls" =
  let wat = emit "let inc x = x + 1;; let answer = inc 41;;" in
  String.split_on_char '\n' wat
  |> List.filter (String.starts_with ~prefix:";; source function")
  |> List.iter print_endline;
  assert (contains wat "(call $fn2 ");
  assert (not (contains wat "call_indirect"));
  assert (contains wat "(export \"_start\")");
  [%expect
    {|
    ;; source function print_int#0 (code 0)
    ;; source function print_string#1 (code 1)
    ;; source function inc#6 (code 2)
    |}]

let%expect_test
    "integer code generation uses wrapping i32 arithmetic and signed \
     comparisons" =
  let wat =
    emit
      "let a = -1;; let x = -a + 2 - 3 * 4;; let p = a / 2;; let q = a mod 2;; \
       let _ = (a = 1) && (a <> 2) && (a < 3) && (a <= 4) && (a > 5) && (a >= \
       6);;"
  in
  List.iter
    (fun instruction ->
      assert (contains wat instruction);
      print_endline instruction)
    [
      "i32.sub";
      "i32.add";
      "i32.mul";
      "i32.div_s";
      "i32.rem_s";
      "i32.eq";
      "i32.ne";
      "i32.lt_s";
      "i32.le_s";
      "i32.gt_s";
      "i32.ge_s";
    ];
  [%expect
    {|
    i32.sub
    i32.add
    i32.mul
    i32.div_s
    i32.rem_s
    i32.eq
    i32.ne
    i32.lt_s
    i32.le_s
    i32.gt_s
    i32.ge_s
    |}]

let%expect_test
    "passive byte literals do not occupy a fixed static memory region" =
  let wat = emit {|let () = print_string "é\n";;|} in
  assert (contains wat "(data $data0 \"\\c3\\a9\\0a\")");
  assert (contains wat "(memory.init $data0");
  print_endline "UTF-8 bytes are copied into a fresh runtime string";
  [%expect {| UTF-8 bytes are copied into a fresh runtime string |}]

let%expect_test
    "generated binary validates and executes with full integer boundaries" =
  run
    {|let () = print_int (2147483647 + 1); print_string " "; print_int (-(-2147483648)); print_string "\n";;|};
  [%expect {|
    -2147483648 -2147483648
    status=0
    |}]

let%expect_test "false is unboxed and an unused branch is not evaluated" =
  run {|let () = if false then print_int (1 / 0) else print_string "else\n";;|};
  [%expect {|
    else
    status=0
    |}]

let%expect_test "all integer comparisons execute with signed boundary semantics"
    =
  run
    {|let mark b = if b then print_string "t" else print_string "f";;
    let () = mark (-2147483648 < 0); mark (-1 <= -1); mark (1 > -1);
      mark (1 >= 1); mark (42 = 42); mark (42 <> 7); mark (-1 > 0);
      print_string "\n";;|};
  [%expect {|
    ttttttf
    status=0
    |}]

let%expect_test
    "recursive direct calls and conditional results retain block values" =
  run
    {|let rec sum n = if n = 0 then 0 else n + sum (n - 1);; let () = print_int ((if true then sum 5 else 900) + 1); print_string "\n";;|};
  [%expect {|
    16
    status=0
    |}]

let%expect_test
    "arithmetic guards include the non-Wasm remainder overflow condition" =
  let wat = emit "let x = -2147483648 mod (-1);;" in
  assert (contains wat "(i32.eq (local.get $a) (i32.const -2147483648))");
  assert (contains wat "(i32.eq (local.get $b) (i32.const -1))");
  assert (contains wat "(then unreachable)");
  print_endline "min-int/-1 and zero divisors are guarded before remainder";
  [%expect {| min-int/-1 and zero divisors are guarded before remainder |}]

let%expect_test
    "unsupported features return located diagnostics rather than partial WAT" =
  List.iter
    (fun source ->
      match Wasm_build.emit (prepare source) with
      | Ok _ -> assert false
      | Error diagnostic ->
          assert (diagnostic.primary.file = "wasm.tern");
          assert (
            diagnostic.primary.end_pos.byte_offset
            > diagnostic.primary.start_pos.byte_offset);
          print_endline diagnostic.message)
    [
      "let pair = (1, 2);;";
      "let f g = g 1;;";
      "type t = A | B;; let value = A;;";
      "let f x = match x with true -> 1 | false -> 0;;";
      {|let s = "a" ^ "b";;|};
    ];
  [%expect
    {|
    the part-1 Wasm backend does not support tuples yet
    the part-1 Wasm backend does not support indirect closure calls yet
    the part-1 Wasm backend does not support variants yet
    the part-1 Wasm backend does not support pattern matching yet
    the part-1 Wasm backend does not support string concatenation yet
    |}]

let%expect_test "emission is deterministic and does not mutate closed IR" =
  let closed =
    Closure_convert.program
      (Lower.program (prepare "let id x = x;; let n = id 1;;"))
  in
  let first = Wat.program closed and second = Wat.program closed in
  assert (first = second);
  print_endline "stable WAT and literal numbering";
  [%expect {| stable WAT and literal numbering |}]
