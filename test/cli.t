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
