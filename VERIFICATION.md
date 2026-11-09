# Verification scope and evidence

Reviewed on **2026-11-08**, against baseline `3e507f4` plus the final licensing,
distribution-notice, and setup-idempotency fixes. This is a
maintained verification guide, not a claim of complete correctness or a security
certification. `ROADMAP.md` lists work not yet implemented. `DESIGN.md` retains
historical development observations; this document states the current evidence.

## Status vocabulary

- **Implemented:** the code path exists; this alone does not establish coverage.
- **Verified:** named checks were actually executed on the environment below.
- **Partial:** only a bounded subset, limited contract, or selected environment is
  covered; remaining gaps are explicit.
- **Unverified:** no execution evidence is claimed for the named behavior/platform.

## Current implementation and limits

| Area | Implemented / verified evidence | Partial or unverified behavior |
| --- | --- | --- |
| Front end and HM inference | Located lexer/parser, resolver, inference, type printing, phase expectations, and all 16 examples | Tests are not a proof over all programs; adversarial compiler work/memory is not explicitly budgeted in every phase |
| Pattern analysis | Typed usefulness, redundancy, and missing-witness tests, including nested list/option cases | Conservative treatment of uninhabited recursive types; broader witness/model verification remains |
| Interpreters and backend | AST/ANF/closed interpreters; full-language WAT; direct/indirect tail calls; exact golden corpus | QCheck generation is bounded and excludes some language/resource families, including recursive/string generation |
| Optimizations | Four independent opt-in passes, individual/all-enabled corpus checks, typed randomized comparisons | Not universal size/speed improvements; no exhaustive equivalence proof |
| Collector | Mark-sweep, shadow roots, iterative cyclic tracing, coalescing, helper safepoints, OOM and stress assertions | Conservative local retention, fragmentation, manual host rooting, and discard-after-trap contract; no compaction or trap unwinder |
| Runtime errors | Front-end errors have rendered real spans; runtime failures retain prior output | Compiled runtime traps are not source-mapped; generic Wasm traps do not expose a full fault taxonomy |
| Playground | Real js_of_ocaml compiler, wabt assembly, worker execution, same-origin static GETs, Unicode highlights, limits, cancellation, and viewport tests | Chromium only; Safari/Firefox, actual mobile devices, and hard JS-worker heap isolation are unverified |
| Setup | Real setup replay passes; opam/GitHub/npm DNS and downloads work; mocks check asset selection, checksums, version metadata, spaces, and cleanup | Replay uses the existing macOS/ARM64 switch, not a clean cross-platform bootstrap; external HOME/cache paths intentionally fail the local-state guard |
| Dependencies | Exact npm lock; pinned tool releases/checksums; npm audit reported zero known advisories | Most opam library versions are not locked to a repository snapshot; advisory absence is not a source/engine security audit |
| Publication | Complete project MIT license; owner-supplied author/maintainer fields; preserved upstream notices; native/site legal distribution and clean-source package checks | Lint has no errors but warnings 35/36 remain for canonical project/issue URLs, which are not guessed before repository creation; no remote publication claim |

The runtime host is not advertised as a hardened arbitrary-Wasm service. The
playground compiles typed Tern, exposes only printing imports, and uses a worker
deadline. An external embedder that mutates guest memory or retains unrooted raw
values is outside the typed-language safety contract.

## Reproducible checks

Run inside the repository with the documented local environment and installed
dependencies. Preserve supplied HOME/TMPDIR/cache/SDK settings. Do not use host
service sockets, global installs, or external caches to make a check pass.

```sh
scripts/check.sh
.tools/bin/opam exec --switch=. -- dune runtest --force --root . -j 2
scripts/build-site.sh
npm test
npm run test:browser
npm audit --json --cache "$XDG_CACHE_HOME/npm"
.tools/bin/opam lint ternc.opam
python3 scripts/check-publication.py
```

`scripts/check.sh` is the **native** build/test/format gate; it does not stand in
for the npm/browser commands. The forced native command reruns expectations,
Cram/runtime tests, and the default differential campaign instead of relying on
cached test actions. SDK selection is performed by repository scripts; manual
native rebuilding may also require the supplied read-only SDK setting.

Browser installation and fresh-checkout prerequisites are documented in README.
The supplied `PLAYWRIGHT_BROWSERS_PATH=0` uses project-local node_modules storage;
`npm ci` replaces that directory, so reinstall the browser afterward. A missing
browser is a failed/unverified browser check, not an automatic success.

Longer property replay is explicit:

```sh
TERN_DIFF_SEED=171717 TERN_DIFF_COUNT=500 scripts/check.sh
```

The generator prints feature counts and seeds. Keep minimized confirmed failures
as source fixtures; do not change expected output to conceal a mismatch.

## Review observations

The final native/site/JavaScript/Chromium checks are rerun for this review; their
scope is the local toolchain, not an unexecuted platform matrix. The suites cover:

- 34 offline infrastructure/document contracts, including roadmap arithmetic,
  license metadata/notices, exact setup-version matching, and repository boundaries;
- 16 examples and five curated programs through AST/IR/Wasm, with baseline,
  individual passes, and every pass enabled;
- 150 cases per default execution property and 500 typed generation/shrink cases;
- 21 real-Wasm runtime tests, plus compiler phase/Cram tests, retained-live-data
  OOM, and a 10-million-step tail loop;
