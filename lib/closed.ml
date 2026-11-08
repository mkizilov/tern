type atom = Anf.atom [@@deriving show { with_path = false }, eq]

type expr = expr_desc Ast.located

and expr_desc =
  | Return of atom
  | Let of Core.name * rhs * expr
  | Joins of join list * expr
  | Jump of Core.name * atom list
  | If of atom * expr * expr
  | Switch of atom * (Anf.key * expr) list * expr
  | Fail of string

and rhs = rhs_desc Ast.located

and rhs_desc =
  | Alias of atom
  | Closure_call of atom * atom
  | Direct_call of int * atom * atom
  | Primitive of Core.primitive Ast.located * atom list
  | Tuple of atom list
  | Variant of Core.name * atom option
  | Field of atom * int
  | Payload of atom
  | Block of expr
  | Environment of atom list
  | Allocate_environment of int
  | Environment_set of atom * int * atom
  | Environment_get of atom * int
  | Closure of int * atom
  | Closure_environment of atom
  | Builtin_apply of Core.builtin * atom

and join = join_desc Ast.located

and join_desc = {
  label : Core.name;
  parameters : Core.name list;
  action : expr;
}
[@@deriving show { with_path = false }, eq]

type function_definition = function_desc Ast.located

and function_desc = {
  index : int;
  name : Core.name;
  environment : Core.name;
  parameter : Core.name;
  captures : Core.name list;
  layout : Core.name list;
  body : expr;
}
[@@deriving show { with_path = false }, eq]

type program = program_desc Ast.located

and program_desc = {
  next_id : int;
  functions : function_definition list;
  builtins : (Core.name * int) list;
  types : Core.type_decl list;
  body : expr;
}
[@@deriving show { with_path = false }, eq]
