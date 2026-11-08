open Tern

let prepare source =
  match Check.prepare ~file:"anf.tern" source with
  | Ok checked -> checked
  | Error diagnostic -> failwith (Diagnostic.show diagnostic)

module Ids = Set.Make (Int)
module Labels = Map.Make (Int)

let verify (program : Anf.program) =
  let definitions = ref Ids.empty in
  let constructors = ref Labels.empty in
  let tag_switches = ref 0
  and literal_switches = ref 0
  and payload_reads = ref 0
  and join_count = ref 0 in
  let bind (name : Core.name) =
    assert (name.value.id < program.value.next_id);
    assert (not (Ids.mem name.value.id !definitions));
    definitions := Ids.add name.value.id !definitions;
    name.value.id
  in
  let values =
    List.fold_left
      (fun values (name, _) -> Ids.add (bind name) values)
      Ids.empty program.value.builtins
  in
  List.iter
    (fun (definition : Core.type_decl) ->
      ignore (bind definition.value.type_name);
      List.iter
        (fun name -> ignore (bind name))
        definition.value.type_parameters;
      List.iter
        (fun (constructor : Core.constructor_decl) ->
          let id = bind constructor.value.constructor_name in
          constructors :=
            Labels.add id
              (Option.is_some constructor.value.constructor_payload)
              !constructors)
        definition.value.type_constructors)
    program.value.types;
  let atom values = function
    | Anf.Literal _ -> ()
    | Name name -> assert (Ids.mem name.value.id values)
  in
  let rec expression values labels payloads (source : Anf.expr) =
    match source.value with
    | Return value -> atom values value
    | Let (name, rhs, body) ->
        right_hand_side values labels payloads rhs;
        expression (Ids.add (bind name) values) labels payloads body
    | Let_rec (functions, body) ->
        let recursive_values =
          List.fold_left
            (fun values (definition : Anf.function_binding) ->
              Ids.add (bind definition.value.function_name) values)
            values functions
        in
        List.iter
          (fun (definition : Anf.function_binding) ->
            let values =
              Ids.add (bind definition.value.parameter) recursive_values
            in
            expression values Labels.empty Ids.empty definition.value.body)
          functions;
        expression recursive_values labels payloads body
    | Joins (joins, body) ->
        join_count := !join_count + List.length joins;
        let labels =
          List.fold_left
            (fun labels (join : Anf.join) ->
              Labels.add (bind join.value.label)
                (List.length join.value.parameters)
                labels)
            labels joins
        in
        List.iter
          (fun (join : Anf.join) ->
            let values =
              List.fold_left
                (fun values name -> Ids.add (bind name) values)
                values join.value.parameters
            in
            expression values labels payloads join.value.action)
          joins;
        expression values labels payloads body
    | Jump (label, arguments) ->
        assert (Labels.find label.value.id labels = List.length arguments);
        List.iter (atom values) arguments
    | If (condition, yes, no) ->
        atom values condition;
        expression values labels payloads yes;
        expression values labels payloads no
    | Switch (subject, arms, default) ->
        atom values subject;
        let keys = List.map fst arms in
        assert (
          List.length keys = List.length (List.sort_uniq Stdlib.compare keys));
        (match keys with
        | Anf.Tag _ :: _ -> incr tag_switches
        | _ -> incr literal_switches);
        List.iter
          (fun (key, branch) ->
            let payloads =
              match (subject, key) with
              | Anf.Name name, Anf.Tag tag when Labels.find tag.id !constructors
                ->
                  Ids.add name.value.id payloads
              | _ -> payloads
            in
            expression values labels payloads branch)
          arms;
        expression values labels payloads default
    | Fail _ -> ()
  and right_hand_side values labels payloads (source : Anf.rhs) =
    match source.value with
    | Alias value -> atom values value
    | Apply (callee, argument) ->
        atom values callee;
        atom values argument
    | Primitive (operator, arguments) ->
        assert (
          List.length arguments
          = match operator.value with Core.Negate -> 1 | _ -> 2);
        List.iter (atom values) arguments
    | Tuple fields -> List.iter (atom values) fields
    | Constructor name -> assert (Labels.mem name.value.id !constructors)
    | Lambda (parameter, body) ->
        expression (Ids.add (bind parameter) values) Labels.empty Ids.empty body
    | Field (subject, index) ->
        atom values subject;
        assert (index >= 0)
    | Payload subject -> (
        incr payload_reads;
        atom values subject;
        match subject with
        | Name name -> assert (Ids.mem name.value.id payloads)
        | _ -> assert false)
    | Block body -> expression values labels payloads body
  in
  expression values Labels.empty Ids.empty program.value.body;
  (!tag_switches, !literal_switches, !payload_reads, !join_count)

