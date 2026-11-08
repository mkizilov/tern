type severity = Error | Warning | Note [@@deriving show { with_path = false }]

type label = { span : Ast.span; message : string option }
[@@deriving show { with_path = false }]

type t = {
  severity : severity;
  message : string;
  primary : Ast.span;
  secondary : label list;
  notes : string list;
}
[@@deriving show { with_path = false }]

exception Raised of t

let make ?(severity = Error) ?(secondary = []) ?(notes = []) primary message =
  { severity; message; primary; secondary; notes }

let fail ?secondary ?notes primary message =
  raise (Raised (make ?secondary ?notes primary message))

let lines source =
  let length = String.length source in
  let rec loop start index acc =
    if index = length then
      Array.of_list (List.rev (String.sub source start (index - start) :: acc))
    else
      match source.[index] with
      | '\r' | '\n' ->
          let next =
            if
              source.[index] = '\r'
              && index + 1 < length
              && source.[index + 1] = '\n'
            then index + 2
            else index + 1
          in
          loop next next (String.sub source start (index - start) :: acc)
      | _ -> loop start (index + 1) acc
  in
  loop 0 0 []

(* Map scalar boundaries to terminal columns, not UTF-8 byte offsets. *)
let display_line line =
  let buffer = Buffer.create (String.length line) in
  let rec loop byte column boundaries =
    if byte = String.length line then
      (Buffer.contents buffer, Array.of_list (List.rev boundaries))
    else
      let decoded = String.get_utf_8_uchar line byte in
      let text, width, bytes =
        if not (Uchar.utf_decode_is_valid decoded) then
          let text = Printf.sprintf "\\x%02X" (Char.code line.[byte]) in
          (text, String.length text, 1)
        else
          let uchar = Uchar.utf_decode_uchar decoded in
          let code = Uchar.to_int uchar in
          let bytes = Uchar.utf_decode_length decoded in
          if code = 9 then
            let width = 4 - (column mod 4) in
            (String.make width ' ', width, bytes)
          else if
            code < 32
            || (code >= 127 && code <= 159)
            || Uucp.Gc.general_category uchar = `Cf
            || code = 0x2028 || code = 0x2029
          then
            let text = Printf.sprintf "\\u{%x}" code in
            (text, String.length text, bytes)
          else
            ( String.sub line byte bytes,
              max 0 (Uucp.Break.tty_width_hint uchar),
              bytes )
      in
      Buffer.add_string buffer text;
      loop (byte + bytes) (column + width) ((column + width) :: boundaries)
  in
  loop 0 0 [ 0 ]

let severity_name = function
  | Error -> "error"
  | Warning -> "warning"
  | Note -> "note"

let severity_color = function Error -> "31" | Warning -> "33" | Note -> "34"

let render ?(color = false) ~source diagnostic =
  let buffer = Buffer.create 256 in
  let add = Buffer.add_string buffer in
  let safe text = fst (display_line text) in
  let paint code text =
    if color then "\027[1;" ^ code ^ "m" ^ text ^ "\027[0m" else text
  in
  add
    (paint
       (severity_color diagnostic.severity)
       (severity_name diagnostic.severity));
  add (": " ^ safe diagnostic.message ^ "\n");
  let frame primary (span : Ast.span) label =
    add
      ((if primary then " --> " else " ::: ")
      ^ safe span.file ^ ":"
      ^ string_of_int span.start_pos.line
      ^ ":"
      ^ string_of_int (span.start_pos.column + 1)
      ^ "\n");
    match source span.file with
    | None -> add " = note: source unavailable\n"
    | Some source ->
        let source = lines source in
        let first = span.start_pos.line in
        let last =
          if span.end_pos.line > first && span.end_pos.column = 0 then
            span.end_pos.line - 1
          else span.end_pos.line
        in
        if first < 1 || first > Array.length source || last < first then
          add " = note: source line unavailable\n"
        else
          let last = min last (Array.length source) in
          let gutter = String.length (string_of_int last) in
          let margin = String.make gutter ' ' ^ " |" in
          add (margin ^ "\n");
          let excerpt line =
            let text, columns = display_line source.(line - 1) in
            let column index =
              columns.(max 0 (min index (Array.length columns - 1)))
            in
            let start =
              if line = first then column span.start_pos.column else 0
            in
            let stop =
              if line = span.end_pos.line then column span.end_pos.column
              else columns.(Array.length columns - 1)
            in
            add
              (Printf.sprintf "%*d |%s\n" gutter line
                 (if text = "" then "" else " " ^ text));
            add (margin ^ " " ^ String.make start ' ');
            let mark = if primary then '^' else '-' in
            add
              (paint
                 (if primary then severity_color diagnostic.severity else "34")
                 (String.make (max 1 (stop - start)) mark));
            if line = last then
              Option.iter (fun label -> add (" " ^ safe label)) label;
            add "\n"
          in
          excerpt first;
          if last > first + 1 then add (margin ^ " ...\n");
          if last > first then excerpt last
  in
  frame true diagnostic.primary None;
  List.iter
    (fun label -> frame false label.span label.message)
    diagnostic.secondary;
  List.iter (fun note -> add (" = note: " ^ safe note ^ "\n")) diagnostic.notes;
  Buffer.contents buffer

let emit ?(channel = stdout) ?color ~source diagnostic =
  let color =
    match color with
    | Some color -> color
    | None -> Unix.isatty (Unix.descr_of_out_channel channel)
  in
  output_string channel (render ~color ~source diagnostic);
  flush channel