- both optimized and unoptimized two-million-iteration GC churn: more than
  256 MiB cumulative physical requests in exactly 64 KiB linear memory, with
  value-sensitive captures retained across collecting non-tail calls;
- a 20,000-node retained list, required growth, iterative tracing, and complete
  reclamation after the source invocation;
- eight generated-JavaScript tests, including all examples with collection forced
  before every allocation through the default non-optimized browser compiler,
  plus executable README tour snippets and byte-exact distributed notices;
- nine real Chromium UI tests, including all dropdown examples, errors/warnings,
  partial runtime output, cancellation, limits, safe text, tab keys, edit races,
  responsive viewport layout, and the readable license page.

The current-GC benchmark runner was also replayed across **all 30 configurations**
(five programs × baseline/four individual passes/all). Every configuration
assembled, validated, and matched actual AST stdout. No transient output report
was retained. This functional replay is not isolated performance/latency evidence;
`OPTIMIZATIONS.md` remains explicitly historical pre-GC data. The runner's current
managed-byte metric is an ending cursor, not peak or live bytes.

`npm audit --json` returned zero known vulnerabilities for the current locked
production/development dependency graph. The registry response is date-specific
and does not prove the compiler, browser engine, or dependencies are vulnerability-
free. No dependency update was justified by that result.

`opam lint ternc.opam` now exits **0**. The supplied copyright owner is represented
in Dune-generated author/maintainer fields, and project license metadata is MIT
in Dune/opam/npm. Warnings 35 (homepage) and 36 (bug-reports) remain because no
canonical project repository URL was provided. The approved GitHub owner is
`mkizilov`; a nonexistent project/issue URL or personal email is not invented.

## Licensing and publication hygiene

The root MIT license is complete with copyright **2026 Mykyta Kizilov**. Native
documentation and the static site retain it, THIRD_PARTY_NOTICES.md, and verbatim
upstream texts (including OCaml/js_of_ocaml/Menhir linking exceptions, MIT/ISC/BSD
terms, Unicode data terms, and all 15 bundled npm runtime dependency notices).
The browser legal page makes those terms readable; byte-for-byte tests protect
the original text assets. Dependencies are not relabeled as project-owned MIT.

The native package is also built/tested from a temporary clean source snapshot
using the existing local switch, then installed to a temporary repository-local
prefix. The installed CLI is executed and installed legal texts are checked.
This is a clean-source/package check, not a fresh toolchain or remote installation.

Gitleaks **8.30.1** was downloaded locally from its official release and verified
against the release checksum. The reviewed macOS/ARM64 archive SHA-256 is
`b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5`.
The official assets/checksums are at
https://github.com/gitleaks/gitleaks/releases/tag/v8.30.1 . Install the matching
verified binary under `.tools/bin/gitleaks`, never globally. The publication script
requires that version, uses default rules with redacted output and bounded time,
scans a current tracked/unignored-source snapshot and all referenced Git history,
and removes its temporary snapshot. No baseline suppression or history rewrite
is used. It additionally rejects tracked build/cache artifacts, project creation-
attribution wording, and personal machine paths in project-owned text. Copyright
and required third-party notices are preserved.

No secret finding or current personal-machine path was detected. Historical
`AGENTS.md` at initial commit `4b3801f` contains a non-secret local workspace path,
removed from the current tree by `3e507f4`; that historical privacy breadcrumb
remains because history is not rewritten. It is not a detected credential, and
owner review of retained historical metadata is still appropriate. All earlier
commit hashes, branch/tag references, and author/committer identities are retained.
The only creation-wording search hit was a technical description of a private
record produced by Check.prepare, not project creation attribution.

The setup replay exposed and fixed an exact-string version comparison that would
redownload wasm-tools 1.263.0 merely because its version includes commit/date
metadata. A regression accepts only the exact pinned version with optional release
metadata, rejects 1.263.00, and retains checksum/failure-cleanup tests. Earlier DNS
failures remain historical observations in DESIGN.md, not current limitations.

## Observed tools and unverified environments

| Tool / environment | Observed version or scope |
| --- | --- |
| OS/CPU | macOS / ARM64 |
| OCaml | 5.4.1, project-local switch |
| Dune | 3.24.2 |
| js_of_ocaml | 6.5.0 in the existing switch |
| wasm-tools | 1.263.0 (7a2fa422c, 2026-10-30) |
| Node / npm | v26.13.0 / 11.20.0 |
| Browser tooling | pinned Playwright 1.65.0 Chromium headless shell, one worker |
| Secret scanning | project-local Gitleaks 8.30.1, default rules, full referenced history |

Fresh-switch bootstrap, Linux/x86_64 execution, other Node versions, Firefox,
WebKit/Safari, actual mobile devices, public deployment, publication, and isolated
performance benchmarks were **not verified here**. Docker/hardware/host-service
access is neither required nor exercised.
Signing credentials were not accessed and no signed artifact is claimed. No
GitHub repository was created and no push or public deployment was performed.

AFT lacks ocamllsp and uses a fallback JavaScript analyzer; its partial snapshot
is not an OCaml clean bill of health. Native compilation/tests and executed Wasm
are authoritative. Cram's occasional Perl classification is a tooling gap, not
a compiler diagnosis. Reachability/unused-export hints do not justify deletion.
Owned browser/server lifecycles and the closed loopback endpoint verify cleanup;
host-wide process enumeration is sandbox-restricted and is not bypassed.
