The real command must reproduce the complete golden corpus without trimming.

  $ count=0
  $ for program in ../examples/*.tern; do
  >   expected="${program%.tern}.out"
  >   ternc run --interp "$program" > actual.out || exit 1
  >   cmp "$expected" actual.out || exit 1
  >   count=$((count + 1))
  > done
  $ test "$count" -eq 15
  $ printf '%s interpreter outputs matched byte-for-byte\n' "$count"
  15 interpreter outputs matched byte-for-byte

Output already written survives a runtime error; diagnostics stay on stderr.

  $ cat > failure.tern <<'TERN'
  > let () = print_string "before"; print_int (1 / 0);;
  > TERN
  $ ternc run --interp failure.tern > partial.out 2> runtime.err
  [1]
  $ printf before > expected.out
  $ cmp expected.out partial.out
  $ test -s runtime.err

Default run compiles the same supported program and retains output on a trap.

  $ ternc run failure.tern > no-run.out 2> no-run.err
  [1]
  $ cmp expected.out no-run.out

Ill-typed code is rejected before any effect, including preceding declarations.

  $ cat > invalid.tern <<'TERN'
  > let () = print_string "must not run";;
  > let bad = 1 + true;;
  > TERN
  $ ternc run --interp invalid.tern > invalid.out 2> invalid.err
  [1]
  $ test ! -s invalid.out
