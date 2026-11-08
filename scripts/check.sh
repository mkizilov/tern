#!/bin/bash
set -eu
. "$(dirname -- "$0")/env.sh"

if [ ! -x "$ROOT/.tools/bin/opam" ] || [ ! -x "$ROOT/_opam/bin/dune" ]; then
    echo 'Local toolchain missing. Run scripts/setup.sh first.' >&2
    exit 1
fi
opam exec --switch="$ROOT" -- dune build --root . -j 2
opam exec --switch="$ROOT" -- dune test --root . -j 2
opam exec --switch="$ROOT" -- dune fmt --root . -j 2
