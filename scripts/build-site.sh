#!/bin/bash
set -eu
. "$(dirname -- "$0")/env.sh"

if [ ! -x node_modules/.bin/esbuild ]; then
    echo 'Local JavaScript dependencies missing. Run npm ci first.' >&2
    exit 1
fi
opam exec --switch="$ROOT" -- dune build --root . -j 2 playground/compiler.bc.js
GOMAXPROCS=2 node playground/build.mjs
