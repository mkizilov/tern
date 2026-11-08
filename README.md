# Tern

Tern is a small functional language targeting WebAssembly, with an OCaml 5
compiler named **ternc**. The initial project defines the language and local
tooling; it intentionally does not implement the compiler yet.

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
