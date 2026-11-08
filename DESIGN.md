# Tern compiler design

## Status and scope

The compiler is named `ternc`; its inputs are `.tern` files and its eventual
output is a core WebAssembly `.wasm` module. Prompt 1 establishes the language
contract, example corpus, dependency metadata, and local tooling. Prompt 2 adds
the AST, token vocabulary, and lexer; there is no executable stub, parser,
interpreter, or backend yet.
`LANGUAGE.md` is authoritative for semantics. Do not infer behavior from OCaml
just because the surface syntax is similar.

## Pipeline and phase contracts

```text
UTF-8 source
  → lexer → parser → AST → name resolution → type inference
                                            ├→ reference interpreter
                                            └→ ANF lowering → closure conversion
                                                               → WAT → wasm-tools → .wasm
```

The reference interpreter is a semantic oracle, not a transformation that the
backend executes during compilation. Both paths share the resolved, type-checked
program. Keep phases independently testable and free of CLI I/O.

1. **Lexer (sedlex):** produce located tokens with UTF-8 byte offsets and readable
   line/column positions. Handle nested comments, integer-literal boundaries,
   identifiers, and string escapes. Return structured lexical errors.
2. **Parser (Menhir):** produce a location-preserving surface AST. Encode operator
   precedence explicitly. Desugar function-binding shorthand without losing
   diagnostic spans. Parse type declarations and nested patterns; do not resolve
   or infer names here.
3. **AST:** algebraic OCaml types represent expressions, declarations, type
   syntax, and patterns. Use `ppx_deriving` for stable debug printers where useful.
   Keep source spans through subsequent representations.
4. **Name resolution:** give each binding and constructor a fresh stable identity.
   Resolve shadowing, pattern scope, recursive groups, and primitive names.
   Reject undefined names, duplicate pattern binders, duplicate types or
   constructors, and undeclared type parameters. Constructor arity is known here.
5. **Type inference:** Hindley-Milner unification with an occurs check, fresh
   scheme instantiation, let generalization, and monomorphic recursion within
   each recursive group. Nominal type constructors carry their arities. Check
   unit sequencing and irrefutable bindings, annotate expressions, and report
   located mismatches. Match coverage/redundancy analysis emits warnings;
   non-exhaustive matches still require runtime checks. Normalize type-variable
   names in diagnostics/tests so internal allocation order does not leak.
6. **Reference interpreter:** evaluate the typed resolved AST using environments,
   lexical closures, tuples, and tagged variants. Use explicit 32-bit integer
   operations, not host-dependent OCaml integer overflow. Output goes to an
   injectable sink, so tests capture bytes without mutating process stdout.
   Preserve left-to-right effects and short-circuiting. Return located runtime
   errors for failed matches and invalid arithmetic.
7. **ANF lowering:** name intermediate results with fresh identities, making
   evaluation order explicit. Only atomic operands reach primitive operations
   and applications. Retain branches and pattern decision trees; never hoist
   effects across a branch or evaluate an unselected arm. Test IR invariants.
8. **Closure conversion:** compute free variables and replace functions with
   explicit code/environment pairs. Lift code into module functions; environments
   hold captured values. Recursive groups need shared environments initialized
   before any function can be invoked. Curried functions and partial applications
   keep their semantics. Representation details remain internal.
9. **WAT emission:** choose layouts for tuples, strings, variants, and closures
   in linear memory. Use `i32` for integers, checked allocation, and indirect calls
   for closures. A checked bump allocator is a reasonable first runtime;
   reclamation is not part of Prompt 1. Document the ABI before implementing it.
   Map division traps and match failures to the runtime error contract. Expose
   an entry point and host imports for integer/string output; a future host runner
   must produce the same bytes as the reference interpreter.
10. **Assembly and validation:** call `wasm-tools parse input.wat -o output.wasm`,
    then `wasm-tools validate output.wasm`. Check process status, retain useful
    diagnostics, and clean intermediate files. `wasm-tools` is an assembler and
    validator, **not a WebAssembly execution engine**. Select/test a runner in
    the backend task; no runtime execution is claimed now.

