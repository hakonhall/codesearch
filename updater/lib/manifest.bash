declare -r MANIFEST_BASH &> /dev/null || return 0

source util.bash || exit 2

function manifest::ParseLine {
    local line="$1"

    local S=' +'
    if ! [[ "$line" =~ ^($SECTION_VALUE_RE0)$S($ORGREPO_RE1)($S$GIT_REF_RE1($S($DIR_RE1))?)?$ ]]
    then
        Fail "Invalid manifest line: '$line'"
    fi

    local server="${BASH_REMATCH[1]}"
    local orgrepo="${BASH_REMATCH[2]}"
    local ref="${BASH_REMATCH[5]}"
    local dir="${BASH_REMATCH[7]}"

    (( ${#dir} > 0 )) || dir="$server/$orgrepo"

    OUT="$server"
    OUT2="$orgrepo"
    OUT3="$ref" # May be empty
    OUT4="$dir" # Defaults to server/org/repo
}
