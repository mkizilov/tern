open Tern_diff

let validate_generated term =
  match Tern.Check.prepare ~file:"generated.tern" (Program_gen.source term) with
  | Ok _ -> true
  | Error diagnostic ->
      QCheck.Test.fail_report (Tern.Diagnostic.show diagnostic)

let property variants count =
  let coverage = Hashtbl.create 8 in
  let seen = ref 0 in
  QCheck.Test.make ~count
    ~name:
      (if variants then "AST = IR = Wasm: typed variants and matches"
       else "AST = IR = Wasm: typed integer/control/closure programs")
    (Program_gen.arbitrary ~variants)
    (fun term ->
      incr seen;
      List.iter
        (fun feature ->
          Hashtbl.replace coverage feature
            (1 + Option.value (Hashtbl.find_opt coverage feature) ~default:0))
        (Program_gen.features term);
      ignore (validate_generated term);
      let source = Program_gen.source term in
      let result = Differential.execute ~file:"generated.tern" source in
      if Differential.agrees result then (
        if !seen = count then (
          Hashtbl.to_seq coverage |> List.of_seq |> List.sort Stdlib.compare
          |> List.iter (fun (name, count) ->
              Printf.printf "coverage %s=%d " name count);
          print_newline ());
        true)
      else QCheck.Test.fail_report (Differential.describe result))

let shrinking =
  QCheck.Test.make ~count:500
    ~name:"typed shrink candidates remain well typed and strictly smaller"
    (Program_gen.arbitrary ~variants:true) (fun term ->
      ignore (validate_generated term);
      Program_gen.shrink term (fun candidate ->
          assert (
            (Program_gen.size candidate, Program_gen.cost candidate)
            < (Program_gen.size term, Program_gen.cost term));
          ignore (validate_generated candidate));
      true)

let () =
  List.iter
    (fun (name, flags) ->
      ignore (Differential.corpus ~optimizations:flags "../../examples");
      ignore (Differential.corpus ~optimizations:flags "../../tests/programs");
      Printf.printf "isolated pass corpus: %s passed\n%!" name)
    [
      ("baseline", Tern.Optimize.none);
      ("constants", { Tern.Optimize.none with constants = true });
      ("dce", { Tern.Optimize.none with dead_code = true });
      ("inline", { Tern.Optimize.none with inline = true });
      ("matches", { Tern.Optimize.none with matches = true });
    ];
  let examples = Differential.corpus "../../examples" in
  let programs = Differential.corpus "../../tests/programs" in
  Printf.printf
    "Differential corpus: %d examples, %d programs; AST = IR = Wasm\n%!"
    examples programs;
  let seed =
    Option.value (Sys.getenv_opt "TERN_DIFF_SEED") ~default:"20261108"
    |> int_of_string
  in
  let count =
    Option.value (Sys.getenv_opt "TERN_DIFF_COUNT") ~default:"150"
    |> int_of_string
  in
  if count < 1 then invalid_arg "TERN_DIFF_COUNT must be positive";
  Printf.printf "QCheck seed=%d; %d cases per execution property\n%!" seed count;
  exit
    (QCheck_base_runner.run_tests ~colors:false ~verbose:false
       ~rand:(Random.State.make [| seed |])
       [ shrinking; property false count; property true count ])
