declare -r UPDATE_MANIFEST_BASH= 2>/dev/null || return 0

# Updates the repos file based on the config file.

set -e

source config.bash
source constants.bash
source github.bash
source manifest.bash

# Read the config file at path $1 and resolve which repositories and branches
# should be checked out, and save that to the path at $2.
ResolveGitBranches() {
    local configfile="$1"
    local reposfile="$2" # Defaults to repos-manifest from config
    local verbose="${3:-false}"

    ReadConfig "$configfile"
    configfile="$configfile"

    if test "$reposfile" == ""; then
        config::resolve::repos-manifest
        reposfile="$OUT3"
    else
        PrettyPath "$reposfile"
        reposfile="$OUT"
    fi

    config::resolve::repos-json
    local repos_json="$OUT3"

    > "$reposfile".unsorted || Fail "Failed to create $reposfile.unsorted"
    _ResolveIncludes "$configfile" "$reposfile".unsorted
    _ResolveManifestSections "$configfile" "$reposfile".unsorted
    sort -u "$reposfile".unsorted > "$reposfile".new
    rm "$reposfile".unsorted

    _WriteJsonManifest "$reposfile".new "$repos_json".new

    local diff exit_status
    if diff=$(diff -Nu "$reposfile"{,.new}); then
        :
    elif (( $? == 2 )); then
        Fail "Failed to diff '$reposfile' and '$reposfile.new', aborting"
    fi

    local -i nAdded=0 nRemoved=0
    while read -r
    do
        if [[ "$REPLY" =~ ^('+++'|---) ]]; then
            continue
        elif [[ "$REPLY" =~ ^'+' ]]; then
            nAdded+=1
        elif [[ "$REPLY" =~ ^- ]]; then
            nRemoved+=1
        fi
    done <<< "$diff"

    if $verbose; then
        printf "%s" "$diff"
    fi

    local -i n=0
    n=$(wc -l < "$reposfile".new) ||
        Fail "Failed to count lines in $reposfile.new"

    if (( nAdded > 0 )); then
        if (( nRemoved > 0 )); then
            Log "repos updated: $n repos (+$nAdded -$nRemoved)"
        else
            Log "repos updated: $n repos (+$nAdded)"
        fi
    else
        if (( nRemoved > 0 )); then
            Log "repos updated: $n repos (-$nRemoved)"
        else
            Log "repos unchanged: $n repos"
        fi
    fi

    # Try to update the files simultaneously.

    if test -e "$reposfile" && diff -q "$reposfile" "$reposfile".new
    then
        rm "$reposfile".new
    else
        mv "$reposfile".new "$reposfile"
    fi

    if test -e "$repos_json" && diff -q "$repos_json" "$repos_json".new
    then
        rm "$repos_json".new
    else
        mv "$repos_json".new "$repos_json"
    fi

    OUT="$reposfile"
    OUT2="$repos_json"
}

_ResolveIncludes() {
    local configfile="$1"
    local manifest="$2"

    local -a repos=()

    local server
    for server in "${GITHUB_SERVERS[@]}"
    do
        _ResolveForServer "$server"
        repos+=("${OUTA[@]}")
    done

    local repo
    for repo in "${repos[@]}"
    do
        echo "$repo"
    done | sort >> "$manifest"
}

