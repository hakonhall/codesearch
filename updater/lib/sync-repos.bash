declare -r SYNC_REPOS_BASH 2>/dev/null || return 0

set -e

source config.bash || exit 2
source constants.bash || exit 2
source manifest.bash || exit 2
source util.bash || exit 2

function SyncRepos {
    local configfile="$1"

    ReadConfig "$configfile"

    config::resolve::repos-manifest
    local repos_manifest="$OUT"

    config::resolve::code
    local reposDir="$OUT"
    local savedPwd="$PWD"
    cd "$reposDir"

    local -A visited_dirs=()
    local -A orphaned_dirs=()
    local d
    for d in ./*
    do
        orphaned_dirs["$d"]=1
    done
    visited_dirs[.]=1

    local comp_re="[a-zA-Z0-9_#.-]+"
    while read -r
    do
        manifest::ParseLine "$REPLY"
        local server="$OUT"
        local orgrepo="$OUT2"
        local ref="$OUT3"
        local dir="$OUT4"

        local prefix_d=.
        local suffix_d="$dir"
        while true
        do
            prefix_d+=/"${suffix_d%%/*}"
            suffix_d="${suffix_d#*/}"

            unset "orphaned_dirs[$prefix_d]"

            test "$prefix_d" != ./"$dir" || break
            (( ${#prefix_d} < 2 + ${#dir} )) ||
                Fail "Failed to traverse on path: '$dir'"

            if ! test -v "visited_dirs[$prefix_d]"; then
                for d in "$prefix_d"/*; do
                    orphaned_dirs["$d"]=1
                done
            fi
            visited_dirs["$prefix_d"]=1
        done

        if [ -d "$dir" ] && ! [ -s "$dir"/.git/index ]
        then
            Log "corrupt $dir/.git/index"
            rm -rf "$dir"
        fi

        if [ -d "$dir" ]
        then
            Log "updating $dir"
            pushd "$dir" > /dev/null
            if (( ${#ref} == 0 )); then
                git pull --rebase > /dev/null
            elif [[ "$ref" =~ ^[0-9a-f]{40}$ ]]
            then
                git fetch -q
                # Set 'git config advice.detachedHead false' to reduce noise
                # Allow non-existing references(!)
                git checkout -q "$ref" || true
            else
                git fetch -q
                git checkout -q "$ref"
                git rebase -q
            fi
            popd > /dev/null
        else
            local url="${GITHUB_URLS[$server]}"
            (( ${#url} > 0 )) || Fail "No URL found for server '$server'"

            local -i nurl="${#url}"
            local lastUrlChar="${url:$((nurl - 1)):1}"
            if [[ "$url" =~ ^([a-z]+@)?$DNS_RE0($|:) ]]
            then
                case "${BASH_REMATCH[3]}" in
                    '') url+=: ;;
                    ':')
                        case "$lastUrlChar" in
                            ':') : ;;
                            '/') : ;;
                            *) url+=/
                        esac
                        ;;
                esac
                url+="$orgrepo".git
            elif [[ "$url" =~ ^https://([a-z0-9]+@)?$DNS_RE0(:[0-9]+)?($|/) ]] ||
                 [[ "$url" =~ ^ssh://([a-z]+@)?$DNS_RE0(:[0-9]+)?($|/) ]]
            then
                case "$lastUrlChar" in
                    '/') : ;;
                    *) url+=/
                esac
                url+="$orgrepo".git
            else
                Fail "Invalid URL: '$url'"
            fi

            Log "cloning to $dir"
            git clone -q "$url" "$dir"
            # Set 'git config advice.detachedHead false' to reduce noise
            # Allow non-existing refs(!)
            (( ${#ref} == 0 )) || git -C "$dir" checkout -q "$ref" || true
        fi
    done < "$repos_manifest"

    local -a dirs_to_remove=("${!orphaned_dirs[@]}")
    if ((${#dirs_to_remove[@]} > 0))
    then
        local dir
        for dir in "${dirs_to_remove[@]}"
        do
            if test -d "$dir"; then
                # Double-check we're about to remove a directory below PWD.
                local curDir="$PWD"
                cd "$dir" || Fail "Failed to cd to '$dir'"
                local toRm="$PWD"
                cd "$curDir" || Fail "Failed to cd to '$curDir'"
                [[ "$toRm" == "$curDir"/* ]] ||
                    Fail "Was about to remove '$toRm'"
            fi                
            Log "removing $dir"
            rm -rf "$dir"
        done
        # Removes servers and org without repos
        rmdir --parents --ignore-fail-on-non-empty */*
    fi

    cd "$savedPwd"
}
