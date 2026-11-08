open Tern
open Tern_diff

let anf source =
  Lower.program
    (match Check.prepare ~file:"opt.tern" source with
    | Ok x -> x
    | Error d -> failwith (Diagnostic.show d))

let rec counts (source : Anf.expr) =
  let plus (a, b, c) (x, y, z) = (a + x, b + y, c + z) in
  match source.value with
  | Let (_, rhs, body) ->
      let own =
        match rhs.value with
        | Primitive _ -> (1, 0, 0)
        | Apply _ -> (0, 1, 0)
        | _ -> (0, 0, 0)
      in
      let inner =
        match rhs.value with
        | Lambda (_, body) | Block body -> counts body
        | _ -> (0, 0, 0)
      in
      plus own (plus inner (counts body))
  | Let_rec (functions, body) ->
      List.fold_left
        (fun n (f : Anf.function_binding) -> plus n (counts f.value.body))
        (counts body) functions
  | Joins (joins, body) ->
      List.fold_left
        (fun n (j : Anf.join) -> plus n (counts j.value.action))
        (counts body) joins
  | Switch (_, arms, default) ->
      List.fold_left
        (fun n (_, body) -> plus n (counts body))
        (plus (0, 0, 1) (counts default))
        arms
  | If (_, a, b) -> plus (counts a) (counts b)
  | _ -> (0, 0, 0)

let observe flags source =
  let actual =
    Differential.check ~optimizations:flags ~file:"opt.tern" source
  in
  Printf.printf "success=%b stdout=%S\n" actual.success actual.output

let unique_binders program =
  let seen = Hashtbl.create 32 in
  let bind (name : Core.name) =
    assert (not (Hashtbl.mem seen name.value.id));
    Hashtbl.add seen name.value.id ()
  in
  let rec walk (expr : Anf.expr) =
    match expr.value with
    | Let (name, rhs, body) ->
        bind name;
        (match rhs.value with
        | Lambda (p, b) ->
            bind p;
            walk b
        | Block b -> walk b
        | _ -> ());
        walk body
    | Let_rec (fs, body) ->
        List.iter
          (fun (f : Anf.function_binding) ->
            bind f.value.function_name;
            bind f.value.parameter;
            walk f.value.body)
          fs;
        walk body
    | Joins (js, body) ->
        List.iter
          (fun (j : Anf.join) ->
            bind j.value.label;
            List.iter bind j.value.parameters;
            walk j.value.action)
          js;
        walk body
    | If (_, a, b) ->
        walk a;
        walk b
    | Switch (_, arms, default) ->
        List.iter (fun (_, body) -> walk body) arms;
        walk default
    | _ -> ()
  in
  walk program.Ast.value.Anf.body

let%expect_test
    "constant folding and propagation operate independently with int32 wrapping"
    =
  let source =
    "let x = 2147483647 + 1;; let y = x + 2;; let () = print_int y;;"
  in
  let result = Opt_const.program (anf source) in
  let primitive, _, _ = counts result.value.body in
  assert (primitive = 0);
  observe { Optimize.none with constants = true } source;
  [%expect {| success=true stdout="-2147483646" |}]

let%expect_test
    "constant folding does not move or erase a runtime arithmetic error" =
  observe
    { Optimize.none with constants = true }
    {|let () = print_string "before";; let unused = -2147483648 mod (-1);;|};
  [%expect {| success=false stdout="before" |}]

let%expect_test
    "constant condition results propagate but selected effects remain" =
  let source = "let n = if true then 1 else 2;; let () = print_int (n+3);;" in
  let primitive, _, _ = counts (Opt_const.program (anf source)).value.body in
  assert (primitive = 0);
  observe { Optimize.none with constants = true } source;
  observe
    { Optimize.none with constants = true }
    {|let n = if true then (print_string "yes"; 1) else (print_string "no"; 2);; let () = print_int n;;|};
  [%expect {|
    success=true stdout="4"
    success=true stdout="yes1"
    |}]

let%expect_test
    "dead code removes unused total arithmetic but retains effects and traps" =
  let source = {|let unused = 2 + 3;; let () = print_string "effect";;|} in
  let primitive, _, _ = counts (Opt_dce.program (anf source)).value.body in
  assert (primitive = 0);
  observe { Optimize.none with dead_code = true } source;
  observe { Optimize.none with dead_code = true } {|let unused = 1 / 0;;|};
  [%expect
    {|
    success=true stdout="effect"
    success=false stdout=""
    |}]

