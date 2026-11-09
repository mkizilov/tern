# IR optimization measurements

**Historical turn-15 measurements, before the turn-17 collector and 16-byte
headers.** The table below is retained as observed, not relabeled as current GC
performance. Re-running the documented runner measures the current collector and
labels ending managed bytes instead of the old bump-only metric.

Observed on v26.13.0, darwin/arm64; wasm-tools 1.263.0 (7a2fa422c 2026-10-30).
Compiler: project-local OCaml 5.4.1. Five fixed programs, six configurations. Each cell is validated and checked against AST stdout.

## Method

Inputs: naive Fibonacci(24); insertion sort of a descending 300-element list plus order-sensitive checksum; persistent binary-search-tree insertion of 1,000 permuted keys and lookup sum; 4,000 string appends (8,000 output bytes plus LF); 10,000 closure-heavy iterations with option wrapping and a small helper.
Each configuration starts from the same checked source. Baseline disables every pass; each individual column enables only that pass; all uses inline → constants → matches → DCE. Flags are opt-in and default off.
Runtime is median of 7 fresh-instance `_start` executions after 2 warmups. Configurations are interleaved per round with rotating order, rather than measuring one configuration in a batch. Compilation, assembly, validation, instantiation, and host GC are excluded; output-byte capture is included. Node host GC runs before each sample, not inside the measured interval. No source-language collector is implemented.
The host uses `--max-old-space-size=256`; each Wasm instance is capped at 64 MiB. Measurements are sequential. Timing differences near timer/JIT noise are not speedup claims.

| Program | Pass | Wasm bytes | Median ms | Size Δ | Time Δ | Same binary as baseline | Peak bump bytes | Linear bytes |
| --- | --- | ---: | ---: | ---: | ---: | --- | ---: | ---: |
| fibonacci | baseline | 3357 | 2.3772 | 0.0% | 0.0% | yes | 104 | 65536 |
| fibonacci | constants | 3321 | 2.1090 | -1.1% | -11.3% | no | 96 | 65536 |
| fibonacci | dce | 3357 | 2.3961 | 0.0% | 0.8% | yes | 104 | 65536 |
| fibonacci | inline | 3357 | 2.4185 | 0.0% | 1.7% | yes | 104 | 65536 |
| fibonacci | matches | 3357 | 2.3912 | 0.0% | 0.6% | yes | 104 | 65536 |
| fibonacci | all | 3301 | 2.0773 | -1.7% | -12.6% | no | 96 | 65536 |
| list_sort | baseline | 4988 | 4.9854 | 0.0% | 0.0% | yes | 4717416 | 4784128 |
| list_sort | constants | 4988 | 4.9755 | 0.0% | -0.2% | yes | 4717416 | 4784128 |
| list_sort | dce | 4988 | 4.9662 | 0.0% | -0.4% | yes | 4717416 | 4784128 |
| list_sort | inline | 4988 | 4.9773 | 0.0% | -0.2% | yes | 4717416 | 4784128 |
| list_sort | matches | 4988 | 4.9876 | 0.0% | 0.0% | yes | 4717416 | 4784128 |
| list_sort | all | 4988 | 4.9582 | 0.0% | -0.5% | yes | 4717416 | 4784128 |
| tree_map | baseline | 6094 | 5.3315 | 0.0% | 0.0% | yes | 2988984 | 3014656 |
| tree_map | constants | 6094 | 5.3178 | 0.0% | -0.3% | no | 2988984 | 3014656 |
| tree_map | dce | 6094 | 5.3226 | 0.0% | -0.2% | yes | 2988984 | 3014656 |
| tree_map | inline | 6094 | 5.3249 | 0.0% | -0.1% | yes | 2988984 | 3014656 |
| tree_map | matches | 6094 | 5.3225 | 0.0% | -0.2% | yes | 2988984 | 3014656 |
| tree_map | all | 6085 | 5.3667 | -0.1% | 0.7% | no | 2988984 | 3014656 |
| string_build | baseline | 3640 | 3.3182 | 0.0% | 0.0% | yes | 16240208 | 16252928 |
| string_build | constants | 3530 | 3.3481 | -3.0% | 0.9% | no | 16272176 | 16318464 |
| string_build | dce | 3640 | 3.3439 | 0.0% | 0.8% | yes | 16240208 | 16252928 |
| string_build | inline | 3640 | 3.3313 | 0.0% | 0.4% | yes | 16240208 | 16252928 |
| string_build | matches | 3640 | 3.3430 | 0.0% | 0.7% | yes | 16240208 | 16252928 |
| string_build | all | 3513 | 3.3459 | -3.5% | 0.8% | no | 16272144 | 16318464 |
| closures | baseline | 4334 | 3.1949 | 0.0% | 0.0% | yes | 1360256 | 1376256 |
| closures | constants | 4325 | 3.2385 | -0.2% | 1.4% | no | 1360256 | 1376256 |
| closures | dce | 4303 | 3.2477 | -0.7% | 1.7% | no | 1360256 | 1376256 |
| closures | inline | 4454 | 2.5818 | 2.8% | -19.2% | no | 1120208 | 1179648 |
| closures | matches | 4334 | 3.1913 | 0.0% | -0.1% | yes | 1360256 | 1376256 |
| closures | all | 3767 | 2.5831 | -13.1% | -19.1% | no | 1120136 | 1179648 |

Maximum sampled ending host RSS: 35359048 bytes (not a continuous peak measurement). No generated dataset is retained; build artifacts are removed in finally.

## Reproduce

```sh
scripts/check.sh
PATH="$PWD/.tools/bin:$PATH" node --expose-gc --max-old-space-size=256 benchmarks/measure.mjs > OPTIMIZATIONS.md
```

## Scope and safety

Constant folding/propagation uses int32 semantics and leaves invalid division/remainder to trap at runtime. DCE removes unused total values/functions and unreachable case actions while retaining calls, tuple/constructor/concat operations, projections, and arithmetic traps. Inlining copies small non-recursive bodies with fresh identities; it is not recursive unrolling. Known-constructor simplification selects proven decision arms and safe projections without dropping subject effects.
None of these passes guarantees lower runtime or smaller output in every program. The complete hand-written runtime remains embedded, so IR reductions can be small relative to runtime bytes. Each pass is independently tested and the all-enabled pipeline is covered by AST/IR/Wasm differential properties. Resource-exhaustion timing is not an optimization equivalence guarantee.
Rows with identical SHA-256 binary content still vary in measured time: those differences are host/JIT/order noise, not optimizer improvements. Constant propagation can also duplicate literal construction at use sites; lower binary size does not guarantee fewer allocations (see string building).
An earlier batched trial showed a 62.4% apparent list-sort slowdown for identical bytes. That observation prompted interleaved rounds for the final table; even interleaving does not isolate the shared host or justify significance claims.
