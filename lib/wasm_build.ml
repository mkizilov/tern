let temporary_root () =
  let root =
    match Sys.getenv_opt "TMPDIR" with
    | Some root -> root
    | None -> Filename.concat (Sys.getcwd ()) ".agent-local/tmp"
  in
  if not (Sys.file_exists root) then (
    let parent = Filename.dirname root in
    if not (Sys.file_exists parent) then Unix.mkdir parent 0o700;
    Unix.mkdir root 0o700);
  root

let workspace action =
  let directory =
    Filename.temp_dir ~temp_dir:(temporary_root ()) "tern-build-" ""
  in
  Fun.protect
    ~finally:(fun () ->
      Array.iter
        (fun file -> Sys.remove (Filename.concat directory file))
        (Sys.readdir directory);
      Unix.rmdir directory)
    (fun () -> action directory)

let write file text =
  Out_channel.with_open_bin file (fun channel -> output_string channel text)

let run_tool span directory arguments =
  let log = Filename.concat directory "tool.log" in
  let descriptor =
    Unix.openfile log [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC ] 0o600
  in
  let status =
    Fun.protect
      ~finally:(fun () -> Unix.close descriptor)
      (fun () ->
        let environment =
          Unix.environment () |> Array.to_list
          |> List.filter (fun value ->
              not (String.starts_with ~prefix:"RAYON_NUM_THREADS=" value))
        in
        let pid =
          Unix.create_process_env "wasm-tools"
            (Array.of_list ("wasm-tools" :: arguments))
            (Array.of_list ("RAYON_NUM_THREADS=2" :: environment))
            Unix.stdin descriptor descriptor
        in
        snd (Unix.waitpid [] pid))
  in
  match status with
  | Unix.WEXITED 0 -> ()
  | status ->
      let output =
        In_channel.with_open_bin log In_channel.input_all |> String.trim
      in
      let status =
        match status with
        | Unix.WEXITED code -> "exit " ^ string_of_int code
        | _ -> "terminated by signal"
      in
      Diagnostic.fail span
        ("wasm-tools " ^ List.hd arguments ^ " failed (" ^ status ^ "): "
       ^ output)

let assemble span directory wat =
  let source = Filename.concat directory "program.wat" in
  let binary = Filename.concat directory "program.wasm" in
  write source wat;
  run_tool span directory [ "parse"; source; "-o"; binary ];
  run_tool span directory [ "validate"; binary ];
  binary

let protect span action =
  try Ok (action ()) with
  | Diagnostic.Raised diagnostic -> Error diagnostic
  | Sys_error message ->
      Error (Diagnostic.make span ("Wasm build failed: " ^ message))
  | Unix.Unix_error (error, operation, target) ->
      Error
        (Diagnostic.make span
           ("Wasm build failed: " ^ operation
           ^ (if target = "" then "" else " " ^ target)
           ^ ": " ^ Unix.error_message error))

let emit (checked : Check.checked) =
  Wat.program (Closure_convert.program (Lower.program checked))

let build ~output (checked : Check.checked) =
  match emit checked with
  | Error diagnostic -> Error diagnostic
  | Ok wat ->
      protect checked.core.span (fun () ->
          (if Sys.file_exists output && Sys.file_exists checked.core.span.file
           then
             let input = Unix.stat checked.core.span.file
             and target = Unix.stat output in
             if input.st_dev = target.st_dev && input.st_ino = target.st_ino
             then
               Diagnostic.fail checked.core.span
                 "output would overwrite the input source");
          workspace (fun directory ->
              let binary = assemble checked.core.span directory wat in
              let temporary =
                Filename.temp_file ~temp_dir:(Filename.dirname output)
                  ".tern-output-" ".wasm"
              in
              Fun.protect
                ~finally:(fun () ->
                  if Sys.file_exists temporary then Sys.remove temporary)
                (fun () ->
                  write temporary
                    (In_channel.with_open_bin binary In_channel.input_all);
                  Sys.rename temporary output)))

let run (checked : Check.checked) =
  match emit checked with
  | Error diagnostic -> Error diagnostic
  | Ok wat ->
      protect checked.core.span (fun () ->
          workspace (fun directory ->
              let binary = assemble checked.core.span directory wat in
              let host = Filename.concat directory "run.mjs" in
              write host Runtime_assets.host;
              flush stdout;
              flush stderr;
              let pid =
                Unix.create_process "node" [| "node"; host; binary |] Unix.stdin
                  Unix.stdout Unix.stderr
              in
              match snd (Unix.waitpid [] pid) with
              | Unix.WEXITED status -> status
              | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> 1))