let%expect_test
    "dead recursive groups preserve transitive peers of a live member" =
  observe
    { Optimize.none with dead_code = true }
    {|let rec even n = if n = 0 then true else odd (n-1) and odd n = if n = 0 then false else even (n-1);;
      let rec unused n = unused n;; let () = if even 10 then print_string "even" else print_string "odd";;|};
  [%expect {| success=true stdout="even" |}]

let%expect_test
    "small nonrecursive functions inline independently and retain lexical \
     capture" =
  let source =
    {|let x = 10;; let add n = x + n;; let a = add 20;; let x = 900;; let b = add 12;; let () = print_int (a+b);;|}
  in
  let original = anf source in
  let _, before, _ = counts original.value.body in
  let optimized = Opt_inline.program original in
  let _, after, _ = counts optimized.value.body in
  assert (after < before && optimized.value.next_id > original.value.next_id);
  observe { Optimize.none with inline = true } source;
  [%expect {| success=true stdout="52" |}]

let%expect_test
    "inlining evaluates arguments once even when the parameter is used twice" =
  observe
    { Optimize.none with inline = true }
    {|let twice n = n+n;; let mark () = print_string "once"; 21;; let () = print_int (twice (mark ()));;|};
  [%expect {| success=true stdout="once42" |}]

let%expect_test "recursive functions are not inlining candidates" =
  let source = "let rec f n = if n = 0 then 1 else f (n-1);; let x = f 2;;" in
  let original = anf source in
  assert (Anf.equal_program original (Opt_inline.program original));
  print_endline "recursive calls remain shared";
  [%expect {| recursive calls remain shared |}]

let%expect_test "large nonrecursive functions are not inlining candidates" =
  let additions = String.concat "+" (List.init 24 (fun _ -> "x")) in
  let source = anf ("let large x = " ^ additions ^ ";; let n = large 2;;") in
  assert (Anf.equal_program source (Opt_inline.program source));
  print_endline "body above the inline budget remains shared";
  [%expect {| body above the inline budget remains shared |}]

let%expect_test
    "inlining freshens nested lambdas, case joins and formals across copies" =
  let source =
    {|type 'a option = None | Some of 'a;;
    let choose x = fun value -> match value with None -> x | Some y -> x+y;;
    let a = choose 10;; let b = choose 20;; let () = print_int (a (Some 7) + b None);;|}
  in
  let original = anf source in
  let optimized = Opt_inline.program original in
  assert (optimized.value.next_id > original.value.next_id);
  unique_binders optimized;
  observe { Optimize.none with inline = true } source;
  [%expect {| success=true stdout="37" |}]

let%expect_test
    "known-constructor decisions simplify without constant or DCE passes" =
  let source =
    {|type 'a option = None | Some of 'a;;
    let value = Some (20,22);; let () = match value with None -> print_int 0 | Some (a,b) -> print_int (a+b);;|}
  in
  let original = anf source in
  let _, _, before = counts original.value.body in
  let optimized = Opt_match.program original in
  let _, _, after = counts optimized.value.body in
  assert (after < before);
  observe { Optimize.none with matches = true } source;
  [%expect {| success=true stdout="42" |}]

let%expect_test
    "match simplification retains whole-value fallbacks and subject effects" =
  observe Optimize.all
    {|type 'a option = None | Some of 'a;; let n = (print_string "s"; 7);;
      let value = Some n;; let () = match value with Some 0 -> print_int 0 | whole ->
        (match whole with None -> print_int 0 | Some n -> print_int n);;|};
  [%expect {| success=true stdout="s7" |}]

let%expect_test "optimized IR remains deterministic with all passes enabled" =
  let source = anf "let inc x = x+1;; let result = inc (1+2);;" in
  assert (
    Anf.equal_program
      (Optimize.program Optimize.all source)
      (Optimize.program Optimize.all source));
  observe Optimize.all {|let inc x = x+1;; let () = print_int (inc (1+2));;|};
  [%expect {| success=true stdout="4" |}]
