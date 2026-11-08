open Tern

type command = Checking | Interpreting | Dumping_ir | Building

let usage =
  "Usage: ternc check [--types] FILE.tern\n\
  \       ternc build FILE.tern -o FILE.wasm\n\
  \       ternc run [--interp | --ir] FILE.tern\n\
  \       ternc dump-ir [--closed] FILE.tern"

let run command arguments =
  let types = ref false in
  let interp = ref false in
  let ir = ref false in
  let closed = ref false in
  let output = ref None in
  let filename = ref None in
  let anonymous file =
    match !filename with
    | None -> filename := Some file
    | Some _ -> raise (Arg.Bad "expected exactly one input file")
  in
  let arguments = Array.of_list (Sys.argv.(0) :: arguments) in
  let options =
    match command with
    | Checking ->
        [ ("--types", Arg.Set types, " print top-level inferred types") ]
    | Interpreting ->
        [
          ("--interp", Arg.Set interp, " use the reference interpreter");
          ("--ir", Arg.Set ir, " use the ANF interpreter");
        ]
    | Dumping_ir ->
        [ ("--closed", Arg.Set closed, " print closure-converted IR") ]
    | Building ->
        [
          ( "-o",
            Arg.String (fun file -> output := Some file),
            " write validated Wasm" );
        ]
  in
  Arg.parse_argv arguments options anonymous usage;
  if command = Interpreting && !interp && !ir then
    raise (Arg.Bad ("run accepts at most one of --interp or --ir\n" ^ usage));
  if command = Building && !output = None then
    raise (Arg.Bad ("build requires -o FILE.wasm\n" ^ usage));
  let file =
    match !filename with
    | Some file -> file
    | None -> raise (Arg.Bad ("missing input file\n" ^ usage))
  in
  let report source diagnostic =
    Diagnostic.emit ~channel:stderr ~source diagnostic;
    1
  in
  match In_channel.with_open_bin file In_channel.input_all with
  | source -> (
      let lookup requested = if requested = file then Some source else None in
      match Check.prepare ~file source with
      | Error diagnostic -> report lookup diagnostic
      | Ok checked -> (
          List.iter
            (fun warning ->
              Diagnostic.emit ~channel:stderr ~source:lookup warning)
            checked.inferred.warnings;
          match command with
          | Checking ->
              if !types then
                print_string (Infer.format_bindings checked.inferred);
              0
          | Dumping_ir ->
              let ir = Lower.program checked in
              print_string
                (if !closed then
                   Closed_pretty.program (Closure_convert.program ir)
                 else Ir_pretty.program ir);
              0
          | Building -> (
              match Wasm_build.build ~output:(Option.get !output) checked with
              | Ok () -> 0
              | Error diagnostic -> report lookup diagnostic)
          | Interpreting -> (
              let write text =
                output_string stdout text;
                flush stdout
              in
              let result =
                if !interp then
                  Result.map (fun () -> 0) (Interp.program ~write checked)
                else if !ir then
                  Result.map
                    (fun () -> 0)
                    (Ir_interp.closed ~write
                       (Closure_convert.program (Lower.program checked)))
                else Wasm_build.run checked
              in
              match result with
              | Ok status -> status
              | Error diagnostic -> report lookup diagnostic)))
  | exception Sys_error message ->
      let position : Ast.position = { line = 1; column = 0; byte_offset = 0 } in
      let span : Ast.span =
        { file; start_pos = position; end_pos = position }
      in
      report
        (fun _ -> None)
        (Diagnostic.make span ("cannot read input: " ^ message))

let () =
  let status =
    try
      match Array.to_list Sys.argv with
      | _ :: "check" :: arguments -> run Checking arguments
      | _ :: "run" :: arguments -> run Interpreting arguments
      | _ :: "dump-ir" :: arguments -> run Dumping_ir arguments
      | _ :: "build" :: arguments -> run Building arguments
      | [ _; ("--help" | "-help") ] ->
          print_endline usage;
          0
      | _ ->
          prerr_endline usage;
          2
    with
    | Arg.Bad message ->
        prerr_endline message;
        2
    | Arg.Help message ->
        print_string message;
        0
  in
  exit status
