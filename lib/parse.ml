type error = Diagnostic.t
[@@deriving show { with_path = false }]

let token (token : Token.t) =
  match token.value with
  | Token.Let -> Grammar.LET token
  | Rec -> REC token
  | And -> AND token
  | In -> IN token
  | Fun -> FUN token
  | If -> IF token
  | Then -> THEN token
  | Else -> ELSE token
  | Type -> TYPE token
  | Of -> OF token
  | Match -> MATCH token
  | With -> WITH token
  | True -> TRUE token
  | False -> FALSE token
  | Mod -> MOD token
  | Identifier _ -> IDENTIFIER token
  | Constructor _ -> CONSTRUCTOR token
  | Type_variable _ -> TYPE_VARIABLE token
  | Integer _ -> INTEGER token
  | String _ -> STRING token
  | Underscore -> UNDERSCORE token
  | Lparen -> LPAREN token
  | Rparen -> RPAREN token
  | Comma -> COMMA token
  | Semicolon -> SEMICOLON token
  | Double_semicolon -> DOUBLE_SEMICOLON token
  | Arrow -> ARROW token
  | Bar -> BAR token
  | Plus -> PLUS token
  | Minus -> MINUS token
  | Star -> STAR token
  | Slash -> SLASH token
  | Caret -> CARET token
  | Equal -> EQUAL token
  | Not_equal -> NOT_EQUAL token
  | Less -> LESS token
  | Less_equal -> LESS_EQUAL token
  | Greater -> GREATER token
  | Greater_equal -> GREATER_EQUAL token
  | And_and -> AND_AND token
  | Or_or -> OR_OR token
  | Eof -> EOF token

let program ~file source =
  let position : Ast.position = { line = 1; column = 0; byte_offset = 0 } in
  let span : Ast.span = { file; start_pos = position; end_pos = position } in
  let last : Token.t ref = ref { value = Token.Eof; span } in
  let beginnings = ref [ 0 ] in
  String.iteri
    (fun index character ->
      if character = '\n'
         || (character = '\r'
             && (index + 1 = String.length source || source.[index + 1] <> '\n'))
      then beginnings := (index + 1) :: !beginnings)
    source;
  let beginnings = Array.of_list (List.rev !beginnings) in
  let lexing_position (position : Ast.position) : Lexing.position =
    { pos_fname = file;
      pos_lnum = position.line;
      pos_bol = beginnings.(position.line - 1);
      pos_cnum = position.byte_offset }
  in
  try
    let lexer = Lexer.create ~file source in
    let module I = Grammar.MenhirInterpreter in
    let rec loop checkpoint =
      match checkpoint with
      | I.InputNeeded _ ->
          let next = Lexer.next lexer in
          last := next;
          loop
            (I.offer checkpoint
               (token next, lexing_position next.span.start_pos,
                lexing_position next.span.end_pos))
      | I.Shifting _ | I.AboutToReduce _ -> loop (I.resume checkpoint)
      | I.Accepted program -> Ok program
      | I.HandlingError environment ->
          let message =
            try
              Grammar_messages.message (I.current_state_number environment)
              |> String.trim
            with Not_found ->
              "unexpected " ^ Token.show_kind (!last).value
              ^ "; check the surrounding expression or declaration"
          in
          Error (Diagnostic.make (!last).span message)
      | I.Rejected ->
          Error (Diagnostic.make (!last).span "expected a complete Tern program")
    in
    loop (Grammar.Incremental.program (lexing_position position))
  with
  | Diagnostic.Raised error -> Error error
