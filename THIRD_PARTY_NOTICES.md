# Third-party notices

Tern's project-owned source and documentation are licensed under the root
[MIT LICENSE](LICENSE), copyright 2026 Mykyta Kizilov. That license does not
replace dependency copyrights, licenses, linking exceptions, or data notices.

The texts under `licenses/` are preserved verbatim from the reviewed local
dependency distributions, with package boundaries added only to the combined npm
notice file. Packages/toolchains/caches themselves are not vendored or committed.
The static site and native documentation installation include these notices.

## Compiler/runtime dependencies

| Component | Reviewed version | Upstream terms / preserved text |
| --- | --- | --- |
| OCaml core/standard library, including Unix | 5.4.1 | LGPL-2.1 with the upstream linking exception: [OCaml.txt](licenses/OCaml.txt) |
| js_of_ocaml library/runtime | 6.5.0 | LGPL-2.1 with the upstream linking exception: [js_of_ocaml.txt](licenses/js_of_ocaml.txt) |
| Menhir runtime library | 20260209 | Library GPL v2 with linking exception; the complete upstream file also describes generator/SDK terms: [menhirLib.txt](licenses/menhirLib.txt) |
| Sedlex | 3.8.1 | MIT: [sedlex.txt](licenses/sedlex.txt) |
| Gen | 1.1 | BSD-style redistribution terms: [gen.txt](licenses/gen.txt) |
| ppx_deriving runtime/generated support | 6.2.0 | MIT: [ppx_deriving.txt](licenses/ppx_deriving.txt) |
| Uucp | 18.0.0 | ISC: [uucp.txt](licenses/uucp.txt) |
| Unicode data | upstream notice retrieved 2026-11-08 | Unicode License V3: [Unicode.txt](licenses/Unicode.txt), from https://www.unicode.org/license.txt |

The native and JavaScript compiler link third-party libraries; Tern-generated
Wasm contains the project-owned hand-written runtime. The upstream exceptions
and full terms above are retained rather than relabeling those libraries as MIT.
Read the original terms when distributing dependency code or modified libraries.

## Bundled browser dependencies

[npm-runtime.txt](licenses/npm-runtime.txt) contains the full license text and any
installed NOTICE file for every production npm dependency in the reviewed graph:

- CodeMirror commands 6.11.1, language 6.13.1, legacy-modes 6.5.5, lint 6.9.7,
  state 6.7.6, streamparser 6.0.0, and view 6.43.15 (MIT).
- Lezer common 1.5.5, highlight 1.2.5, and lr 1.4.12 (MIT).
- find-cluster-break 1.0.4, crelt 1.0.7, style-mod 4.1.4, and w3c-keyname 2.2.8
  (MIT).
- wabt 1.0.39 (Apache-2.0).

`package-lock.json` records the exact package versions and integrity values.
Development tools such as esbuild and Playwright are not browser runtime
dependencies; their own license files remain in their installed packages. The
browser build preserves legal comments and additionally distributes the complete
notice texts, so minification is not the only means of retaining attribution.

If dependencies change, review their license/NOTICE files and update this inventory
and the corresponding preserved texts before redistributing a new bundle. Do not
remove required third-party notices during project presentation wording cleanup.
