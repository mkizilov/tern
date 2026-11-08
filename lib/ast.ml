type position = { line : int; column : int; byte_offset : int }
[@@deriving show { with_path = false }, eq]

type span = { file : string; start_pos : position; end_pos : position }
[@@deriving show { with_path = false }, eq]

type 'a located = { value : 'a; span : span [@equal fun _ _ -> true] }
[@@deriving show { with_path = false }, eq]

type name = string located [@@deriving show { with_path = false }, eq]

type literal = Int of int32 | Bool of bool | String of string | Unit
[@@deriving show { with_path = false }, eq]

type rec_flag = Nonrecursive | Recursive
[@@deriving show { with_path = false }, eq]

type unary_op = Negate [@@deriving show { with_path = false }, eq]

type binary_op =
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
  | And
  | Or
[@@deriving show { with_path = false }, eq]

type type_expr = type_expr_desc located

and type_expr_desc =
  | Type_variable of name
  | Type_constructor of name * type_expr list
  | Type_arrow of type_expr * type_expr
  | Type_tuple of type_expr list
[@@deriving show { with_path = false }, eq]

type pattern = pattern_desc located

and pattern_desc =
  | P_wildcard
  | P_variable of name
  | P_literal of literal
  | P_tuple of pattern list
  | P_constructor of name * pattern option
[@@deriving show { with_path = false }, eq]

type expr = expr_desc located

and expr_desc =
  | E_literal of literal
  | E_variable of name
  | E_constructor of name
  | E_lambda of pattern * expr
  | E_apply of expr * expr
  | E_let of rec_flag * binding list * expr
  | E_if of expr * expr * expr
  | E_tuple of expr list
  | E_match of expr * case list
  | E_unary of unary_op located * expr
  | E_binary of binary_op located * expr * expr
  | E_sequence of expr * expr

and binding = binding_desc located

and binding_desc = { binding_pattern : pattern; binding_body : expr }

and case = case_desc located

and case_desc = { case_pattern : pattern; case_body : expr }
[@@deriving show { with_path = false }, eq]

type constructor_decl = constructor_decl_desc located

and constructor_decl_desc = {
  constructor_name : name;
  constructor_payload : type_expr option;
}
[@@deriving show { with_path = false }, eq]

type type_decl = type_decl_desc located

and type_decl_desc = {
  type_name : name;
  type_parameters : name list;
  type_constructors : constructor_decl list;
}
[@@deriving show { with_path = false }, eq]

type declaration = declaration_desc located

and declaration_desc =
  | D_let of rec_flag * binding list
  | D_type of type_decl
[@@deriving show { with_path = false }, eq]

type program = declaration list located
[@@deriving show { with_path = false }, eq]
