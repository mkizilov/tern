#!/bin/bash
set -eu
. "$(dirname -- "$0")/env.sh"

if [ ! -f site/index.html ]; then
    echo 'Site missing. Run scripts/build-site.sh first.' >&2
    exit 1
fi
exec python3 -m http.server 21916 --bind 127.0.0.1 --directory site
