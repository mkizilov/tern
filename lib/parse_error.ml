type t = { message : string; span : Ast.span }
[@@deriving show { with_path = false }]

exception Error of t
