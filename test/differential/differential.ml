open Tern

type outcome = { output : string; success : bool }
type result = { ast : outcome; ir : outcome; wasm : outcome }

let capture evaluator =
  let output = Buffer.create 128 in
  let success =
    match evaluator (Buffer.add_string output) with
    | Ok () -> true
    | Error _ -> false
  in
  { output = Buffer.contents output; success }

let with_workspace action =
  let parent =
    Option.value (Sys.getenv_opt "TMPDIR") ~default:"../../.agent-local/tmp"
  in
  if not (Sys.file_exists parent) then Unix.mkdir parent 0o700;
  let directory = Filename.temp_dir ~temp_dir:parent "tern-differential-" "" in
  Fun.protect
    ~finally:(fun () ->
      Array.iter
        (fun name -> Sys.remove (Filename.concat directory name))
        (Sys.readdir directory);
      Unix.rmdir directory)
    (fun () -> action directory)

let await ?(timeout = 10.) pid =
  let deadline = Unix.gettimeofday () +. timeout in
  let rec loop () =
    match Unix.waitpid [ Unix.WNOHANG ] pid with
    | 0, _ ->
        if Unix.gettimeofday () >= deadline then (
          Unix.kill pid Sys.sigkill;
          ignore (Unix.waitpid [] pid);
          failwith "compiled differential case exceeded its time limit");
        ignore (Unix.select [] [] [] 0.01);
        loop ()
    | _, Unix.WEXITED status -> status
    | _ -> failwith "compiled differential case terminated by signal"
  in
  loop ()

let execute ~file source =
  let checked =
    match Check.prepare ~file source with
    | Ok checked -> checked
    | Error diagnostic ->
        failwith ("invalid differential input: " ^ Diagnostic.show diagnostic)
  in
  let ast = capture (fun write -> Interp.program ~write checked) in
  let closed = Closure_convert.program (Lower.program checked) in
  let ir = capture (fun write -> Ir_interp.closed ~write closed) in
  let wasm =
    with_workspace (fun directory ->
        let binary = Filename.concat directory "case.wasm" in
        (match Wasm_build.build ~output:binary checked with
        | Ok () -> ()
        | Error diagnostic ->
            failwith
              ("differential compilation failed: " ^ Diagnostic.show diagnostic));
        let host = Filename.concat directory "host.mjs" in
        Out_channel.with_open_bin host (fun channel ->
            output_string channel Runtime_assets.host);
        let runner = Filename.concat directory "runner.mjs" in
        Out_channel.with_open_bin runner (fun channel ->
            output_string channel
              "import { readFileSync } from 'node:fs';\n\
               import { instantiate } from './host.mjs';\n\
               const instance = await \
               instantiate(readFileSync(process.argv[2]));\n\
               try { instance.exports._start(); } catch (error) { if (!(error \
               instanceof WebAssembly.RuntimeError)) throw error; \
               process.stderr.write(String(error)); process.exitCode = 17; }\n");
        let output = Filename.concat directory "stdout"
        and errors = Filename.concat directory "stderr" in
        let out =
          Unix.openfile output
            [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC ]
            0o600
        in
        let err =
          Unix.openfile errors
            [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC ]
            0o600
        in
        let status =
          Fun.protect
            ~finally:(fun () ->
              Unix.close out;
              Unix.close err)
            (fun () ->
              let pid =
                Unix.create_process "node"
                  [| "node"; runner; binary |]
                  Unix.stdin out err
              in
              await pid)
        in
        if status <> 0 && status <> 17 then
          failwith
            ("differential host failed: "
            ^ In_channel.with_open_bin errors In_channel.input_all);
        {
          output = In_channel.with_open_bin output In_channel.input_all;
          success = status = 0;
        })
  in
  { ast; ir; wasm }

let agrees result = result.ast = result.ir && result.ast = result.wasm

let describe result =
  let show name result =
    Printf.sprintf "%s: success=%b stdout=%S" name result.success result.output
  in
  String.concat "\n"
    [ show "AST" result.ast; show "IR" result.ir; show "Wasm" result.wasm ]

let check ~file source =
  let result = execute ~file source in
  if not (agrees result) then failwith (describe result);
  result.ast

let corpus directory =
  let rec programs directory =
    Sys.readdir directory |> Array.to_list |> List.sort String.compare
    |> List.concat_map (fun name ->
        let path = Filename.concat directory name in
        if Sys.is_directory path then programs path
        else if Filename.extension path = ".tern" then [ path ]
        else [])
  in
  let files = programs directory in
  List.iter
    (fun file ->
      let source = In_channel.with_open_bin file In_channel.input_all in
      let actual = check ~file source in
      let output = Filename.remove_extension file ^ ".out" in
      if not (Sys.file_exists output) then
        failwith ("missing stdout golden: " ^ output);
      let expected = In_channel.with_open_bin output In_channel.input_all in
      if actual.output <> expected then
        failwith
          (Printf.sprintf "%s: expected %S, got %S" file expected actual.output);
      let status = Filename.remove_extension file ^ ".status" in
      let success =
        if Sys.file_exists status then
          match
            String.trim (In_channel.with_open_bin status In_channel.input_all)
          with
          | "error" -> false
          | "ok" -> true
          | _ -> failwith ("invalid status golden: " ^ status)
        else true
      in
      if actual.success <> success then
        failwith ("wrong success status: " ^ file))
    files;
  List.length files
