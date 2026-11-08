type error_kind =
  | Unterminated_string
  | Unterminated_comment
  | Invalid_escape of string
  | Control_character of int
  | Invalid_character of string
  | Integer_out_of_range
  | Invalid_utf8
[@@deriving show { with_path = false }]

type error = Diagnostic.t
[@@deriving show { with_path = false }]

exception Error = Diagnostic.Raised

type t = { lexbuf : Sedlexing.lexbuf }

let fail kind span =
  let message, notes =
    match kind with
    | Unterminated_string ->
        "unterminated string", [ "close the string with a double quote" ]
    | Unterminated_comment ->
        "unterminated comment", [ "close every nested comment with `*)`" ]
    | Invalid_escape escape ->
        Printf.sprintf "invalid escape %S" escape,
        [ "valid escapes are \\n, \\r, \\t, \\\", and \\\\" ]
    | Control_character code -> Printf.sprintf "control character U+%04X" code, []
    | Invalid_character character -> Printf.sprintf "invalid character %S" character, []
    | Integer_out_of_range ->
        "integer out of range", [ "Tern integers range from -2147483648 to 2147483647" ]
    | Invalid_utf8 -> "invalid UTF-8", [ "source files must be valid UTF-8" ]
  in
  Diagnostic.fail ~notes span message

let validate_utf8 ~file source =
  let length = String.length source in
  let rec loop byte_offset line column =
    if byte_offset < length then
      let decoded = String.get_utf_8_uchar source byte_offset in
      if not (Uchar.utf_decode_is_valid decoded) then
        let start_pos : Ast.position = { line; column; byte_offset } in
        let end_pos =
          { start_pos with byte_offset = byte_offset + 1; column = column + 1 }
        in
        fail Invalid_utf8 { file; start_pos; end_pos }
      else
        let width = Uchar.utf_decode_length decoded in
        match Uchar.to_int (Uchar.utf_decode_uchar decoded) with
        | 13 when byte_offset + 1 < length && source.[byte_offset + 1] = '\n' ->
            loop (byte_offset + 2) (line + 1) 0
        | 10 | 13 -> loop (byte_offset + width) (line + 1) 0
        | _ -> loop (byte_offset + width) line (column + 1)
  in
  loop 0 1 0

let create ~file source =
  validate_utf8 ~file source;
  let lexbuf = Sedlexing.Utf8.from_string source in
  Sedlexing.set_filename lexbuf file;
  { lexbuf }

let span lexbuf =
  let first, last = Sedlexing.lexing_positions lexbuf in
  let first_byte, last_byte = Sedlexing.lexing_bytes_positions lexbuf in
  let position (p : Lexing.position) (byte : Lexing.position) : Ast.position =
    { line = p.pos_lnum;
      column = p.pos_cnum - p.pos_bol;
      byte_offset = byte.pos_cnum }
  in
  { Ast.file = first.pos_fname;
    start_pos = position first first_byte;
    end_pos = position last last_byte }

let emit lexbuf value = { Ast.value; span = span lexbuf }

let identifier = function
  | "let" -> Token.Let
  | "rec" -> Rec
  | "and" -> And
  | "in" -> In
  | "fun" -> Fun
  | "if" -> If
  | "then" -> Then
  | "else" -> Else
  | "type" -> Type
  | "of" -> Of
  | "match" -> Match
  | "with" -> With
  | "true" -> True
  | "false" -> False
  | "mod" -> Mod
  | "_" -> Underscore
  | name -> Identifier name

let integer lexbuf =
  let digits = Sedlexing.Utf8.lexeme lexbuf in
  let rec first_nonzero i =
    if i < String.length digits - 1 && digits.[i] = '0' then first_nonzero (i + 1)
    else i
  in
  let first = first_nonzero 0 in
  let magnitude = String.sub digits first (String.length digits - first) in
  if String.length magnitude > 10
     || (String.length magnitude = 10 && String.compare magnitude "2147483648" > 0)
  then fail Integer_out_of_range (span lexbuf);
  (* The parser needs this extra magnitude for the literal -2147483648. *)
  emit lexbuf (Token.Integer (Int64.of_string magnitude))

let lower_start = [%sedlex.regexp? 'a' .. 'z' | '_']
let upper_start = [%sedlex.regexp? 'A' .. 'Z']
let ident_rest = [%sedlex.regexp? lower_start | upper_start | '0' .. '9' | '\'']

let rec comment lexbuf opening depth =
  match%sedlex lexbuf with
  | "(*" -> comment lexbuf opening (depth + 1)
  | "*)" -> if depth > 1 then comment lexbuf opening (depth - 1)
  | "\r\n" | '\n' -> comment lexbuf opening depth
  | '\r' ->
      Sedlexing.new_line lexbuf;
      comment lexbuf opening depth
  | eof -> fail Unterminated_comment opening
  | any -> comment lexbuf opening depth
  | _ -> assert false

