The entire corpus is compiled, validated, executed, and compared byte-for-byte.

  $ count=0
  $ for source in ../examples/*.tern; do
  >   ternc build "$source" -o compiled.wasm || exit 1
  >   wasm-tools validate compiled.wasm || exit 1
  >   node ../runtime/run.mjs compiled.wasm > built.out || exit 1
  >   ternc run "$source" > run.out || exit 1
  >   cmp "${source%.tern}.out" built.out || exit 1
  >   cmp built.out run.out || exit 1
  >   count=$((count + 1))
  > done
  $ test "$count" -eq 15
  $ printf '%s compiled example outputs match golden bytes\n' "$count"
  15 compiled example outputs match golden bytes

Embedded runtime and runner assets work from a directory with no repository assets.

  $ mkdir 'work dir'
  $ cp ../examples/01_hello.tern 'work dir/input file.tern'
  $ cd 'work dir'
  $ mkdir scratch
  $ TMPDIR="$PWD/scratch" ternc build 'input file.tern' -o 'output file.wasm'
  $ TMPDIR="$PWD/scratch" ternc run 'input file.tern'
  Hello, Tern!
  $ test -z "$(ls -A scratch)"
  $ ternc build 'input file.tern' -o 'input file.tern' > input.out 2> input.err
  [1]
  $ test ! -s input.out
  $ cmp ../../examples/01_hello.tern 'input file.tern'
  $ cd ..

Neither a type error nor a parse error replaces existing output.

  $ printf sentinel > protected.wasm
  $ printf 'let bad = 1 + true;;\n' > invalid.tern
  $ ternc build invalid.tern -o protected.wasm > invalid.out 2> invalid.err
  [1]
  $ test ! -s invalid.out
  $ printf sentinel > expected
  $ cmp expected protected.wasm
  $ printf 'let value = if true then 1;;\n' > syntax.tern
  $ ternc build syntax.tern -o protected.wasm > unsupported.out 2> unsupported.err
  [1]
  $ test ! -s unsupported.out
  $ cmp expected protected.wasm

Assembler success is not enough: invalid binaries must fail validation before publish.

  $ mkdir fake-bin scratch
  $ cat > fake-bin/wasm-tools <<'SH'
  > #!/bin/bash
  > if [ "$1" = parse ]; then
  >   while [ "$1" != -o ]; do shift; done
  >   printf 'not a wasm binary' > "$2"
  >   exit 0
  > fi
  > echo validation-rejected >&2
  > exit 17
  > SH
  $ chmod +x fake-bin/wasm-tools
  $ PATH="$PWD/fake-bin:$PATH" TMPDIR="$PWD/scratch" ternc build ../examples/01_hello.tern -o protected.wasm > tool.out 2> tool.err
  [1]
  $ test ! -s tool.out
  $ test -s tool.err
  $ cmp expected protected.wasm
  $ test -z "$(ls -A scratch)"

Runtime arithmetic failures keep stdout and return a failed status.

  $ printf 'let () = print_string "before"; print_int (-2147483648 mod (-1));;\n' > overflow.tern
  $ ternc run overflow.tern > partial.out 2> runtime.err
  [1]
  $ printf before > expected
  $ cmp expected partial.out
  $ test -s runtime.err

Both division and remainder reject zero and the minimum-integer overflow pair.

  $ for expression in '1 / 0' '1 mod 0' '-2147483648 / (-1)' '-2147483648 mod (-1)'; do
  >   printf 'let value = %s;;\n' "$expression" > bad-arithmetic.tern
  >   status=0
  >   ternc run bad-arithmetic.tern > arithmetic.out 2> arithmetic.err || status=$?
  >   test "$status" -eq 1 || exit 1
  >   test ! -s arithmetic.out || exit 1
  >   test -s arithmetic.err || exit 1
  > done

Build requires an explicit output filename.

  $ ternc build ../examples/01_hello.tern > usage.out 2> usage.err
  [2]
  $ test ! -s usage.out

Ten million tail calls run in bounded heap memory without growing the Wasm stack.

  $ cat > deep.tern <<'TERN'
  > let rec loop n = if n = 0 then 42 else loop (n - 1);;
  > let () = print_int (loop 10000000); print_string "\n";;
  > TERN
  $ ternc build deep.tern -o deep.wasm
  $ node --input-type=module - deep.wasm <<'JS'
  > import assert from 'node:assert/strict';
  > import { readFileSync } from 'node:fs';
  > import { instantiate } from '../runtime/run.mjs';
  > const instance = await instantiate(readFileSync(process.argv[2]));
  > instance.exports._start();
  > assert.ok(instance.exports.rt_heap_top() < 65536);
  > console.log('10,000,000 tail calls completed; heap below one page');
  > JS
  42
  10,000,000 tail calls completed; heap below one page

Non-exhaustive matching fails at runtime without losing preceding output.

  $ cat > missing.tern <<'TERN'
  > type option = None | Some of int;;
  > let get x = match x with Some n -> n;;
  > let () = print_string "before"; print_int (get None);;
  > TERN
  $ ternc run missing.tern > missing.out 2> missing.err
  [1]
  $ printf before > expected
  $ cmp expected missing.out
  $ test -s missing.err