_ResolveForServer() {
    local server="$1"

    local -a repos=()
    local -i nexcluded=0

    if (( ${#GITHUB_INCLUDES[$server]} > 0 ))
    then
        while read -r
        do
            local include="$REPLY"
            if (( ${#include} == 0 ))
            then
                : # The last line is empty!?
            else
                manifest::ParseLine "$server $include"
                repos+=("$server $include")
            fi
        done <<< "${GITHUB_INCLUDES[$server]}"

        while read -r
        do
            local include="$REPLY"
            if (( ${#include} == 0 ))
            then
                : # The last line is empty!?
            else
                GetReposOfOrg "$server" "$include"
                repos+=("${OUTA[@]}")
            fi
        done <<< "${GITHUB_INCLUDE_ORGS[$server]}"

        while read -r
        do
            local include="$REPLY"
            if (( ${#include} == 0 ))
            then
                : # The last line is empty!?
            else
                GetReposOfUser "$server" "$include"
                repos+=("${OUTA[@]}")
            fi
        done <<< "${GITHUB_INCLUDE_USERS[$server]}"

        local exclude_re="${GITHUB_EXCLUDES[$server]}"
        if (( ${#exclude_re} > 0 )); then
            local -i i=0
            for i in "${!repos[@]}"; do
                local line="${repos[$i]}"
                manifest::ParseLine "$line"
                local server="$OUT"
                local orgrepo="$OUT2"
                if [[ "$server/$orgrepo" =~ $exclude_re ]]; then
                    nexcluded+=1
                    unset "repos[$i]"
                fi
            done
        fi
    fi

    if (( nexcluded > 0 )); then
        Log "found ${#repos[@]} $server repos after excluding $nexcluded"
    else
        Log "found ${#repos[@]} $server repos"
    fi

    OUTA=("${repos[@]}")
}

_ResolveManifestSections() {
    local configfile="$1"
    local manifest="$2"

    VerifyConfig

    ResolveManifestSections
    local -a ids=("${OUTA[@]}")

    local id
    for id in "${ids[@]}"
    do
        ResolveManifestSection "$id"
        local path="$OUT"
        local -a command=("${OUTA[@]}")

        if (( ${#command[@]} > 0 ))
        then
            if "${command[@]}"
            then
                :
            else
                Fail "Failed to execute command: exit status $?: ${command[*]}"
            fi
        fi

        test -e "$path" || Fail "No such manifest file: $path"

        local server orgrepo ref dir
        while read -r server orgrepo ref dir
        do
            [[ "$server" =~ ^$SECTION_VALUE_RE0$ ]] ||
                Fail "Invalid server from manifest $path: '$server'"
            test -v "GITHUB_SERVERSH[$server]" ||
                Fail "Unknown server from manifest $path: '$server'"

            [[ "$orgrepo" =~ ^$ORGREPO_RE3$ ]] ||
                Fail "Invalid org/repo from manifest $path: '$orgrepo'"

            if (( ${#ref} == 0 ))
            then
                dir="" # bash guarantees this, but just to be sure
            else
                [[ "$ref" =~ ^$GIT_REF_RE1$ ]] ||
                    Fail "Invalid ref from manifest $path: '$ref'"

                # This should be impossible as bash would assign token to ref
                (( ${#dir} == 0 )) || [[ "$dir" =~ ^$DIR_RE1$ ]] ||
                    Fail "Invalid directory in manifest $path: '$dir'"
            fi
        done < "$path"

        cat "$path" >> "$manifest"
    done
}

_WriteJsonManifest() {
    local manifest="$1"
    local out="$2"

    local tmpout="$out"~

    echo "{" > "$tmpout"

    # servers

    echo "  \"servers\": [" >> "$tmpout"

    local -i i=0 nservers="${#GITHUB_SERVERS[@]}"
    local server
    for server in "${GITHUB_SERVERS[@]}"
    do
        local weburl="${GITHUB_WEBURLS[$server]}"
        (( ${#weburl} > 0 )) || Fail "Found no weburl for server '$server'"

        local comma=,
        if (( i == nservers - 1 )); then
            comma=
        fi

        echo "    {\"name\": \"$server\", \"url\": \"$weburl\" }$comma" \
             >> "$tmpout"
        i+=1
    done

    echo "  ]," >> "$tmpout"

    # branches

    echo "  \"branches\": [" >> "$tmpout"

    mapfile -t < "$manifest"
    i=0
    local -i nbranches="${#MAPFILE[@]}"
    local line
    for line in "${MAPFILE[@]}"
    do
        local orgrepo branch dir
        read -r server orgrepo branch dir <<< "$line" ||
            Fail "Failed to parse manifest line: '$line'"

        (( ${#server} > 0 )) || Fail "Empty server in manifest: $line"
        (( ${#orgrepo} > 0 )) || Fail "Empty repo in manifest: $line"

        if (( ${#dir} == 0 ))
        then
            dir="$server/$orgrepo"
        fi

        branch="${branch#\#}"  # Removes prefix #, if any
        local branch_json
        if (( ${#branch} == 0 ))
        then
            branch_json=null
        else
            branch_json="\"$branch\""
        fi

        local comma=,
        if (( i == nbranches - 1 )); then
            comma=
        fi

        echo "    { \"server\": \"$server\", \"dir\": \"$dir\", \"repo\": \"$orgrepo\", \"branch\": $branch_json }$comma" >> "$tmpout"

        i+=1
    done < "$manifest"

    echo "  ]" >> "$tmpout"

    echo "}" >> "$tmpout"

    mv "$tmpout" "$out"
}
