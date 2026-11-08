%{
open Ast
open Parse_support
%}

%token <Token.t> LET REC AND IN FUN IF THEN ELSE TYPE OF MATCH WITH TRUE FALSE MOD
%token <Token.t> IDENTIFIER CONSTRUCTOR TYPE_VARIABLE INTEGER STRING UNDERSCORE
%token <Token.t> LPAREN RPAREN COMMA SEMICOLON DOUBLE_SEMICOLON ARROW BAR
%token <Token.t> PLUS MINUS STAR SLASH CARET EQUAL NOT_EQUAL LESS LESS_EQUAL
%token <Token.t> GREATER GREATER_EQUAL AND_AND OR_OR EOF

/* Control bodies extend right; a bar belongs to the innermost open match. */
%nonassoc CONTROL
%nonassoc BAR
%right SEMICOLON
%right OR_OR
%right AND_AND
%nonassoc EQUAL NOT_EQUAL LESS LESS_EQUAL GREATER GREATER_EQUAL
%right CARET
%left PLUS MINUS
%left STAR SLASH MOD
%nonassoc NEGATE

/* Finish atomic expressions before reporting a missing enclosing keyword. */
%on_error_reduce application_expr

%start <Ast.program> program
%%

program:
  declarations = list(declaration); eof = EOF
    { let span = match declarations with
      | [] -> eof.span
      | first :: _ -> cover first.span eof.span
      in node span declarations }

declaration:
  first = LET; group = binding_group; last = DOUBLE_SEMICOLON
    { let flag, bindings = group in
      node (cover first.span last.span) (D_let (flag, bindings)) }
| definition = type_declaration; last = DOUBLE_SEMICOLON
    { node (cover definition.span last.span) (D_type definition) }

binding_group:
  binding = binding { Nonrecursive, [binding] }
| REC; bindings = separated_nonempty_list(AND, binding) { recursive bindings }

binding:
  pattern = irrefutable_pattern; EQUAL; body = expr
    { binding pattern [] body }
| identifier = IDENTIFIER; parameters = nonempty_list(irrefutable_pattern);
  EQUAL; body = expr
    { let pattern = node identifier.span (P_variable (name identifier)) in
      binding pattern parameters body }

expr:
  expression = application_expr { expression }
| first = LET; group = binding_group; IN; body = expr %prec CONTROL
    { let flag, bindings = group in
      let body = finish body in
      Expr (node (cover first.span body.span) (E_let (flag, bindings, body))) }
| first = FUN; parameters = nonempty_list(irrefutable_pattern); ARROW;
  body = expr %prec CONTROL
    { let body = lambda parameters (finish body) in
      Expr { body with span = cover first.span body.span } }
| first = IF; condition = expr; THEN; yes = expr; ELSE; no = expr %prec CONTROL
    { let condition = finish condition and yes = finish yes and no = finish no in
      Expr (node (cover first.span no.span) (E_if (condition, yes, no))) }
| first = MATCH; subject = expr; WITH; cases = cases
    { let last = List.hd (List.rev cases) in
      Expr (node (cover first.span last.span) (E_match (finish subject, cases))) }
| left = expr; SEMICOLON; right = expr
    { let left = finish left and right = finish right in
      Expr (node (cover left.span right.span) (E_sequence (left, right))) }
| left = expr; operator = binary_operator; right = expr
    { let left = finish left and right = finish right in
      Expr (node (cover left.span right.span) (E_binary (operator, left, right))) }
| minus = MINUS; expression = expr %prec NEGATE { negative minus expression }

%inline binary_operator:
  token = PLUS { node token.span Add }
| token = MINUS { node token.span Subtract }
| token = STAR { node token.span Multiply }
| token = SLASH { node token.span Divide }
| token = MOD { node token.span Remainder }
| token = CARET { node token.span Concat }
| token = EQUAL { node token.span Equal }
| token = NOT_EQUAL { node token.span Not_equal }
| token = LESS { node token.span Less }
| token = LESS_EQUAL { node token.span Less_equal }
| token = GREATER { node token.span Greater }
| token = GREATER_EQUAL { node token.span Greater_equal }
| token = AND_AND { node token.span And }
| token = OR_OR { node token.span Or }

application_expr:
  expression = application { expression }

application:
  expression = atom { expression }
| callee = application; argument = atom
    { let callee = finish callee and argument = finish argument in
      Expr (node (cover callee.span argument.span) (E_apply (callee, argument))) }

atom:
  token = INTEGER { Magnitude (magnitude token) }
| token = STRING
    { match token.value with
      | Token.String value -> Expr (node token.span (E_literal (String value)))
      | _ -> assert false }
| token = TRUE { Expr (node token.span (E_literal (Bool true))) }
| token = FALSE { Expr (node token.span (E_literal (Bool false))) }
| token = IDENTIFIER { Expr (node token.span (E_variable (name token))) }
| token = CONSTRUCTOR { Expr (node token.span (E_constructor (name token))) }
| first = LPAREN; last = RPAREN
    { Expr (node (cover first.span last.span) (E_literal Unit)) }
