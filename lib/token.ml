type kind =
  | Let
  | Rec
  | And
  | In
  | Fun
  | If
  | Then
  | Else
  | Type
  | Of
  | Match
  | With
  | True
  | False
  | Mod
  | Identifier of string
  | Constructor of string
  | Type_variable of string
  | Integer of int64
  | String of string
  | Underscore
  | Lparen
  | Rparen
  | Comma
  | Semicolon
  | Double_semicolon
  | Arrow
  | Bar
  | Plus
  | Minus
  | Star
  | Slash
  | Caret
  | Equal
  | Not_equal
  | Less
  | Less_equal
  | Greater
  | Greater_equal
  | And_and
  | Or_or
  | Eof
[@@deriving show { with_path = false }]

type t = kind Ast.located [@@deriving show { with_path = false }]
