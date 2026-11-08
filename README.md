# Tern

Tern is a small functional language targeting WebAssembly, with an OCaml 5
compiler named **ternc**. The project now has a located AST and Sedlex lexer;
the parser and subsequent compiler phases are not implemented yet.

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
returning located tokens (including EOF) or a structured lexical error.
`Lexer.create` / `Lexer.next` provide incremental token delivery and raise
`Lexer.Error` on invalid input. The input is a UTF-8 string, validated at creation.
Spans use 1-based lines, 0-based Unicode-scalar columns, exclusive ends, and
0-based byte offsets. Tabs advance one column.

Run the AST/lexer `ppx_expect` suite with `dune test -j 2` in the local switch
(or `scripts/check.sh` for all checks). The suite includes every token kind,
positions, errors, and lexical acceptance of all 15 examples; it does not yet
parse, type-check, or execute them. Turn 2 native checks remain blocked by the
same shell DNS/toolchain limitation documented in `DESIGN.md`.
