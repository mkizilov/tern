# Tern language specification

Tern is a strict, statically typed functional language. Files use `.tern`.
`ternc` will compile a single file to WebAssembly; a reference interpreter will
define the same observable behavior. This is an implementation contract, not a
claim that the compiler already exists. Prompt 1 contains no compiler code.

## Source files and lexical rules

A program is a sequence of top-level `type` and `let` declarations, each terminated
by `;;`. There is no implicit `main`: top-level binding expressions execute once,
in source order. `let () = ...;;` is the usual entry point. Top-level expressions
must be bound; the program does not automatically print their values.

Source is UTF-8. Whitespace is insignificant outside strings. Comments use
`(* ... *)` and may nest. Value/type identifiers match
`[a-z_][A-Za-z0-9_']*`; a single `_` is only a wildcard. Constructor names start
with an uppercase ASCII letter, followed by the same identifier characters.
Keywords are `let rec and in fun if then else type of match with true false mod`.
Names are case-sensitive. There are no modules, imports, objects, mutable cells,
exceptions, floats, or implicit conversions in this version.

Diagnostics use 1-based lines and 0-based Unicode-scalar columns, with exclusive
end positions and 0-based byte offsets. Tabs count as one column. LF, CRLF, and
lone CR each end a line; CRLF is one line break. Outside strings/comments,
whitespace is ASCII space, tab, vertical tab, form feed, or a line break.
Unterminated string/comment errors point to their opening delimiter (the
outermost opening delimiter for nested comments). Other lexical errors point
to the offending character or escape. Malformed UTF-8 is rejected before lexing.
The diagnostic renderer displays columns starting at 1, without changing the
internal 0-based span convention. It shows source excerpts with carets, optional
secondary labels, and notes; warnings and errors retain distinct severities.

```tern
(* A whole file. *)
let greeting = "Hello, Tern!\n";;
let () = print_string greeting;;
```

## Values and primitive operations

| Type | Syntax | Semantics |
| --- | --- | --- |
| `int` | `0`, `42`, `-7` | Signed 32-bit two's-complement integer |
| `bool` | `true`, `false` | Two distinct boolean values |
| `string` | `"hello"`, `"line\n"` | Immutable UTF-8 byte sequence |
| `unit` | `()` | A single value, for effect-only expressions |

Integer literals are decimal, without separators, in `[-2147483648, 2147483647]`;
out-of-range literals are compile-time errors. Unary `-` negates integers.
Unary negation, `+`, `-`, and `*` wrap modulo 2^32. `/` truncates toward zero;
`mod` has the sign of the dividend. Division or remainder by zero, and either operation on
`-2147483648` and `-1`, are runtime errors. Comparisons are signed.

`+ - * / mod : int -> int -> int`. Comparisons `= <> < <= > >=` all have type
`int -> int -> bool`; equality is deliberately **not** polymorphic. Functions,
strings, tuples, variants, booleans, and unit cannot be compared with `=`.
Use pattern matching or `if` for boolean tests. This keeps inference ordinary
Hindley-Milner without type classes or equality constraints.

Strings allow raw UTF-8 text and escapes `\n`, `\r`, `\t`, `\"`, and `\\`.
Other escapes, unescaped control characters, and unterminated strings are lexical
errors. There is no interpolation, indexing, or Unicode normalization.
`^ : string -> string -> string` concatenates bytes without inserting spaces.
`&&` and `||` require booleans and short-circuit left to right.

Lexically, `-` is always a separate token; the lexer accepts unsigned magnitudes
through `2147483648` so the parser can construct the minimum signed integer.
The parser must reject that extra magnitude unless it is the direct operand of
unary minus. Larger magnitudes are lexical errors. Leading decimal zeroes do
not change the base. Type-variable tokens omit their leading apostrophe in their
payload but retain it in their source span. Raw C0/C1 control characters and DEL
are forbidden in strings (the documented escapes remain valid).

## Bindings, scope, and sequencing

