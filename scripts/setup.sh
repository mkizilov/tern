#!/bin/bash
set -eu
. "$(dirname -- "$0")/env.sh"

OPAM_VERSION=2.6.1
OCAML_VERSION=5.5.2
WASM_TOOLS_VERSION=1.263.0

case "$(uname -s)" in
    Darwin) os=macos ;;
    Linux) os=linux ;;
    *) echo 'Supported hosts: macOS and Linux (ARM64 or x86_64).' >&2; exit 1 ;;
esac
case "$(uname -m)" in
    arm64|aarch64) opam_arch=arm64; wasm_arch=aarch64 ;;
    x86_64) opam_arch=x86_64; wasm_arch=x86_64 ;;
    *) echo 'Unsupported CPU (expected ARM64 or x86_64).' >&2; exit 1 ;;
esac

scratch=$(mktemp -d "$TMPDIR/tern-setup.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
trap 'exit 1' HUP INT TERM

download() {
    url=$1
    asset=$2
    curl --fail --location --silent --show-error --retry 2 --connect-timeout 20 \
        "$url/$asset" -o "$scratch/$asset"
    expected=
    while read -r digest filename; do
        if [ "$filename" = "$asset" ]; then expected=$digest; break; fi
    done < "$ROOT/scripts/tool-checksums.sha256"
    [ -n "$expected" ] || { echo "Missing checksum: $asset" >&2; exit 1; }
    if command -v sha256sum >/dev/null 2>&1; then
        actual=$(sha256sum "$scratch/$asset")
    else
        actual=$(shasum -a 256 "$scratch/$asset")
    fi
    [ "${actual%% *}" = "$expected" ] || { echo "Checksum mismatch: $asset" >&2; exit 1; }
}

if [ ! -x "$ROOT/.tools/bin/opam" ] || [ "$(opam --version)" != "$OPAM_VERSION" ]; then
    asset="opam-$OPAM_VERSION-$opam_arch-$os"
    download "https://github.com/ocaml/opam/releases/download/$OPAM_VERSION" "$asset"
    chmod +x "$scratch/$asset"
    mv "$scratch/$asset" "$ROOT/.tools/bin/opam"
fi

if [ ! -x "$ROOT/.tools/bin/wasm-tools" ] || [ "$(wasm-tools --version)" != "wasm-tools $WASM_TOOLS_VERSION" ]; then
    asset="wasm-tools-$WASM_TOOLS_VERSION-$wasm_arch-$os.tar.gz"
    download "https://github.com/bytecodealliance/wasm-tools/releases/download/v$WASM_TOOLS_VERSION" "$asset"
    tar -xzf "$scratch/$asset" -C "$scratch" \
        "wasm-tools-$WASM_TOOLS_VERSION-$wasm_arch-$os/wasm-tools"
    chmod +x "$scratch/wasm-tools-$WASM_TOOLS_VERSION-$wasm_arch-$os/wasm-tools"
    mv "$scratch/wasm-tools-$WASM_TOOLS_VERSION-$wasm_arch-$os/wasm-tools" "$ROOT/.tools/bin/wasm-tools"
fi

if [ ! -f "$OPAMROOT/config" ]; then
    opam init --bare --no-setup --yes
fi
if [ ! -d "$ROOT/_opam" ]; then
    opam switch create . --empty --yes
fi
opam install --switch="$ROOT" --yes --no-depexts "ocaml-base-compiler.$OCAML_VERSION" dune
opam exec --switch="$ROOT" -- dune build @opam -j 2
opam install . --switch="$ROOT" --deps-only --with-test --yes --no-depexts
opam exec --switch="$ROOT" -- ocamlc -version
wasm-tools --version
echo 'Setup complete. Run scripts/check.sh.'
