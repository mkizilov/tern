# Tern

Tern is a small functional language targeting WebAssembly, with an OCaml 5
compiler named **ternc**. The project now has a located AST, Sedlex lexer,
Menhir parser, source pretty-printer, and unified diagnostics. Resolution,
typing, interpretation, and WebAssembly generation are not implemented yet.

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