`let pattern = expression in expression` binds immutable values locally. A
non-recursive right-hand side sees the previous environment, not its new binding.
Bindings shadow earlier bindings lexically. Each pattern binds any name at most
once. Top-level `let pattern = expression;;` has the same binding semantics.

```tern
let answer = let x = 20 in x + 22;;
let () = print_int answer; print_string "\n";;
```

`e1; e2` requires `e1 : unit`, evaluates it, then evaluates and returns `e2`.
It is an expression, not a top-level declaration separator. Parentheses delimit
compound subexpressions. Pattern bindings in `let` must be irrefutable: a variable,
`_`, `()`, or a tuple of irrefutable patterns; constructor and literal tests belong
in `match`. A `let () = e` requires `e : unit`.

## Functions, closures, and recursion

`fun x -> body` creates a first-class function with lexical capture. Multiple
parameters abbreviate nested unary functions: `fun x y -> e` means
`fun x -> fun y -> e`. Parameters are irrefutable patterns. The binding shorthand
`let f x y = e` means `let f = fun x y -> e`. Application is curried,
left-associative, and written with spaces: `f x y` means `(f x) y`.
Parenthesize negative arguments (`f (-1)`); `f - 1` is subtraction.
Partial application returns a closure; functions can be stored in tuples or
variants, passed to other functions, and returned.

```tern
let make_adder x = fun y -> x + y;;
let add_seven = make_adder 7;;
let () = print_int (add_seven 35); print_string "\n";;
```

`let rec f x = ...` allows `f` in its own body. `and` adds mutually recursive
functions to the same group, all visible in every function body. Recursive
bindings require names and function right-hand sides (including explicit `fun`);
arbitrary recursive values are not allowed. The group is available in the
following `in` body or subsequent top-level declarations. `and` is only supported
in recursive groups, not ordinary `let` bindings.

```tern
let rec even n = if n = 0 then true else odd (n - 1)
and odd n = if n = 0 then false else even (n - 1);;
let () = if even 10 then print_string "even\n" else print_string "odd\n";;
```

## Conditionals and tuples

`if condition then yes else no` is an expression. The condition must be `bool`,
both branches must have the same type, and only the selected branch executes.
`else` is mandatory and associates with the nearest unmatched `if`.

Tuples have fixed arity of at least two: `(1, true)` has type `int * bool`.
`(e)` merely groups `e`; `()` is unit. Tuples may nest and contain functions.
Use patterns to project fields: `let (x, y) = pair in x + y`.

## User-defined algebraic data types

Type declarations occur only at top level. Types are nominal and names may not
be redeclared. Constructors are unique within a file, in a namespace separate
from lowercase values. Each constructor has either no payload or one payload
(which may itself be a tuple). Constructor application uses ordinary application
syntax; a constructor with payload is a first-class unary function.

Type and constructor declarations are visible only from their declaration onward;
a type is also visible within its own constructor payloads. There are no forward
references to later declarations. The primitive type names `int`, `bool`, `string`,
and `unit` are predeclared and cannot be redeclared as types. Value names occupy
a separate namespace, so `let int = 1` is allowed. Parameters on each type must
be distinct. A recursive function group likewise cannot bind the same name twice.

```tern
type 'a option = None | Some of 'a;;
type 'a list = Nil | Cons of ('a * 'a list);;
type ('a, 'b) result = Ok of 'a | Error of 'b;;
let numbers = Cons (1, Cons (2, Nil));;
let found = Some 42;;
```

Type parameters use apostrophe-prefixed names and are applied in postfix OCaml
style: `int list`, `(int, string) result`, or `'a list option`. Product `*` binds
more tightly than function arrow `->`; arrows associate right. Recursive use of
the declared type is allowed; mutually recursive type declarations and type
aliases are not part of this version. Every payload type variable must be
declared as a parameter. There are no built-in list/option types, list literal
sugar, GADTs, or extensible variants. Expression type annotations are not
required and are not included in this initial syntax.

## Pattern matching