let capture evaluator =
  let output = Buffer.create 64 in
  let result = evaluator (Buffer.add_string output) in
  (Buffer.contents output, result)

let compare source =
  let checked = prepare source in
  let ir = Lower.program checked in
  ignore (verify ir);
  let ast_output, ast = capture (fun write -> Interp.program ~write checked) in
  let ir_output, normalized =
    capture (fun write -> Ir_interp.program ~write ir)
  in
  assert (ast_output = ir_output);
  match (ast, normalized) with
  | Ok (), Ok () -> Printf.printf "%S: ok\n" ir_output
  | Error expected, Error actual ->
      assert (expected.message = actual.message);
      assert (Ast.equal_span expected.primary actual.primary);
      Printf.printf "%S: %s\n" ir_output actual.message
  | _ -> assert false

let%expect_test "every intermediate operation is named and arguments are atoms"
    =
  let ir = Lower.program (prepare "let x = (1 + 2) * 3;;") in
  ignore (verify ir);
  print_string (Ir_pretty.program ir);
  [%expect
    {|
    builtin print_int#0
    builtin print_string#1
    let $anf#7 = Add(1, 2)
    let $anf#8 = Multiply($anf#7, 3)
    let x#6 = $anf#8
    return ()
    |}]

let%expect_test
    "one tag switch groups constructor cases before payload and literal tests" =
  let source =
    "type option = None | Some of int;; let f x = match x with Some 0 -> 1 | \
     Some _ -> 2 | None -> 3;;"
  in
  let tags, literals, payloads, joins =
    verify (Lower.program (prepare source))
  in
  Printf.printf
    "tag switches=%d literal switches=%d guarded payloads=%d case joins=%d\n"
    tags literals payloads joins;
  [%expect
    {| tag switches=1 literal switches=1 guarded payloads=1 case joins=3 |}]

let%expect_test
    "decision tree default and bound fallback receive the original value" =
  compare
    "type 'a option = None | Some of 'a;;\n\
     let f x = match x with Some 0 -> print_string \"zero\" | value ->\n\
     (match value with None -> print_string \"none\" | Some n -> print_int n);;\n\
     let () = f (Some 7); f None;;";
  [%expect {| "7none": ok |}]

let%expect_test "nested tuple and constructor patterns share safe projections" =
  compare
    "type 'a option = None | Some of 'a;;\n\
     let f x = match x with Some (0, _) -> 1 | Some (_, true) -> 2 | Some _ -> \
     3 | None -> 4;;\n\
     let () = print_int (f (Some (9, true))); print_int (f (Some (0, false))); \
     print_int (f None);;";
  [%expect {| "214": ok |}]

let%expect_test "matrix column selection preserves first-case priority" =
  compare
    "type t = A | B;;\n\
     let f x = match x with (_, true) -> 1 | (A, _) -> 2 | (B, _) -> 3;;\n\
     let () = print_int (f (A, true)); print_int (f (A, false)); print_int (f \
     (B, false));;";
  [%expect {| "123": ok |}]

let%expect_test "the match subject executes once and case actions execute once"
    =
  compare
    "type option = None | Some of int;;\n\
     let get () = print_string \"s\"; Some 42;;\n\
     let () = match get () with Some n -> print_int n | None -> print_string \
     \"n\";;";
  [%expect {| "s42": ok |}]

let%expect_test "an early wildcard keeps later effects unreachable" =
  compare
    {|let () = match true with _ -> print_string "first" | true -> print_string "bad";;|};
  [%expect {| "first": ok |}]

let%expect_test "branch results join before a single continuation" =
  compare
    {|let choose b = (if b then (print_string "t"; 1) else (print_string "f"; 2)) + (print_string "c"; 3);;
      let () = print_int (choose false);;|};
  [%expect {| "fc5": ok |}]

let%expect_test "callee and argument effects keep their ordering through ANF" =
  compare
    {|let make () = print_string "f"; fun x -> print_int x;;
      let arg () = print_string "a"; 7;; let () = make () (arg ());;|};
  [%expect {| "fa7": ok |}]

