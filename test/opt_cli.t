Every optimization is independently opt-in for build/run/IR, and default output is unchanged.

  $ printf 'let inc x = x + 1;; let () = print_int (inc (1 + 2));;\n' > input.tern
  $ printf 4 > expected
  $ count=0
  $ for flag in --const-fold --dce --inline --match-simplify --opt-all; do
  >   ternc build "$flag" input.tern -o output.wasm || exit 1
  >   node ../runtime/run.mjs output.wasm > actual || exit 1
  >   cmp expected actual || exit 1
  >   ternc run --ir "$flag" input.tern > actual || exit 1
  >   cmp expected actual || exit 1
  >   count=$((count + 1))
  > done
  $ echo "$count configurations preserve output"
  5 configurations preserve output
  $ ternc run --opt-all input.tern > actual
  $ cmp expected actual
  $ ternc dump-ir input.tern > original.ir
  $ ternc dump-ir --opt-all input.tern > optimized.ir
  $ cmp -s original.ir optimized.ir
  [1]
  $ ternc run --interp --inline input.tern
  IR optimizations cannot be combined with --interp
  [2]
