type error = Lexical of Lexer.error | Syntax of Parse_error.t
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
  try
    let lexer = Lexer.create ~file source in
    let supply _ =
      let next = Lexer.next lexer in
      last := next;
      token next
    in
    Ok (Grammar.program supply (Lexing.from_string ""))
  with
  | Lexer.Error error -> Error (Lexical error)
  | Parse_error.Error error -> Error (Syntax error)
  | Grammar.Error ->
      Error
        (Syntax
           { message = "unexpected " ^ Token.show_kind (!last).value;
             span = (!last).span })