## Planned layout and dependencies

As phases are implemented, place the reusable library in `lib/`, a thin CLI in
`bin/`, and OCaml phase tests in `test/`. Do not create empty modules in advance.
The current `tests/test_project.py` checks only project setup contracts.

`dune-project` generates `ternc.opam` and is the dependency source of truth.
Dune builds/tests/formats; Menhir and sedlex provide parsing/lexing;
`ppx_deriving` provides printers; `ppx_expect` snapshots each compiler phase;
QCheck adds generative tests. `js_of_ocaml` and `js_of_ocaml-ppx` are declared for
later OCaml-in-JavaScript integration, not as substitutes for the Wasm backend.
`ocamlformat` is pinned. Python 3 is a read-only host prerequisite for
infrastructure tests, not a compiler runtime dependency; no Python packages
are needed.

## Local setup and verification

Read `AGENTS.md` first. With the supplied project-local environment:

```sh
scripts/setup.sh
scripts/check.sh
```

Setup supports ARM64/x86_64 macOS/Linux with Bash, a C toolchain, make, tar, curl, and
SHA-256 tooling available read-only. It downloads opam **2.6.1** and wasm-tools
**1.263.0** to `.tools/bin`, verifying platform-specific SHA-256 digests from
their GitHub releases. It initializes the project-local opam root without shell
profile changes, runs `opam switch create . --empty`, installs OCaml **5.5.2**
and Dune, regenerates opam metadata, then runs
`opam install . --deps-only --with-test`. Package builds/downloads use at most two
workers. Opam sandbox defaults remain enabled; system dependency installation
is disabled (`--no-depexts`). No Homebrew, sudo, services, or global switch is used.
Other dependencies are resolved from constraints, not a fully locked repository.

The environment script preserves supplied HOME/TMPDIR/cache paths and refuses
non-project state paths. Outside the supplied harness, explicitly set HOME to
`$PWD/.agent-local/home` (and unset or localize other external state variables)
before setup. It never resets a supplied project-local value. Toolchains live
in `_opam/`; binaries in `.tools/bin`; caches and extraction directories remain
under `.agent-local/`. Extraction directories are removed on success or failure.
Re-running setup reuses matching tool versions and the switch. `check.sh`
selects that switch explicitly and runs, fail-fast:

```sh
opam exec --switch="$PWD" -- dune build -j 2
opam exec --switch="$PWD" -- dune test -j 2
opam exec --switch="$PWD" -- dune fmt -j 2
```

For direct commands, select the local environment in the current shell only
(`export PATH="$PWD/.tools/bin:$PATH"` and
`eval "$(opam env --switch="$PWD" --set-switch)"`), then use `dune build`,
`dune test`, or `dune fmt`. All three must pass before a future task is done.
`dune fmt` checks formatting; `dune build @fmt --auto-promote` applies it.
Commit generated `ternc.opam` updates, never `_build/`, `_opam/`, or caches.

Every phase requires `ppx_expect` success and error tests. Add QCheck properties
for unification, substitution, and IR invariants where useful. Once executable,
all fifteen examples must match `.out` byte-for-byte in the interpreter and,
later, a real Wasm runtime. Differential checks must include effect ordering,
closure capture, mutual recursion, nested patterns, and integer edges.

### Prompt 1 environment limitation

The mandatory shell sandbox probe passed. Shell HTTPS attempts to both
`api.github.com` and `opam.ocaml.org` failed with curl error 6 (DNS resolution).
No OCaml/opam/Dune installation was present. Release metadata was readable through
the documentation HTTP tool, allowing asset names/digests to be confirmed, but
no alternate execution/download path was used to bypass the shell boundary.
Actual installation, dependency solving, `dune build`, `dune test`, and `dune fmt`
remain unverified here. Standalone Python infrastructure tests can run offline;
their mocked tool calls are not evidence of an installed compiler, a successful
Dune build, or execution of Tern examples.

