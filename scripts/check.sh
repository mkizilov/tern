#!/bin/bash
set -eu
. "$(dirname -- "$0")/env.sh"

if [ ! -x "$ROOT/.tools/bin/opam" ] || [ ! -x "$ROOT/_opam/bin/dune" ]; then
    echo 'Local toolchain missing. Run scripts/setup.sh first.' >&2
    exit 1
fi
opam exec --switch="$ROOT" -- dune build -j 2
opam exec --switch="$ROOT" -- dune test -j 2
opam exec --switch="$ROOT" -- dune fmt -j 2
