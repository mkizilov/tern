# Tern

Tern is a small functional language targeting WebAssembly, with an OCaml 5
compiler named **ternc**. The project now has a located AST, Sedlex lexer,
Menhir parser, source pretty-printer, unified diagnostics, and name resolution
to a smaller Core AST, Hindley–Milner type inference, and typed pattern-match
warnings. Interpretation and WebAssembly generation are not implemented yet.

- [Language specification](LANGUAGE.md)
- [Compiler design and local setup](DESIGN.md)
- [15 example programs and expected output](examples/README.md)
- [Working agreement and verification](AGENTS.md)

With the supplied project-local environment, run:

```sh
scripts/setup.sh
scripts/check.sh
```

Setup installs pinned local opam, OCaml 5.5.2 in `_opam/`, declared Dune
dependencies, and pinned wasm-tools in `.tools/bin`. It does not install globally
or change shell profiles. See `DESIGN.md` for prerequisites, environment rules,
and the shell DNS limitation that prevented installation during initial setup.

Offline infrastructure checks (Python 3 standard library only):

```sh
python3 tests/test_project.py
```

These checks test setup contracts with mocked tools and validate fixture bytes;
they are not a substitute for building OCaml or executing Tern programs.

## AST and lexer

`lib/ast.ml` defines located syntax nodes with derived printers. `lib/token.ml`
defines the token vocabulary; `lib/lexer.ml` exposes `Lexer.lex ~file source`,
returning located tokens (including EOF) or a `Diagnostic.t`.
`Lexer.create` / `Lexer.next` provide incremental token delivery and raise
`Lexer.Error` on invalid input. The input is a UTF-8 string, validated at creation.
Spans use 1-based lines, 0-based Unicode-scalar columns, exclusive ends, and
0-based byte offsets. Tabs advance one column.

Run the AST/lexer `ppx_expect` suite with `dune test -j 2` in the local switch
(or `scripts/check.sh` for all checks). The suite includes every token kind,
positions, errors, and lexical acceptance of all 15 examples; it does not yet
parse, type-check, or execute them. Turn 2 native checks remain blocked by the
same shell DNS/toolchain limitation documented in `DESIGN.md`.

## Parser and source printer

`Parse.program ~file source` returns a located `Ast.program` or a `Diagnostic.t`
with its primary source span. It uses `lib/grammar.mly`, built with Menhir
`--strict`; unresolved conflicts and unused precedence warnings are build
failures, not suppressed warnings. The grammar handles application, operators,
local/recursive bindings, nested matches, tuples/patterns, and parametric variants.
Bare match bars belong to the innermost open match; parentheses close that scope.

`Pretty.program ast` returns canonical Tern source. It desugars function-binding
shorthand and deliberately parenthesizes compound expressions and types. It is
not an OCaml debug dump or a comment/layout-preserving formatter.
`Ast.equal_program` (and the other derived AST equality functions) compares
syntax while ignoring **every** located span, including identifier/operator
spans. Direct `Ast.equal_span` still compares actual source positions.

The parser expectation suite parses all 15 examples, prints/reparses each, and
asserts span-free AST equality and stable printed output. It also tests syntax
errors, integer edges, precedence, and the nested-match ambiguity. These new
OCaml tests remain unexecuted here: native setup is still blocked by shell DNS.

## Diagnostics

Lexer, parser, and parser semantic errors share `Diagnostic.t`: severity, message,
primary span, optionally labeled secondary spans, and notes. Low-level failures
raise `Diagnostic.Raised` (`Lexer.Error` is an alias); the `Lexer.lex` and
`Parse.program` result APIs return the same diagnostic type. The previous
`Parse.Lexical`/`Parse.Syntax` wrappers and separate parser-error record are gone.

Render without filesystem access by supplying source text explicitly:

```ocaml
Diagnostic.render ~color:false
  ~source:(fun file -> if file = "example.tern" then Some source else None)
  diagnostic
```

The result has a rustc-style severity/message header, `file:line:column`, source
excerpt, and caret underline. Displayed columns are 1-based; AST columns remain
0-based. Secondary frames, optional labels, and notes follow the primary frame.
`Diagnostic.render` defaults to plain text for deterministic output;
`Diagnostic.emit` writes to stdout by default and enables ANSI color only when
its actual output channel is a terminal. Redirected output stays plain, unless
color is explicitly forced.

Tabs expand to four-column stops. `uucp` supplies terminal width hints for wide
and combining Unicode characters, avoiding a home-grown Unicode table. Controls,
formatting controls, and malformed bytes are escaped safely in excerpts. Long
multiline spans show their first and last source lines with an elision marker.
Source lookup failures are stated explicitly, never replaced with invented text.

Parser errors use `lib/grammar.messages`, compiled into a state/message lookup
by Dune with `menhir --compile-errors`. The incremental table backend requires
`menhirLib`. Ten syntax-error snapshots plus renderer/lexer regression cases are
in `test/diagnostic_tests.ml`. Native message compilation, snapshots, and color
emission remain unverified while toolchain installation is blocked by shell DNS.

