open Tern_diff

let%expect_test "a timed-out owned host is killed and reaped" =
  Differential.with_workspace (fun directory ->
      let log =
        Unix.openfile
          (Filename.concat directory "timeout.log")
          [ Unix.O_WRONLY; Unix.O_CREAT ]
          0o600
      in
      Fun.protect
        ~finally:(fun () -> Unix.close log)
        (fun () ->
          let pid =
            Unix.create_process "node"
              [| "node"; "-e"; "for (;;) {}" |]
              Unix.stdin log log
          in
          (try
             ignore (Differential.await ~timeout:0.05 pid);
             assert false
           with Failure message -> print_endline message);
          try
            ignore (Unix.waitpid [ Unix.WNOHANG ] pid);
            assert false
          with Unix.Unix_error (Unix.ECHILD, _, _) ->
            print_endline "owned child reaped"));
  [%expect
    {|
    compiled differential case exceeded its time limit
    owned child reaped
    |}]

let%expect_test
    "three-engine comparison includes failure status and partial bytes" =
  let result =
    Differential.check ~file:"error.tern"
      {|let () = print_string "prefix"; print_int (1 / 0);;|}
  in
  Printf.printf "success=%b stdout=%S\n" result.success result.output;
  [%expect {| success=false stdout="prefix" |}]

let%expect_test
    "comparison rejects newline loss and success-status disagreements" =
  let ast : Differential.outcome = { output = "42\n"; success = true } in
  let wrong : Differential.result =
    { ast; ir = ast; wasm = { output = "42"; success = true } }
  in
  assert (not (Differential.agrees wrong));
  let failed = { wrong with wasm = { ast with success = false } } in
  assert (not (Differential.agrees failed));
  print_endline (Differential.describe wrong);
  [%expect
    {|
    AST: success=true stdout="42\n"
    IR: success=true stdout="42\n"
    Wasm: success=true stdout="42"
    |}]

let%expect_test
    "typed shrinking removes a lambda application without losing capture scope"
    =
  let open Program_gen in
  let original =
    make Int
      (Apply
         ( make
             (Arrow (Int, Int))
             (Lambda
                ( 0,
                  Int,
                  make Int
                    (Binary ("+", make Int (Variable 0), make Int (Integer 1l)))
                )),
           make Int (Integer 41l) ))
  in
  shrink original (fun term ->
      match Tern.Check.prepare ~file:"shrink.tern" (source term) with
      | Ok _ -> ()
      | Error diagnostic -> failwith (Tern.Diagnostic.show diagnostic));
  print_endline
    "all typed candidates check; beta shrinking preserves bound names";
  [%expect
    {| all typed candidates check; beta shrinking preserves bound names |}]