let rec string_literal lexbuf opening buffer =
  match%sedlex lexbuf with
  | '"' ->
      let ending = span lexbuf in
      { Ast.value = Token.String (Buffer.contents buffer);
        span = { opening with end_pos = ending.end_pos } }
  | "\\n" ->
      Buffer.add_char buffer '\n';
      string_literal lexbuf opening buffer
  | "\\r" ->
      Buffer.add_char buffer '\r';
      string_literal lexbuf opening buffer
  | "\\t" ->
      Buffer.add_char buffer '\t';
      string_literal lexbuf opening buffer
  | "\\\"" ->
      Buffer.add_char buffer '"';
      string_literal lexbuf opening buffer
  | "\\\\" ->
      Buffer.add_char buffer '\\';
      string_literal lexbuf opening buffer
  | '\\' -> escape lexbuf opening (span lexbuf)
  | eof -> fail Unterminated_string opening
  | 0x00 .. 0x1f | 0x7f .. 0x9f ->
      if Uchar.to_int (Sedlexing.lexeme_char lexbuf 0) = 13 then
        Sedlexing.new_line lexbuf;
      fail
        (Control_character (Uchar.to_int (Sedlexing.lexeme_char lexbuf 0)))
        (span lexbuf)
  | any ->
      Buffer.add_string buffer (Sedlexing.Utf8.lexeme lexbuf);
      string_literal lexbuf opening buffer
  | _ -> assert false

and escape lexbuf opening slash =
  match%sedlex lexbuf with
  | eof -> fail Unterminated_string opening
  | any ->
      if Uchar.to_int (Sedlexing.lexeme_char lexbuf 0) = 13 then
        Sedlexing.new_line lexbuf;
      let ending = span lexbuf in
      fail (Invalid_escape ("\\" ^ Sedlexing.Utf8.lexeme lexbuf))
        { slash with end_pos = ending.end_pos }
  | _ -> assert false

let rec next lexer =
  let lexbuf = lexer.lexbuf in
  match%sedlex lexbuf with
  | Plus (' ' | '\t' | '\011' | '\012') -> next lexer
  | "\r\n" | '\n' -> next lexer
  | '\r' ->
      Sedlexing.new_line lexbuf;
      next lexer
  | "(*" ->
      comment lexbuf (span lexbuf) 1;
      next lexer
  | lower_start, Star ident_rest ->
      emit lexbuf (identifier (Sedlexing.Utf8.lexeme lexbuf))
  | upper_start, Star ident_rest ->
      emit lexbuf (Token.Constructor (Sedlexing.Utf8.lexeme lexbuf))
  | '\'', lower_start, Star ident_rest ->
      let name = Sedlexing.Utf8.lexeme lexbuf in
      emit lexbuf (Token.Type_variable (String.sub name 1 (String.length name - 1)))
  | Plus ('0' .. '9') -> integer lexbuf
  | '"' -> string_literal lexbuf (span lexbuf) (Buffer.create 32)
  | '(' -> emit lexbuf Token.Lparen
  | ')' -> emit lexbuf Token.Rparen
  | ',' -> emit lexbuf Token.Comma
  | ";;" -> emit lexbuf Token.Double_semicolon
  | ';' -> emit lexbuf Token.Semicolon
  | "->" -> emit lexbuf Token.Arrow
  | "||" -> emit lexbuf Token.Or_or
  | '|' -> emit lexbuf Token.Bar
  | '+' -> emit lexbuf Token.Plus
  | '-' -> emit lexbuf Token.Minus
  | '*' -> emit lexbuf Token.Star
  | '/' -> emit lexbuf Token.Slash
  | '^' -> emit lexbuf Token.Caret
  | '=' -> emit lexbuf Token.Equal
  | "<>" -> emit lexbuf Token.Not_equal
  | "<=" -> emit lexbuf Token.Less_equal
  | '<' -> emit lexbuf Token.Less
  | ">=" -> emit lexbuf Token.Greater_equal
  | '>' -> emit lexbuf Token.Greater
  | "&&" -> emit lexbuf Token.And_and
  | eof -> emit lexbuf Token.Eof
  | any -> fail (Invalid_character (Sedlexing.Utf8.lexeme lexbuf)) (span lexbuf)
  | _ -> assert false

let lex ~file source =
  try
    let lexer = create ~file source in
    let rec loop acc =
      let token = next lexer in
      match token.Ast.value with
      | Token.Eof -> Ok (List.rev (token :: acc))
      | _ -> loop (token :: acc)
    in
    loop []
  with Error error -> Result.Error error
