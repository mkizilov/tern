open Tern

let usage = "Usage: ternc check [--types] FILE.tern"

let run arguments =
  let types = ref false in
  let filename = ref None in
  let anonymous file =
    match !filename with
    | None -> filename := Some file
    | Some _ -> raise (Arg.Bad "expected exactly one input file")
  in
  let arguments = Array.of_list (Sys.argv.(0) :: arguments) in
  Arg.parse_argv arguments
    [ "--types", Arg.Set types, " print top-level inferred types" ] anonymous usage;
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
  | source ->
      (match Check.source ~file source with
      | Error diagnostic ->
          report (fun requested -> if requested = file then Some source else None) diagnostic
      | Ok result ->
          if !types then print_string (Infer.format_bindings result);
          0)
  | exception Sys_error message ->
      let position : Ast.position = { line = 1; column = 0; byte_offset = 0 } in
      let span : Ast.span = { file; start_pos = position; end_pos = position } in
      report (fun _ -> None) (Diagnostic.make span ("cannot read input: " ^ message))

let () =
  let status =
    try
      match Array.to_list Sys.argv with
      | _ :: "check" :: arguments -> run arguments
      | _ :: ("--help" | "-help") :: [] -> print_endline usage; 0
      | _ -> prerr_endline usage; 2
    with
    | Arg.Bad message -> prerr_endline message; 2
    | Arg.Help message -> print_string message; 0
  in
  exit status