## Name resolution and Core

Pass a successfully parsed program to `Resolve.program`. It returns a
`Core.program` or the same `Diagnostic.t` used by the lexer/parser. The resolver
reports unbound values/constructors, duplicate pattern variables, and duplicate
type/constructor names, with secondary spans for previous declarations. It also
resolves type parameters/references, checks type application arity and constructor
pattern payloads, and rejects duplicate names in recursive groups.

Every binder gets a deterministic integer ID, including type parameters,
constructors, prelude bindings, and generated lambda parameters. Names at use
sites carry that identity and their own source span. Shadowing is represented
by different IDs, not string-based lookups in later phases. IDs restart on every
call; there is no global counter or cross-program state.

Core has unary name-parameter lambdas, applications, nonrecursive pattern lets,
recursive function groups, literals, tuples, matches, conditionals, and primitive
operations. Pattern lambda parameters become fresh name parameters with inner
pattern lets. Sequencing becomes a unit-pattern let; `&&` and `||` become
conditionals. Top-level value declarations become nested lets ending in unit,
with resolved type declarations retained as separate metadata. Pattern lets are
intentional: replacing them with ordinary matches would lose let-polymorphism.

Types and constructors are visible after their declaration (and a recursive
type is visible within its own payloads). They cannot be redeclared. Primitive
type names are part of the prelude, while value names such as `print_int` can be
shadowed. The value and type namespaces are separate.

`test/resolve_tests.ml` contains identity/scope goldens, rendered error cases,
desugaring checks, and a corpus invariant walk checking globally unique binders,
properly scoped references, resolved types/constructors, primitive arities, and
stable resolution after source printing. These expectations remain unexecuted
here because native OCaml installation is still blocked by shell DNS.

## Type checking

Inside the project-local opam environment:

```sh
dune exec ternc -- check examples/11_polymorphic_tuples.tern --types
dune exec ternc -- check examples/15_list_library.tern
```

The public executable's command is `ternc check file.tern --types`; `dune exec`
runs it locally without installing the project. `--types` may precede or follow
the filename. Successful checking without warnings is silent unless that flag
is present; type reports look like `val id : 'a -> 'a`.
Each top-level bound name is reported in source order, including shadowed names
and tuple components, but not wildcard/unit bindings, local bindings, the
prelude, or generated parameters. The whole program must pass before any type
report is printed. Errors go to stderr (with color only on a terminal) and return
status 1; usage errors return 2. No program code is executed.

Pattern warnings go to stderr without making checking fail (status 0). They can
coexist with a successful `--types` report on stdout. Ill-typed files still fail
before any warnings or partial type reports are emitted.

`Check.source ~file source` runs the front-end pipeline and returns inferred
schemes or a diagnostic. `Infer.program` accepts an already resolved Core program.
`Ty` supplies mutable-variable unification, an occurs check that lowers escaping
variables' levels, generalization at let boundaries, and fresh instantiation.
Recursive groups remain monomorphic internally and generalize only after all
bodies are checked. There is no value restriction, matching Tern's immutable
language contract. Constructor signatures, nominal variants, tuple patterns,
short-circuit conditions, unit sequencing, and built-ins are all type-checked.

Mismatches show expected/actual types at the responsible expression. Variable
names are normalized to `'a`, `'b`, … independently for each reported scheme,
and consistently across the expected/actual pair in a diagnostic. Inference
state is local to a call; failures do not poison later checks.

The native suite adds more than 50 program expectations, low-level type-variable
tests, the 15-example typing corpus, and a Cram check-command integration test.
They are authored but remain unexecuted here because the shell cannot download
the local toolchain. Passing Python infrastructure contracts do not establish
that OCaml compilation, these snapshots, or the command succeeded.

## Exhaustiveness and unreachable cases

After type inference, `Coverage.check` applies Maranget's pattern-matrix
usefulness algorithm. A match missing values gets a warning with a witness such
as `None`, `Some None`, or `Cons (1, Nil)`. A case adding no values beyond the
union of preceding cases gets an unreachable-case warning. This handles nested
constructors, tuple-column correlations, wildcards, binding patterns, and scalar
literals—not only duplicate or pairwise-subsumed patterns.

Constructor signatures come from the resolved variant declarations, with actual
type arguments substituted into payloads. Booleans and unit have finite complete
signatures; integers/strings use open-literal columns and fresh witnesses. A
witness is a pattern describing unmatched values: `_` stands for an arbitrary
well-typed payload where a concrete one is unnecessary or unknown. Coverage is
conservative under the paper's non-empty-type assumption; it does not prove
that recursively defined types without finite inhabitants are empty.

`test/coverage_tests.ml` adds nested/partial/redundant pattern expectations,
parametric variant tests, list/option library checks, and a finite-product
usefulness/witness property. The new warnings, native tests, and CLI integration
remain unverified here because toolchain installation is still blocked by DNS.
