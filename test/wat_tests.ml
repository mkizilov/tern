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

let%expect_test "the remaining data and closure features compile and execute" =
  List.iter run
    [
      {|let (a, b) = (20, 22);; let () = print_int (a + b); print_string "\n";;|};
      {|let f g = g 1;; let inc x = x + 1;; let () = print_int (f inc); print_string "\n";;|};
      {|type t = A | B;; let f x = match x with A -> 1 | B -> 2;; let () = print_int (f B); print_string "\n";;|};
      {|let f x = match x with true -> 1 | false -> 0;; let () = print_int (f true); print_string "\n";;|};
      {|let s = "a" ^ "b";; let () = print_string s; print_string "\n";;|};
    ];
  [%expect
    {|
    42
    status=0
    2
    status=0
    2
    status=0
    1
    status=0
    ab
    status=0
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

let%expect_test
    "tail position survives forwarding aliases and nested conditional blocks" =
  let wat =
    emit
      "let rec loop n = if n = 0 then 42 else let result = loop (n - 1) in \
       result;;"
  in
  assert (contains wat "(return_call $fn2 ");
  print_endline "direct tail call replaces the current function frame";
  let non_tail =
    emit "let rec sum n = if n = 0 then 0 else n + sum (n - 1);;"
  in
  assert (contains non_tail "(call $fn2 ");
  assert (not (contains non_tail "(return_call $fn2 "));
  print_endline "non-tail addition retains its recursive continuation";
  [%expect
    {|
    direct tail call replaces the current function frame
    non-tail addition retains its recursive continuation
    |}]

let%expect_test
    "higher-order tail calls have a typed function table and tail dispatch" =
  let wat = emit "let apply f x = f x;;" in
  assert (contains wat "(table $functions ");
  assert (contains wat "(elem (i32.const 0) $fn0 $fn1");
  assert (contains wat "(return_call_indirect (type $tern_function)");
  run
    {|let apply f x = f x;; let () = print_int (apply (fun x -> x + 1) 41); print_string "\n";;|};
  [%expect {|
    42
    status=0
    |}]

let%expect_test "constructor switches use br_table before reading their payload"
    =
  let source =
    {|type 'a option = None | Some of 'a;;
      let f x = match x with Some (0, _) -> 1 | Some (_, true) -> 2 | Some _ -> 3 | None -> 4;;
      let () = print_int (f (Some (9, true))); print_int (f (Some (0, false))); print_int (f None); print_string "\n";;|}
  in
  let wat = emit source in
  assert (contains wat "(br_table ");
  assert (contains wat "(call $rt_variant_payload ");
  assert (contains wat "(br $join");
  run source;
  [%expect {|
    214
    status=0
    |}]

let%expect_test
    "match columns and wildcard defaults preserve source case priority" =
  run
    {|type t = A | B;;
    let f x = match x with (_, true) -> 1 | (A, _) -> 2 | (B, _) -> 3;;
    let () = print_int (f (A, true)); print_int (f (A, false)); print_int (f (B, false)); print_string "\n";;|};
  [%expect {|
    123
    status=0
    |}]

let%expect_test
    "bound fallbacks carry whole variants and returned closures capture join \
     formals" =
  run
    {|type 'a option = None | Some of 'a;;
    let make value = match value with Some 0 -> fun y -> y | whole ->
      (match whole with Some n -> fun y -> n + y | None -> fun y -> y);;
    let add = make (Some 10);;
    let () = print_int (add 32); print_string "\n";;|};
  [%expect {|
    42
    status=0
    |}]

let%expect_test
    "string switches use byte equality and concatenation preserves UTF-8" =
  run
    {|let f text = match text with "é\n" -> "unicode" | "" -> "empty" | _ -> "other";;
    let () = print_string (f ("é" ^ "\n") ^ ":" ^ f ""); print_string "\n";;|};
  [%expect {|
    unicode:empty
    status=0
    |}]

let%expect_test
    "tuple and constructor operands execute left-to-right, subject exactly once"
    =
  run
    {|type pair = Pair of (int * int);;
    let mark n = print_int n; n;;
    let subject () = print_string "s"; Pair (mark 1, mark 2);;
    let () = match subject () with Pair (a, b) -> print_int (a + b); print_string "\n";;|};
  [%expect {|
    s123
    status=0
    |}]

let%expect_test "an early wildcard never runs later case actions" =
  run
    {|let () = match true with _ -> print_string "first\n" | true -> print_string "wrong\n";;|};
  [%expect {|
    first
    status=0
    |}]

let%expect_test
    "indirect tail recursion can also run beyond ordinary stack depth" =
  let source =
    {|let rec loop n = if n = 0 then 42 else let f = if true then loop else loop in f (n - 1);;
    let () = print_int (loop 100000); print_string "\n";;|}
  in
  assert (contains (emit source) "(return_call_indirect (type $tern_function)");
  run source;
  [%expect {|
    42
    status=0
    |}]

let%expect_test
    "widely separated constructor tags use bounded balanced dispatch" =
  let constructors =
    List.init 5001 (fun i -> "C" ^ string_of_int i) |> String.concat " | "
  in
  let source =
    "type many = " ^ constructors ^ ";;\n"
    ^ "let f x = match x with C0 -> 1 | C5000 -> 2 | _ -> 3;;\n"
    ^ {|let () = print_int (f C0); print_int (f C5000); print_int (f C2500); print_string "\n";;|}
  in
  let wat = emit source in
  assert (not (contains wat "(br_table "));
  assert (contains wat "i32.lt_u");
  assert (String.length wat < 50000);
  run source;
  [%expect {|
    123
    status=0
    |}]

let%expect_test
    "tail calls remain tail through match joins and case result blocks" =
  let source =
    {|let rec loop n = match n with 0 -> 42 | rest -> loop (rest - 1);;
    let () = print_int (loop 100000); print_string "\n";;|}
  in
  assert (contains (emit source) "(return_call $fn2 ");
  run source;
  [%expect {|
    42
    status=0
    |}]
