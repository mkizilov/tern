The check command prints principal schemes only when --types is present.

  $ cat > polymorphic.tern <<'TERN'
  > let id x = x;;
  > let pair = (id 1, id true);;
  > TERN
  $ ternc check polymorphic.tern --types
  val id : 'a -> 'a
  val pair : int * bool
  $ ternc check polymorphic.tern

Diagnostics go to stderr and no partial type report is printed on failure.

  $ cat > mismatch.tern <<'TERN'
  > let id x = x;;
  > let bad = 1 + true;;
  > TERN
  $ ternc check mismatch.tern --types > types.out 2> error.out
  [1]
  $ test ! -s types.out
  $ cat error.out
  error: type mismatch: expected int, but got bool
   --> mismatch.tern:2:15
    |
  2 | let bad = 1 + true;;
    |               ^^^^

Help does not require an input file.

  $ ternc --help
  Usage: ternc check [--types] FILE.tern
         ternc run (--interp | --ir) FILE.tern
         ternc dump-ir FILE.tern

Pattern warnings are non-fatal and coexist with a successful type report.

  $ cat > partial.tern <<'TERN'
  > let f x =
  >   match x with
  >   | true -> 1;;
  > TERN
  $ ternc check partial.tern --types > partial.types 2> partial.warnings
  $ cat partial.types
  val f : bool -> int
  $ cat partial.warnings
  warning: non-exhaustive pattern match
   --> partial.tern:2:3
    |
  2 |   match x with
    |   ^^^^^^^^^^^^
  3 |   | true -> 1;;
    | ^^^^^^^^^^^^^
   = note: example of an unmatched value: false
