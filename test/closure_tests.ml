open Tern
module Ids = Set.Make (Int)
module Labels = Map.Make (Int)

let prepare source =
  match Check.prepare ~file:"closure.tern" source with
  | Ok checked -> checked
  | Error diagnostic -> failwith (Diagnostic.show diagnostic)

let convert source = Closure_convert.program (Lower.program (prepare source))

let verify (program : Closed.program) =
  let definitions = ref Ids.empty in
  let direct = ref 0 and indirect = ref 0 in
  let bind (name : Core.name) =
    assert (name.value.id < program.value.next_id);
    assert (not (Ids.mem name.value.id !definitions));
    definitions := Ids.add name.value.id !definitions;
    name.value.id
  in
  let count = List.length program.value.functions in
  assert (
    List.map
      (fun (f : Closed.function_definition) -> f.value.index)
      program.value.functions
    = List.init count Fun.id);
  let atom values = function
    | Anf.Literal _ -> ()
    | Name name -> assert (Ids.mem name.value.id values)
  in
  let rec expression values labels environment layout (source : Closed.expr) =
    match source.value with
    | Return value -> atom values value
    | Let (name, rhs, body) ->
        right_hand_side values labels environment layout rhs;
        expression (Ids.add (bind name) values) labels environment layout body
    | Joins (joins, body) ->
        let labels =
          List.fold_left
            (fun labels (join : Closed.join) ->
              Labels.add (bind join.value.label)
                (List.length join.value.parameters)
                labels)
            labels joins
        in
        List.iter
          (fun (join : Closed.join) ->
            let values =
              List.fold_left
                (fun values name -> Ids.add (bind name) values)
                values join.value.parameters
            in
            expression values labels environment layout join.value.action)
          joins;
        expression values labels environment layout body
    | Jump (label, arguments) ->
        assert (Labels.find label.value.id labels = List.length arguments);
        List.iter (atom values) arguments
    | If (condition, yes, no) ->
        atom values condition;
        expression values labels environment layout yes;
        expression values labels environment layout no
    | Switch (subject, arms, default) ->
        atom values subject;
        List.iter
          (fun (_, body) -> expression values labels environment layout body)
          arms;
        expression values labels environment layout default
    | Fail _ -> ()
  and right_hand_side values labels environment layout (source : Closed.rhs) =
    match source.value with
    | Alias value | Payload value | Closure_environment value ->
        atom values value
    | Closure_call (callee, argument) ->
        incr indirect;
        atom values callee;
        atom values argument
    | Direct_call (index, env, argument) ->
        incr direct;
        assert (index >= 0 && index < count);
        atom values env;
        atom values argument
    | Primitive (_, arguments) | Tuple arguments | Environment arguments ->
        List.iter (atom values) arguments
    | Variant (_, payload) -> Option.iter (atom values) payload
    | Field (value, index) ->
        assert (index >= 0);
        atom values value
    | Block body -> expression values labels environment layout body
    | Allocate_environment size -> assert (size >= 0)
    | Environment_set (env, slot, value) ->
        assert (slot >= 0);
        atom values env;
        atom values value
    | Environment_get (env, slot) -> (
        atom values env;
        assert (slot >= 0 && slot < layout);
        match (env, environment) with
        | Anf.Name name, Some expected -> assert (name.value.id = expected)
        | _ -> assert false)
    | Closure (index, env) ->
        assert (index >= 0 && index < count);
        atom values env
    | Builtin_apply (_, value) -> atom values value
  in
  List.iter
    (fun (definition : Closed.function_definition) ->
      let f = definition.value in
      let values =
        Ids.empty |> Ids.add (bind f.environment) |> Ids.add (bind f.parameter)
      in
      (* No implicit globals or lexical value environment are admitted here. *)
      expression values Labels.empty (Some f.environment.value.id)
        (List.length f.layout) f.body)
    program.value.functions;
  let values =
    List.fold_left
      (fun values (name, _) -> Ids.add (bind name) values)
      Ids.empty program.value.builtins
  in
  expression values Labels.empty None 0 program.value.body;
  (!direct, !indirect)

