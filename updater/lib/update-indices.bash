declare -r UPDATE_INDICES_BASH= 2> /dev/null || return 0

set -e

source config.bash || exit 2
source util.bash || exit 2

function _UpdateFileIndex {
    local fileindex="$1"
    local git_dir="$2"

    Log "updating file index"
    find "$git_dir" -name .git -prune -o -type f -fprintf "$fileindex"~ '%P\n'
    mv "$fileindex"~ "$fileindex"
}

function _UpdateIndex {
    local index="$1"
    local cindex="$2"
    local git_dir="$3"

    PrettyPath "$index"
    local shortIndex="$OUT"

    Log "updating code search index"
    CSEARCHINDEX="$index"~ "$cindex" "$git_dir"/* &> /dev/null
    mv "$index"~ "$index"
}

UpdateIndices() {
    local configfile="$1"

    ReadConfig "$configfile"

    config::resolve::code
    local reposDir="$OUT3"

    config::resolve::index
    local indexFile="$OUT3"

    config::resolve::fileindex
    local fileIndexFile="$OUT3"

    config::resolve::gopath
    local cindexPath="$OUT3"/bin/cindex

    test -e "$cindexPath" ||
        Fail "cindex not found from configured gopath: '$cindexPath'"

    _UpdateFileIndex "$fileIndexFile" "$reposDir"
    _UpdateIndex "$indexFile" "$cindexPath" "$reposDir"
}