| first = LPAREN; expression = expr; last = RPAREN
    { let expression = finish expression in
      Expr { expression with span = cover first.span last.span } }
| first = LPAREN; head = expr; COMMA;
  tail = separated_nonempty_list(COMMA, expr); last = RPAREN
    { Expr (node (cover first.span last.span)
        (E_tuple (List.map finish (head :: tail)))) }

cases:
  option(BAR); arms = case_list { arms }

case_list:
  arm = case %prec CONTROL { [arm] }
| arm = case; BAR; arms = case_list { arm :: arms }

case:
  pattern = pattern; ARROW; body = expr %prec CONTROL
    { let body = finish body in
      node (cover pattern.span body.span) { case_pattern = pattern; case_body = body } }

pattern:
  pattern = pattern_atom { pattern }
| constructor = CONSTRUCTOR; payload = pattern_atom
    { node (cover constructor.span payload.span)
        (P_constructor (name constructor, Some payload)) }

pattern_atom:
  token = IDENTIFIER { node token.span (P_variable (name token)) }
| token = UNDERSCORE { node token.span P_wildcard }
| token = CONSTRUCTOR { node token.span (P_constructor (name token, None)) }
| token = INTEGER
    { let value = finish (Magnitude (magnitude token)) in
      match value.value with
      | E_literal literal -> node token.span (P_literal literal)
      | _ -> assert false }
| minus = MINUS; token = INTEGER
    { let integer = magnitude token in
      node (cover minus.span token.span)
        (P_literal (Int (Int64.to_int32 (Int64.neg integer.value)))) }
| token = STRING
    { match token.value with
      | Token.String value -> node token.span (P_literal (String value))
      | _ -> assert false }
| token = TRUE { node token.span (P_literal (Bool true)) }
| token = FALSE { node token.span (P_literal (Bool false)) }
| first = LPAREN; last = RPAREN
    { node (cover first.span last.span) (P_literal Unit) }
| first = LPAREN; pattern = pattern; last = RPAREN
    { { pattern with span = cover first.span last.span } }
| first = LPAREN; head = pattern; COMMA;
  tail = separated_nonempty_list(COMMA, pattern); last = RPAREN
    { node (cover first.span last.span) (P_tuple (head :: tail)) }

irrefutable_pattern:
  token = IDENTIFIER { node token.span (P_variable (name token)) }
| token = UNDERSCORE { node token.span P_wildcard }
| first = LPAREN; last = RPAREN
    { node (cover first.span last.span) (P_literal Unit) }
| first = LPAREN; pattern = irrefutable_pattern; last = RPAREN
    { { pattern with span = cover first.span last.span } }
| first = LPAREN; head = irrefutable_pattern; COMMA;
  tail = separated_nonempty_list(COMMA, irrefutable_pattern); last = RPAREN
    { node (cover first.span last.span) (P_tuple (head :: tail)) }

type_declaration:
  first = TYPE; parameters = type_parameters; identifier = IDENTIFIER; EQUAL;
  option(BAR); constructors = separated_nonempty_list(BAR, constructor_declaration)
    { let last = List.hd (List.rev constructors) in
      node (cover first.span last.span)
        { type_name = name identifier; type_parameters = parameters;
          type_constructors = constructors } }

type_parameters:
  { [] }
| parameter = TYPE_VARIABLE { [name parameter] }
| LPAREN; parameters = separated_nonempty_list(COMMA, TYPE_VARIABLE); RPAREN
    { List.map name parameters }

constructor_declaration:
  constructor = CONSTRUCTOR
    { node constructor.span
        { constructor_name = name constructor; constructor_payload = None } }
| constructor = CONSTRUCTOR; OF; payload = type_expr
    { node (cover constructor.span payload.span)
        { constructor_name = name constructor; constructor_payload = Some payload } }

type_expr:
  expression = type_product { expression }
| argument = type_product; ARROW; result = type_expr
    { node (cover argument.span result.span) (Type_arrow (argument, result)) }

type_product:
  expression = type_application { expression }
| head = type_application; STAR;
  tail = separated_nonempty_list(STAR, type_application)
    { let last = List.hd (List.rev tail) in
      node (cover head.span last.span) (Type_tuple (head :: tail)) }

type_application:
  expression = type_atom { expression }
| argument = type_application; constructor = IDENTIFIER
    { node (cover argument.span constructor.span)
        (Type_constructor (name constructor, [argument])) }
| first = LPAREN; head = type_expr; COMMA;
  tail = separated_nonempty_list(COMMA, type_expr); RPAREN; constructor = IDENTIFIER
    { node (cover first.span constructor.span)
        (Type_constructor (name constructor, head :: tail)) }

type_atom:
  token = TYPE_VARIABLE { node token.span (Type_variable (name token)) }
| token = IDENTIFIER { node token.span (Type_constructor (name token, [])) }
| first = LPAREN; expression = type_expr; last = RPAREN
    { { expression with span = cover first.span last.span } }
