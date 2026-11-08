type symbol = { id : int; spelling : string }
[@@deriving show { with_path = false }, eq]

type name = symbol Ast.located [@@deriving show { with_path = false }, eq]

type builtin = Print_int | Print_string
[@@deriving show { with_path = false }, eq]

type builtin_type = Int_type | Bool_type | String_type | Unit_type
[@@deriving show { with_path = false }, eq]

type primitive =
  | Negate
  | Add
  | Subtract
  | Multiply
  | Divide
  | Remainder
  | Concat
  | Equal
  | Not_equal
  | Less
  | Less_equal
  | Greater
  | Greater_equal
[@@deriving show { with_path = false }, eq]

type pattern = pattern_desc Ast.located

and pattern_desc =
  | Wildcard
  | Bind of name
  | Literal_pattern of Ast.literal
  | Tuple_pattern of pattern list
  | Constructor_pattern of name * pattern option
[@@deriving show { with_path = false }, eq]

type expr = expr_desc Ast.located

and expr_desc =
  | Literal of Ast.literal
  | Variable of name
  | Constructor of name
  | Lambda of name * expr
  | Apply of expr * expr
  | Let of pattern * expr * expr
  | Let_rec of recursive_binding list * expr
  | If of expr * expr * expr
  | Tuple of expr list
  | Match of expr * case list
  | Primitive of primitive Ast.located * expr list

and recursive_binding = recursive_binding_desc Ast.located
and recursive_binding_desc = { recursive_name : name; recursive_body : expr }
and case = case_desc Ast.located

and case_desc = { case_pattern : pattern; case_body : expr }
[@@deriving show { with_path = false }, eq]

type type_expr = type_expr_desc Ast.located

and type_expr_desc =
  | Type_variable of name
  | Type_constructor of name * type_expr list
  | Type_arrow of type_expr * type_expr
  | Type_tuple of type_expr list
[@@deriving show { with_path = false }, eq]

type constructor_decl = constructor_decl_desc Ast.located

and constructor_decl_desc = {
  constructor_name : name;
  constructor_payload : type_expr option;
}
[@@deriving show { with_path = false }, eq]

type type_decl = type_decl_desc Ast.located

and type_decl_desc = {
  type_name : name;
  type_parameters : name list;
  type_constructors : constructor_decl list;
}
[@@deriving show { with_path = false }, eq]

type program = program_desc Ast.located

and program_desc = {
  next_id : int;
  builtins : (name * builtin) list;
  builtin_types : (name * builtin_type) list;
  types : type_decl list;
  body : expr;
}
[@@deriving show { with_path = false }, eq]