`match e with | p1 -> e1 | p2 -> e2` evaluates `e` once, then tries arms in
source order. The leading `|` is optional. The first matching arm wins; all arm
results must have the same type. Bindings are local to that arm. Patterns include
variables, `_`, integer/boolean/string/unit literals, tuples, nullary constructors,
and payload constructors; tuple/constructor patterns may nest arbitrarily.
String patterns compare exact bytes. Patterns have no effects. Or-patterns,
guards, aliases, and repeated variable names are not supported.

```tern
type 'a option = None | Some of 'a;;
type 'a list = Nil | Cons of ('a * 'a list);;
let describe xs =
  match xs with
  | Cons (Some 0, _) -> "zero first"
  | Cons (Some n, _) -> "present first"
  | Cons (None, _) -> "absent first"
  | Nil -> "empty";;
```

Non-exhaustive matches are accepted with a warning; reaching an uncovered case
is a runtime error. Redundant arms should warn. Match errors carry source
locations; they must never become unchecked memory access in compiled code.
Parenthesize nested `match` expressions in arm bodies to make arm boundaries
explicit; without parentheses, an arm belongs to the innermost open `match`.
Constructor payload patterns are atomic: parenthesize a payload that is itself
a constructor application (`Some (Some x)`). Tuple payloads already use
parentheses. There are no unparenthesized comma expressions or trailing commas.

## Static typing

Hindley-Milner inference assigns principal types without annotations. Function
application unifies argument and parameter types; infinite types fail an occurs
check. Non-recursive `let` bindings generalize type variables not free in the
environment. Tern has no mutable references, so there is no value restriction.
Lambda parameters are monomorphic. Recursive groups are inferred monomorphically
inside the group, then generalized together relative to the outer environment:
polymorphic recursion is not supported. Constructor schemes quantify their type
parameters. Undefined names, arity errors, and incompatible types are compile-time
errors; no implicit truthiness or numeric/string coercions exist.

```tern
let id x = x;;              (* 'a -> 'a *)
let pair = (id 7, id true);; (* int * bool *)
(* id 1 + true would be a type error. *)
```

## Evaluation order and precedence

Evaluation is call-by-value, left to right: evaluate the callee, then arguments;
tuple fields and constructor payloads follow the same order. A closure captures
binding values, not later shadows. Only function invocation evaluates its body.
There is no observable pointer identity. Allocation failure is a runtime error.

Precedence, highest to lowest:

1. Atoms and parenthesized expressions; function application (left-associative).
2. Unary `-` (so `-f x` means `-(f x)`).
3. `* / mod` (left).
4. `+ -` (left).
5. `^` (right).
6. `= <> < <= > >=` (non-associative; parenthesize chained comparisons).
7. `&&` (right), then `||` (right).
8. `let ... in`, `fun ... ->`, `if ... then ... else`, `match ... with`;
   their bodies extend rightward and include sequencing.
9. `;` (right). Use parentheses around a conditional/match when sequencing
   *after* the whole expression: `(if b then f () else g ()); h ()`.

## Built-ins and observable output

| Name | Type | Effect |
| --- | --- | --- |
| `print_int` | `int -> unit` | Writes signed decimal ASCII, **no newline** |
| `print_string` | `string -> unit` | Writes exact UTF-8 bytes, **no newline** |
| `^` | `string -> string -> string` | Concatenates strings |

These names are initially in scope; lowercase built-ins can be shadowed like
ordinary bindings. Operators are syntax, not rebindable names. There is no input
or implicit output. Runtime errors terminate execution unsuccessfully, preserving
already-written output and reporting a diagnostic separately from stdout.
The `.out` beside each example is exact expected stdout, including newlines.

The fifteen self-contained programs in `examples/` progress from hello world to
a user-defined list library. `examples/README.md` maps each file to its coverage.
Expected output is a specification fixture until the interpreter and compiler
exist; infrastructure tests do not pretend to execute Tern.

The Menhir parser and source printer now consume this syntax. Printing drops
comments, normalizes whitespace, desugars function-binding shorthand into unary
`fun`, and adds explicit parentheses. Parsing the printed form must preserve
the entire AST except source spans; neither parsing nor printing implies that
the program is well-typed or executable yet.