let compare source =
  let checked = prepare source in
  let anf = Lower.program checked in
  let closed = Closure_convert.program anf in
  ignore (verify closed);
  let capture eval =
    let output = Buffer.create 64 in
    let result = eval (Buffer.add_string output) in
    (Buffer.contents output, result)
  in
  let original, first = capture (fun write -> Ir_interp.program ~write anf) in
  let converted, second =
    capture (fun write -> Ir_interp.closed ~write closed)
  in
  assert (original = converted);
  match (first, second) with
  | Ok (), Ok () -> Printf.printf "%S: ok\n" converted
  | Error first, Error second ->
      assert (
        first.message = second.message
        && Ast.equal_span first.primary second.primary);
      Printf.printf "%S: %s\n" converted second.message
  | _ -> assert false

let%expect_test
    "free variables include nested uses but exclude parameters and join binders"
    =
  let anf = Lower.program (prepare "let outer x = fun y -> x + y;;") in
  let rec functions (source : Anf.expr) =
    match source.value with
    | Let (_, { value = Anf.Lambda (parameter, body); _ }, rest) ->
        Printf.printf "parameter %s free [%s]\n" (Ir_pretty.name parameter)
          (String.concat ", "
             (List.map Ir_pretty.name (Free_vars.function_body parameter body)));
        functions body;
        functions rest
    | Let (_, _, body) -> functions body
    | _ -> ()
  in
  functions anf.value.body;
  [%expect {|
    parameter x#7 free []
    parameter y#8 free [x#7]
    |}]

let%expect_test
    "converted nested closures have top-level code and explicit captures" =
  print_string (Closed_pretty.program (convert "let make x = fun y -> x + y;;"));
  [%expect
    {|
    function @0 print_int#0($env_arg#12, $arg#13) captures [] layout [] {
      let $cc#14 = builtin Print_int($arg#13)
      return $cc#14
    }
    function @1 print_string#1($env_arg#15, $arg#16) captures [] layout [] {
      let $cc#17 = builtin Print_string($arg#16)
      return $cc#17
    }
    function @2 $anf#11($env_arg#18, x#7) captures [] layout [] {
      let $env#21 = environment[x#7]
      let $anf#10 = closure(@3, $env#21)
      return $anf#10
    }
    function @3 $anf#10($env_arg#19, y#8) captures [x#7] layout [x#7] {
      let $capture#20 = environment $env_arg#19[0]
      let $anf#9 = Add($capture#20, y#8)
      return $anf#9
    }
    entry {
      let $env#22 = environment[]
      let $anf#11 = closure(@2, $env#22)
      let make#6 = $anf#11
      return ()
    }
    |}]

let%expect_test "recursive conversion explicitly ties the closure environment" =
  print_string (Closed_pretty.program (convert "let rec f x = f x;;"));
  [%expect
    {|
    function @0 print_int#0($env_arg#9, $arg#10) captures [] layout [] {
      let $cc#11 = builtin Print_int($arg#10)
      return $cc#11
    }
    function @1 print_string#1($env_arg#12, $arg#13) captures [] layout [] {
      let $cc#14 = builtin Print_string($arg#13)
      return $cc#14
    }
    function @2 f#6($env_arg#15, x#7) captures [f#6] layout [f#6] {
      let $capture#16 = environment $env_arg#15[0]
      let $call_env#17 = closure-environment $capture#16
      let $anf#8 = call-direct @2($call_env#17, x#7)
      return $anf#8
    }
    entry {
      let $rec_env#18 = allocate-environment 1
      let f#6 = closure(@2, $rec_env#18)
      let $init#19 = set-environment $rec_env#18[0] = f#6
      return ()
    }
    |}]

let%expect_test "known top-level functions and aliases use direct calls" =
  let program =
    convert "let id x = x;; let alias = id;; let value = alias 42;;"
  in
  let direct, indirect = verify program in
  Printf.printf "direct=%d closure=%d\n" direct indirect;
  [%expect {| direct=1 closure=0 |}]

let%expect_test "unknown higher-order parameters still dispatch closure records"
    =
  let program =
    convert "let apply f x = f x;; let id x = x;; let value = apply id 42;;"
  in
  let direct, indirect = verify program in
  Printf.printf "direct=%d closure=%d\n" direct indirect;
  [%expect {| direct=1 closure=2 |}]

