type atom = Name of Core.name | Literal of Ast.literal
[@@deriving show { with_path = false }, eq]

type key = Tag of Core.symbol | Constant of Ast.literal
[@@deriving show { with_path = false }, eq]

type expr = expr_desc Ast.located

and expr_desc =
  | Return of atom
  | Let of Core.name * rhs * expr
  | Let_rec of function_binding list * expr
  | Joins of join list * expr
  | Jump of Core.name * atom list
  | If of atom * expr * expr
  | Switch of atom * (key * expr) list * expr
  | Fail of string

and rhs = rhs_desc Ast.located

and rhs_desc =
  | Alias of atom
  | Apply of atom * atom
  | Primitive of Core.primitive Ast.located * atom list
  | Tuple of atom list
  | Constructor of Core.name
  | Lambda of Core.name * expr
  | Field of atom * int
  | Payload of atom
  | Block of expr

and function_binding = function_desc Ast.located

and function_desc = {
  function_name : Core.name;
  parameter : Core.name;
  body : expr;
}

and join = join_desc Ast.located

and join_desc = {
  label : Core.name;
  parameters : Core.name list;
  action : expr;
}
[@@deriving show { with_path = false }, eq]

type program = program_desc Ast.located

and program_desc = {
  next_id : int;
  builtins : (Core.name * Core.builtin) list;
  types : Core.type_decl list;
  body : expr;
}
[@@deriving show { with_path = false }, eq]
