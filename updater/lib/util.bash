declare -r UTIL_BASH= 2>/dev/null || return 0

set -o pipefail
shopt -s lastpipe nullglob

# General purpose output parameters
declare OUT OUT2 OUT3
declare -a OUTA=() OUTA2=()

Fail() { printf "%s" "$@"; echo; exit 1; } >&2
Failf() { printf "$@" >&2; exit 1; }

Log() {
    if test -t 1
    then
        TZ=UTC printf "%(%Y-%m-%dT%H:%M:%S)T %s\n" -1 "$*"
    else
        local message
        printf -v message "%s" "$@"
        printf "%s\n" "$message"
    fi
}

RequireProgram() { type "$1" &> /dev/null || Fail "Program not found: $1"; }

Capture() {
    local program="$1"
    shift

    if OUT=$("$program" "$@"); then
        # mapfile -t OUTA <<< "$OUT"
        :
    else
        printf "error: exit status $?: %q" "$program" >&2
        printf " %q" "$@" >&2
        printf "\n"
        exit 1
    fi
}

# Returns 0 if the string $1 matches the regex $2 using ASCII (C locale).  Range
# checks in bash(1) are broken, e.g. [[ "å" =~ [a-b] ]] returns true.
Match() {
    local LC_ALL=C
    [[ "$1" =~ $2 ]]
}

# Sets OUT to the canonical path of the (parent) directory of $1. $1 may not be
# canonical.
DirOf() {
    local path="$1"
    OUT=$(realpath -m "$path"/..) || Fail "Failed to find parent of '$path'"
}

CanonicalizePath() {
    OUT=$(realpath -m "$1")
}

# $1 is a non-canonical path.  Resolves symbolic links, removes "." and ".."
# elements, and collapses multiple sequential "/" into one.  Sets OUT to the
# absolute path or relative to PWD, depending on which is shorter.
PrettyPath() {
    local path="$1"
    local abs rel
    abs=$(realpath -m "$path")
    rel=$(realpath -m "$path" --relative-to .)
    if (( ${#abs} < ${#rel} )); then
        OUT="$abs"
    else
        OUT="$rel"
    fi
}
