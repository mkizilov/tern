Both interpreters run the same real checked inputs and match exact golden bytes.

  $ count=0
  $ for source in ../examples/*.tern; do
  >   ternc run --interp "$source" > ast.out || exit 1
  >   ternc run --ir "$source" > ir.out || exit 1
  >   cmp ast.out ir.out || exit 1
  >   cmp "${source%.tern}.out" ir.out || exit 1
  >   count=$((count + 1))
  > done
  $ test "$count" -eq 15
  $ printf '%s AST/IR/golden outputs agree\n' "$count"
  15 AST/IR/golden outputs agree

Dumping IR is not execution and gives named primitive operands.

  $ printf 'let x = (1 + 2) * 3;;\n' > arithmetic.tern
  $ ternc dump-ir arithmetic.tern
  builtin print_int#0
  builtin print_string#1
  let $anf#7 = Add(1, 2)
  let $anf#8 = Multiply($anf#7, 3)
  let x#6 = $anf#8
  return ()

Backend selection is unambiguous.

  $ ternc run --ir --interp arithmetic.tern > conflict.out 2> conflict.err
  [2]
  $ test ! -s conflict.out
