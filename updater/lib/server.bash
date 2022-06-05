declare -r SERVER_BASH= 2> /dev/null || return 0

set -e

source config.bash || exit 2
source util.bash || exit 2

Server() {
    local configfile="$1"

    ReadConfig "$configfile"

    config::resolve::fileindex
    local fileindex="$OUT3"

    config::resolve::gopath
    local cserver="$OUT3"/bin/cserver
    test -e "$cserver" || Fail "cserver not found from gopath: '$cserver'"

    config::resolve::index
    local index="$OUT3"

    config::resolve::port
    local -i port="$OUT"

    config::resolve::code
    local code="$OUT"

    config::resolve::timefile
    local timefile="$OUT3"

    config::resolve::webdir
    local webdir="$OUT3"

    exec "$cserver" -f "$fileindex" -i "$index" -p "$port" -s "$code" \
         -t "$timefile" -w "$webdir"
}
