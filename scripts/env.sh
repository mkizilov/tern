# Sourced by repository scripts; do not source from an interactive shell.
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
cd "$ROOT"
: "${HOME:=$ROOT/.agent-local/home}"
: "${TMPDIR:=$ROOT/.agent-local/tmp}"
: "${OPAMROOT:=$ROOT/.agent-local/opam}"
: "${XDG_CACHE_HOME:=$ROOT/.agent-local/cache}"
: "${XDG_CONFIG_HOME:=$ROOT/.agent-local/config}"
: "${XDG_DATA_HOME:=$ROOT/.agent-local/data}"
for path in "$HOME" "$TMPDIR" "$OPAMROOT" "$XDG_CACHE_HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME"; do
    case "$path" in
        "$ROOT"/*) ;;
        *) echo "Refusing non-project state path: $path" >&2; exit 1 ;;
    esac
    mkdir -p "${path#"$ROOT"/}"
done
mkdir -p .tools/bin
export HOME TMPDIR OPAMROOT XDG_CACHE_HOME XDG_CONFIG_HOME XDG_DATA_HOME
PATH="$ROOT/.tools/bin:$PATH"
OPAMSWITCH="$ROOT"
OPAMJOBS=2
OPAMDOWNLOADJOBS=2
DUNEJOBS=2
MAKEFLAGS=-j2
export PATH OPAMSWITCH OPAMJOBS OPAMDOWNLOADJOBS DUNEJOBS MAKEFLAGS