let%expect_test "closures escaping a case capture its joined pattern parameters"
    =
  compare
    "type 'a option = None | Some of 'a;;\n\
     let f value = match value with Some x -> (fun y -> x + y) | None -> (fun \
     y -> y);;\n\
     let add = f (Some 10);; let () = print_int (add 32);;";
  [%expect {| "42": ok |}]

let%expect_test "recursive groups and curried functions survive normalization" =
  compare
    "let rec even n = if n = 0 then true else odd (n - 1) and odd n = if n = 0 \
     then false else even (n - 1);;\n\
     let () = if even 10 then print_string \"even\" else print_string \"odd\";;";
  [%expect {| "even": ok |}]

let%expect_test
    "short-circuit control flow is not hoisted into an unused branch" =
  compare
    {|let _ = false && (1 / 0 = 0);; let _ = true || (1 / 0 = 0);; let () = print_string "safe";;|};
  [%expect {| "safe": ok |}]

let%expect_test "string and integer switches compare literal values" =
  compare
    {|let f x = match x with "a" -> 1 | "b" -> 2 | _ -> 3;;
      let g x = match x with 0 -> "z" | _ -> "n";;
      let () = print_int (f "b"); print_string (g 9);;|};
  [%expect {| "2n": ok |}]

let%expect_test
    "arithmetic trap messages, source spans, and partial output agree" =
  compare {|let () = print_string "before"; print_int (1 / 0);;|};
  compare "let x = -2147483648 mod (-1);;";
  [%expect
    {|
    "before": integer division by zero
    "": integer remainder overflow
    |}]

let%expect_test
    "an uncovered decision-tree path has the original match diagnostic" =
  compare
    "type t = A | B;; let f x = match x with A -> 1;; let () = print_int (f \
     B);;";
  [%expect {| "": pattern match failed |}]

let%expect_test "lowering is deterministic and does not consume Core IDs" =
  let checked = prepare "let f (x, y) = x + y;;" in
  let first = Lower.program checked in
  let second = Lower.program checked in
  assert (Anf.equal_program first second);
  assert (first.value.next_id > checked.core.value.next_id);
  ignore (verify first);
  print_endline "deterministic hygienic ANF";
  [%expect {| deterministic hygienic ANF |}]

let%expect_test
    "all examples agree under AST and IR interpretation, including goldens" =
  let files =
    Sys.readdir "../examples" |> Array.to_list
    |> List.filter (fun file -> Filename.extension file = ".tern")
    |> List.sort String.compare
  in
  assert (List.length files = 15);
  List.iter
    (fun file ->
      let source =
        In_channel.with_open_bin ("../examples/" ^ file) In_channel.input_all
      in
      let expected =
        In_channel.with_open_bin
          ("../examples/" ^ Filename.remove_extension file ^ ".out")
          In_channel.input_all
      in
      let checked = prepare source in
      let ir = Lower.program checked in
      ignore (verify ir);
      let ast_output, ast_result =
        capture (fun write -> Interp.program ~write checked)
      in
      let ir_output, ir_result =
        capture (fun write -> Ir_interp.program ~write ir)
      in
      (match (ast_result, ir_result) with
      | Ok (), Ok () -> ()
      | _ -> assert false);
      assert (ast_output = expected && ir_output = expected);
      Printf.printf "%s: AST = IR = golden bytes\n" file)
    files;
  [%expect
    {|
    01_hello.tern: AST = IR = golden bytes
    02_arithmetic.tern: AST = IR = golden bytes
    03_booleans.tern: AST = IR = golden bytes
    04_strings.tern: AST = IR = golden bytes
    05_unit_and_sequence.tern: AST = IR = golden bytes
    06_let_and_shadowing.tern: AST = IR = golden bytes
    07_factorial.tern: AST = IR = golden bytes
    08_mutual_recursion.tern: AST = IR = golden bytes
    09_closures.tern: AST = IR = golden bytes
    10_higher_order.tern: AST = IR = golden bytes
    11_polymorphic_tuples.tern: AST = IR = golden bytes
    12_options.tern: AST = IR = golden bytes
    13_nested_patterns.tern: AST = IR = golden bytes
    14_variant_tree.tern: AST = IR = golden bytes
    15_list_library.tern: AST = IR = golden bytes
    |}]