let%expect_test "multi-level lexical capture survives later shadowing" =
  compare
    "let x = 100;; let make n = fun y -> fun z -> x + n + y + z;; let f = make \
     7 20;; let x = 900;; let () = print_int (f 15);;";
  [%expect {| "142": ok |}]

let%expect_test
    "mutually recursive escaping functions retain a shared captured value" =
  compare
    "let make base = let rec even n = if n = 0 then base else odd (n - 1) and \
     odd n = if n = 0 then base + 1 else even (n - 1) in (even, odd);;\n\
     let (even, odd) = make 40;; let () = print_int (even 2); print_string \" \
     \"; print_int (odd 2);;";
  [%expect {| "40 41": ok |}]

let%expect_test "recursive environments from separate calls are not shared" =
  compare
    "let make base = let rec f n = if n = 0 then base else f (n - 1) in f;; \
     let a = make 10;; let b = make 20;; let () = print_int (a 2); \
     print_string \" \"; print_int (b 2);;";
  [%expect {| "10 20": ok |}]

let%expect_test
    "case joins and functions returned by a match keep pattern values" =
  compare
    "type 'a option = None | Some of 'a;; let make value = match value with \
     Some n -> fun x -> n + x | None -> fun x -> x;; let f = make (Some 10);; \
     let () = print_int (f 32);;";
  [%expect {| "42": ok |}]

let%expect_test "builtins and constructors also have uniform callable records" =
  compare
    "type 'a option = None | Some of 'a;; let make f x = f x;; let value = \
     make Some 42;; let output = print_int;; let () = match value with Some n \
     -> output n | None -> ();;";
  [%expect {| "42": ok |}]

let%expect_test
    "error spans and output prefixes survive the converted interpreter" =
  compare {|let () = print_string "before"; print_int (1 / 0);;|};
  compare
    "type t = A | B;; let f x = match x with A -> 1;; let () = print_int (f \
     B);;";
  [%expect
    {|
    "before": integer division by zero
    "": pattern match failed
    |}]

let%expect_test
    "conversion is deterministic and all lifted functions are closed" =
  let anf = Lower.program (prepare "let make x = fun y -> x + y;;") in
  let first = Closure_convert.program anf in
  let second = Closure_convert.program anf in
  assert (Closed.equal_program first second);
  ignore (verify first);
  print_endline "deterministic function table; no implicit value captures";
  [%expect {| deterministic function table; no implicit value captures |}]

let%expect_test "all examples agree under AST, ANF, and converted IR execution"
    =
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
      let anf = Lower.program checked in
      let closed = Closure_convert.program anf in
      ignore (verify closed);
      let execute evaluator =
        let output = Buffer.create 64 in
        (match evaluator (Buffer.add_string output) with
        | Ok () -> ()
        | Error d -> failwith (Diagnostic.show d));
        assert (Buffer.contents output = expected)
      in
      execute (fun write -> Interp.program ~write checked);
      execute (fun write -> Ir_interp.program ~write anf);
      execute (fun write -> Ir_interp.closed ~write closed);
      Printf.printf "%s: AST = ANF = closed IR = golden bytes\n" file)
    files;
  [%expect
    {|
    01_hello.tern: AST = ANF = closed IR = golden bytes
    02_arithmetic.tern: AST = ANF = closed IR = golden bytes
    03_booleans.tern: AST = ANF = closed IR = golden bytes
    04_strings.tern: AST = ANF = closed IR = golden bytes
    05_unit_and_sequence.tern: AST = ANF = closed IR = golden bytes
    06_let_and_shadowing.tern: AST = ANF = closed IR = golden bytes
    07_factorial.tern: AST = ANF = closed IR = golden bytes
    08_mutual_recursion.tern: AST = ANF = closed IR = golden bytes
    09_closures.tern: AST = ANF = closed IR = golden bytes
    10_higher_order.tern: AST = ANF = closed IR = golden bytes
    11_polymorphic_tuples.tern: AST = ANF = closed IR = golden bytes
    12_options.tern: AST = ANF = closed IR = golden bytes
    13_nested_patterns.tern: AST = ANF = closed IR = golden bytes
    14_variant_tree.tern: AST = ANF = closed IR = golden bytes
    15_list_library.tern: AST = ANF = closed IR = golden bytes
    |}]
