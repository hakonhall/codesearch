declare -r GITHUB_BASH= 2>/dev/null || return 0

set -e

source util.bash || exit 2
source config.bash || exit 2

# Requires the config to have been read already.
GetReposOfOrg() {
    local server="$1"
    local org="$2"

    _GetRepos "$server" "$org" org
}

# Requires the config to have been read already.
GetReposOfUser() {
    local server="$1"
    local user="$2"

    _GetRepos "$server" "$user" user
}

_GetRepos() {
    local server="$1"
    local org="$2"  # The org (or user) name
    local type="$3"  # either "org" or "user"

    VerifyConfig
    
    local -a manifest=()
    local -i page=1 pagesize=100
    while true
    do
        local pathQuery="/${type}s/$org/repos?page=$page&per_page=$pagesize"
        _CurlGitHub "$server" "$pathQuery"
        local json="$OUT"

        # Avoid sorting: cannot be done across pages anyways
        jq -r '.[].full_name' <<< "$json" | while read -r
        do
            [[ "$REPLY" =~ ^([^' ']+)/([^' ']+)$ ]] ||
                Fail "Invalid full name of repository: $REPLY"
            local altorg="${BASH_REMATCH[1]}"
            test "$org" == "$altorg" ||
                Fail "Invalid $type of full name repository for " \
                     "'$org': $altorg"
            local name="${BASH_REMATCH[2]}"
            manifest+=("$server $altorg/$name")
        done

        if (( ${#manifest[@]} < page * pagesize )); then
            break
        fi
        page+=1
    done

    OUTA=("${manifest[@]}")
}

_CurlGitHub() {
    local server="$1"
    local pathQuery="$2"

    ResolveGitHubServer "$server"
    local api="$OUT"
    local token="$OUT2"

    local url="$api$pathQuery"

    local -a auth=()
    if test "$token" != ""; then
        auth+=(-H "Authorization: token $token")
    fi

    local -a args=(-s -f
                   "${auth[@]}"
                   -H "Accept: application/vnd.github.v3+json"
                   "$url")
    
    Capture curl "${args[@]}"
 }