`scripts/setup.sh` was attempted and exited 6 while downloading its pinned opam
binary from `github.com`; its temporary directory was removed. `scripts/check.sh`
was attempted and correctly rejected the missing local toolchain. The standalone
infrastructure suite passed 14 tests, including mocked bootstrap on all four
supported OS/CPU combinations, repeatability, checksum/download failures,
fail-fast checks, environment preservation, and exact example fixture contents.
These fixtures have not been executed as Tern programs.

Two additional harness observations affect verification: `/bin/sh` could not
change into existing repository directories although Bash/Python could, so
entry scripts use Bash explicitly. macOS `mkdir -p` with absolute project paths
attempted inaccessible ancestor metadata; scripts create validated state paths
relative to the checkout instead. Neither workaround accesses outside the
repository or disables protection. AFT inspection had no Bash diagnostics but
was partial: Python's language server was unavailable and Dune file types had
no diagnostic producer. Native tests, not that partial result, are the evidence.

## Implemented AST and lexer (Prompt 2)

The wrapped OCaml library is `Tern` (public Dune library `ternc`). `Ast` uses a
generic `{ value; span }` wrapper for expressions, patterns, type expressions,
bindings, match arms, constructor/type declarations, top-level declarations,
and the program. Identifier references/binders and operators also retain their
own spans. Literal and operator variants are payloads, not independently
positionless syntax nodes. Every AST type has `ppx_deriving.show` printers.
The AST models curried unary lambdas/applications, recursive binding groups,
conditionals, tuples, matches, sequencing, and parametric variants. No parsing
or semantic validation is performed by these data types.

`Token.kind` is independent of a future Menhir parser. `Lexer.lex ~file source`
returns all located tokens including a zero-width EOF, or `Error` containing an
error kind and span. `Lexer.create` and `Lexer.next` also support incremental
token consumption; they raise `Lexer.Error` for lexical failures. Input is a
UTF-8 string and is eagerly validated with OCaml's standard Unicode decoder so
malformed bytes never escape as an unlocated Sedlex exception. Token recognition
and string/comment scanning use Sedlex. Sedlex >= 3.6 is required for parallel
code-point and byte positions. LF is tracked automatically by Sedlex; only lone
CR needs an explicit `new_line` call. Never increment again for LF/CRLF.

All spans use 1-based lines, 0-based Unicode-scalar columns, exclusive end
positions, and 0-based byte offsets. Strings span both quotes even though their
body is scanned in pieces. Nested comment failures point to the outer opener;
unterminated strings point to their quote; invalid escapes cover the backslash
and next scalar. Decimal tokens use an `int64` magnitude bounded by `2147483648`,
with a separate minus token. The future parser must reject a bare extra
magnitude while allowing `-2147483648`; this avoids whitespace-dependent
subtraction and OCaml host-integer overflow. AST integer values use `int32`.

`test/` contains `ppx_expect` tests for AST spans/printers, every keyword and
token kind, maximal munch, multiline/CRLF/lone-CR/tab positions, decoded escapes,
UTF-8 scalar/byte offsets, nested comments, empty/repeated EOF, long-buffer
refills, integer edges, lexical errors, and all 15 examples. Corpus tests only
lex the files; they do not assert parsing, typing, or runtime behavior.

### Prompt 2 verification limitation

Setup was retried and again exited 6: the shell could not resolve `github.com`.
`scripts/check.sh` was attempted and rejected the absent local toolchain. Native
compilation, expectation execution, Dune formatting, and opam regeneration have
not run; authored expectation snapshots are not claimed as observed output.
The 14 existing Python infrastructure regressions and `git diff --check` passed.
Selected span fixture arithmetic was independently checked with Python, not by
executing or reimplementing the lexer. AFT diagnostics were partial because
`ocamllsp` is absent; call-graph inspection also reported OCaml as unindexed,
so the local helper call site was checked with indexed text search instead.
