declare -r CONFIG_BASH= 2>/dev/null || return 0

set -e

source constants.bash || exit 2
source manifest.bash || exit 2
source util.bash || exit 2

HelpConfig() {
    cat <<EOF
The config file has the following format:

  config-file: global-section section*
  global-section: assign*
  section: '[' name S value ']' assign*
  assign: key '=' value

Global settings:
  'code': Directory to contain source to check out and index.* [workdir/code]
  'fileindex': Path to file index file.* [workdir/csearch.fileindex]
  'gopath': The GOPATH where hakonhall/codesearch was installed.**
  'index': Path to codesearch index file.* [workdir/csearch.index]
  'log': Path to cserver log file.* [workdir/cserver.log]
  'port':  Port cserver should listen to. [80]
  'timefile': Path to index timestamp file.* [workdir/csearch.time]
  'webdir': Path to hakonhall/codesearch/cmd/cserver/static.* **
  'workdir': The working directory owned and managed by this program.* **
The 'manifest' section specifies the path of a manifest to include:
  'command': The first token in command is a path to program.*  The remaining
             tokens are passed as arguments.  The program should create the
             manifest file.
The 'server' section names a GitHub server and allows these settings:
  'api': URL to GitHub REST API.**
  'exclude': Excludes all ORG/REPO matching the regex. At most 1.
  'include': Includes repo at ORG/REPO (or USER/REPO), optionally at a specific
             commit or branch #REF and place it at a specific directory DIR.
             See MANIFEST section below.
  'include-org' Include all repos from organization ORG.
  'include-user' Include all repos from user USER.
  'token': An OAuth2 token, e.g. a personal access token.
  'url': Base URL for cloning: git@github.com, https://github.com. Required.
*) The path is relative to the config file, if relative.
**) Required for some operations.

Example:
  workdir = db
  [server github]
  api = https://api.github.com
  url = git@github.com
  # Include all repos from the openjdk organization
  include = openjdk
  # Include branch and place it at a specific dirctory:
  include = hakonhall/codesearch #foo-branch special/sub/dir
  exclude = ^openjdk/jdk$
  [manifest db/apps.manifest]
  command = bin/gen-manifest ../db/apps.manifest

MANIFEST

A manifest file is a set of lines of the following form:
  SERVER ORG/REPO [#[REF] [DIR]]

ORG may be a user USER.  The repository ORG/REPO located at SERVER will be
cloned to DIR, SERVER/ORG/REPO by default, and checked out at REF if present.
Manifest files are put in the manifest directory.  The manifest will be split up
into smaller ones for performance.

There is also a JSON manifest intended for the HTTP server:

{
  "servers": [
    { "name": "github", "url": "https://github.com" },
    { "name": "foo", "url": "bar" },
    ...
  ],
  "manifest": [
    [ "server": "github", "dir": "github/hakonhall/codesearch", "repo": "hakonhall/codesearch", "branch": null },
    [ "server": "foo", "dir": "some/dir", "repo": "org2/repo2", "branch": "1a2e..." },
    ...
  ]
}
EOF

    exit 0
}

VerifyConfig() { $_CONFIG_READ || Fail "The config has not been read"; }


declare _CONFIG_READ=false
declare _CONFIG_FILE=
declare -A _CONFIG_VARS=()
declare -A _CONFIG_PATH_DIRS=()
declare -A _CONFIG_PATH_SHORTS=()
declare -A _CONFIG_VARS_RESOLVED=()
declare -a _CONFIG_MANIFESTS=()
declare -A _CONFIG_MANIFEST_COMMANDS=()
# Public variables set and managed by ReadConfig().
declare -A GITHUB_API_URLS=()
declare -A GITHUB_EXCLUDES=()
declare -A GITHUB_INCLUDES=()
declare -A GITHUB_INCLUDE_ORGS=()
declare -A GITHUB_INCLUDE_USERS=()
declare -a GITHUB_SERVERS=()
declare -A GITHUB_SERVERSH=()
declare -A GITHUB_TOKENS=()
declare -A GITHUB_URLS=()
declare -A GITHUB_WEBURLS=()

ReadConfig() {
    if $_CONFIG_READ; then
        OUT="$_CONFIG_FILE"
        return 0
    fi

    _CONFIG_READ=true
    _CONFIG_VARS=()
    _CONFIG_VARS_RESOLVED=()
    _CONFIG_PATH_DIRS=()
    _CONFIG_PATHS_SHORTS=()
    _CONFIG_VARS=()
    _CONFIG_MANIFESTS=()
    _CONFIG_MANIFEST_COMMANDS=()
    GITHUB_API_URLS=()
    GITHUB_EXCLUDES=()
    GITHUB_INCLUDES=()
    GITHUB_INCLUDE_ORGS=()
    GITHUB_INCLUDE_USERS=()
    GITHUB_SERVERS=()
    GITHUB_SERVERSH=()
    GITHUB_TOKENS=()
    GITHUB_URLS=()
    GITHUB_WEBURLS=()

    local configfile
    configfile=$(realpath "$1") || Fail "No such config file: '$configfile'"
    test -f "$configfile" || Fail "No such config file: '$configfile'"
    _CONFIG_FILE="$configfile"

    PrettyPath "$configfile"
    local nice_configfile="$OUT"

    local configdir
    configdir="${configfile%/*}"
    (( ${#configdir} > 0 )) || configdir=/

    local -a lines=()
    mapfile -t lines < "$configfile"
    local -i nlines="${#lines[@]}"

    local LC_ALL=C  # Use ASCII ranges in regex matching
    local -r s=' *' # Any number of spaces regexp
    local -r S=' +' # At least one space regexp
    local -r id='[a-zA-Z0-9_.-]+' # identifier, GH org
    local -r sid="$SECTION_VALUE_RE0"
    local api= manifest= server= url=
    local key value # Stores the result of the parsing of the line
    local loc
    local -i i=0
    while true
    do
        # Parse line
        local -i lineno=$((i + 1))
        loc="$nice_configfile: line $lineno"
        local line
        if (( i >= nlines )); then
            key='[eof]' # This key cannot be made by anything other than an EOF
        else
            line="${lines[$i]}"
            if [[ "$line" =~ ^$s($|'#') ]]; then
                key='[ignored]'
            elif [[ "$line" =~ ^'['$s(server|manifest)$S($sid)$s']'$s($|' #') ]]
            then
                key="[${BASH_REMATCH[1]}]" # put in []
                value="${BASH_REMATCH[2]}"
            elif [[ "$line" =~ ^$s($id)$s'='$s([^' '](.*[^' '])?)$s$ ]]
            then
                key="${BASH_REMATCH[1]}"
                value="${BASH_REMATCH[2]}"
            else
                Fail "$loc: Invalid line: $line"
            fi
        fi

        # Close any previously open sections
        case "$key" in
            '[eof]'|'[manifest]'|'[server]')
                if test "$server" != ""
                then
                    (( ${#GITHUB_API_URLS[$server]} > 0 )) ||
                        Fail "$loc: Missing 'api' for server '$server'"
                    (( ${#GITHUB_URLS[$server]} > 0 )) ||
                        Fail "$loc: Missing 'url' for server '$server'"
                    (( ${#GITHUB_WEBURLS[$server]} > 0 )) ||
                        Fail "$loc: Missing 'weburl' for server '$server'"
                fi
                manifest=
                server=
                ;;
        esac

        # Apply line
        case "$key" in
            '[eof]') break ;;
            '[ignored]') : ;;
            '[manifest]')
                _ResolveConfigPath "$configdir" "$value"
                manifest="$OUT2"
                _CONFIG_MANIFESTS+=("$manifest")
                ;;
            '[server]')
                server="$value"
                GITHUB_SERVERS+=("$server")
                GITHUB_SERVERSH["$server"]=1
                ;;
            api)
                test "$server" != "" ||
                    Fail "$loc: $key assignment outside server section"
                # TODO: This is missing '.' and + !?
                [[ "$value" =~ ^'https://'([a-zA-Z0-9_]+@)$DNS_RE0(:[0-9]+)?($|/) ]] ||
                    Fail "$loc: Invalid HTTPS URL: $value"
                GITHUB_API_URLS["$server"]="$value"
                ;;
            'command')
                (( ${#manifest} > 0 )) ||
                    Fail "$loc: $key assignment outside manifest section"
                local -a cmd=($value)
                _ResolveConfigPath "$configdir" "${cmd[0]}"
                local program="$OUT2"
                test -x "$program" || Fail "Invalid program in command: $value"
                cmd[0]="$program"
                _CONFIG_MANIFEST_COMMANDS["$manifest"]="${cmd[*]}"
                ;;
            exclude)
                test "$server" != "" ||
                    Fail "$loc: $key assignment outside server section"
                if test -v "GITHUB_EXCLUDES[$server]"; then
                    Fail "$loc: Found more than one exclude for server " \
                         "'$server'"
                fi
                GITHUB_EXCLUDES["$server"]="$value"
                ;;
            code|fileindex|gopath|index|log|webdir|timefile|workdir)
                _ResolveConfigPath "$configdir" "$value"
                _CONFIG_VARS["$key"]="$OUT"
                ;;
            include)
                test "$server" != "" ||
                    Fail "$loc: $key assignment outside server section"
                manifest::ParseLine "$server $value"
                GITHUB_INCLUDES["$server"]+="$value"$'\n'
                ;;
            include-org)
                test "$server" != "" ||
                    Fail "$loc: $key assignment outside server section"
                [[ "$value" =~ ^$ORG_RE1$ ]] ||
                    Fail "$loc: Invalid organization name: '$value'"
                GITHUB_INCLUDE_ORGS["$server"]+="$value"$'\n'
                ;;
            include-user)
                test "$server" != "" ||
                    Fail "$loc: $key assignment outside server section"
                [[ "$value" =~ ^$ORG_RE1$ ]] ||
                    Fail "$loc: Invalid user name: '$value'"
                GITHUB_INCLUDE_USERS["$server"]+="$value"$'\n'
                ;;
            port)
                [[ "$value" =~ ^[0-9]+$ ]] || Fail "Invalid port: '$value'"
                _CONFIG_VARS["$key"]="$value"
                ;;
            token)
                test "$server" != "" ||
                    Fail "$loc: $key assignment outside server section"
                test "${GITHUB_TOKENS[$server]}" == "" ||
                    Fail "$loc: Duplicate $key assignment"
                # A github personal access token is ^[0-9a-fA-F]{40}$, but
                # unfortunately RFC 6749 says an OAuth2 tokens may be any ASCII
                # isprint(3) character.
                [[ "$value" =~ ^[[:print:]]+$ ]] ||
                    Fail "$loc: Invalid OAuth2 token"
                GITHUB_TOKENS["$server"]="$value"
                ;;
            url)
                test "$server" != "" ||
                    Fail "$loc: $key assignment outside server section"
                # Remove any suffix / (suffix "//" not handled)
                GITHUB_URLS["$server"]="${value%/}"
                ;;
            weburl)
                test "$server" != "" ||
                    Fail "$loc: $key assignment outside server section"
                [[ "$value" =~ ^https?://$DNS_RE0($|/) ]] ||
                    Fail "$loc: Invalid weburl: '$value'"
                # Remove any suffix / (suffix "//" not handled)
                GITHUB_WEBURLS["$server"]="${value%/}"
                ;;
            *) Fail "$loc: Invalid config key: '$key'" ;;
        esac
        i+=1
    done

    OUT="$_CONFIG_FILE"
}

# Verifies the config has been read, sets OUT to the value of the config
# variable $1, and return 0 if this is the first time this function was invoked
# with this name.
_ResolvingOptional() {
    local name="$1"
    VerifyConfig
    OUT="${_CONFIG_VARS[$name]}"
    if test -v "_CONFIG_VARS_RESOLVED[$name]"; then
        return 1
    else
        _CONFIG_VARS_RESOLVED["$name"]=1
        return 0
    fi
}

_Resolving() {
    local name="$1"
    if _ResolvingOptional "$name"; then
        (( ${#OUT} > 0 )) || Fail "'$name' not specified in config file"
        return 0
    else
        return 1
    fi
}

# If $1 has not been specified in the config file, and $2 and $3 are non-empty,
# $2 will be resolved and used as the base path, setting OUT to basepath/$3.
# OUT2 is the (parent) directory.  OUT3 equals OUT, or the relative path to OUT
# if shorter.
_ResolvingPath() {
    local name="$1"
    local fallback_name="$2"
    local fallback_relative_path="$3"

    local -i ret=1

    if _ResolvingOptional "$name"
    then
        local path="$OUT"
        ret=0
        if (( ${#path} == 0 ))
        then
            if (( ${#fallback_name} > 0 && ${#fallback_relative_path} > 0 ))
            then
                config::resolve::"$fallback_name"
                if test "$OUT" == /; then
                    path="/$fallback_relative_path"
                else
                    path="$OUT/$fallback_relative_path"
                fi
                _CONFIG_VARS["$name"]="$path"
            else
                Fail "'$name' not specified in config file"
            fi
        fi

        local dir="${path%/*}"
        (( ${#dir} > 0 )) || dir=/
        _CONFIG_PATH_DIRS["$name"]="$dir"

        local shortPath
        shortPath=$(realpath -m "$path" --relative-to .) || \
            Fail "Failed to find the relative path to '$path'"
        (( ${#shortPath} < ${#path} )) || shortPath="$path"
        _CONFIG_PATH_SHORTS["$name"]="$shortPath"
    fi

    OUT="${_CONFIG_VARS[$name]}"
    OUT2="${_CONFIG_PATH_DIRS[$name]}"
    OUT3="${_CONFIG_PATH_SHORTS[$name]}"
    return $ret
}

# Sets OUT to the canonical absolute path, OUT2 to its parent, and OUT3 to OUT
# or a relative path to OUT, whichever is shorter.
function config::resolve::code {
    if _ResolvingPath code workdir code; then
        test -d "$OUT" || mkdir -p "$OUT"
    fi
}

# Sets OUT to the canonical absolute path, OUT2 to its parent, and OUT3 to OUT
# or a relative path to OUT, whichever is shorter.
function config::resolve::fileindex {
    if _ResolvingPath fileindex workdir csearch.fileindex; then
        test -d "$OUT2" || mkdir -p "$OUT2"
    fi
}

# Sets OUT to the canonical absolute path, OUT2 to its parent, and OUT3 to OUT
# or a relative path to OUT, whichever is shorter.
function config::resolve::gopath {
    if _ResolvingPath gopath; then
        test -d "$OUT" || Fail "Configured gopath not a directory: '$OUT'"
    fi
}

# Sets OUT to the canonical absolute path, OUT2 to its parent, and OUT3 to OUT
# or a relative path to OUT, whichever is shorter.
function config::resolve::index {
    if _ResolvingPath index workdir csearch.index; then
        test -d "$OUT2" || mkdir -p "$OUT2"
    fi
}

# Sets OUT to the canonical absolute path, OUT2 to its parent, and OUT3 to OUT
# or a relative path to OUT, whichever is shorter.
function config::resolve::log {
    if _ResolvingPath timefile workdir cserver.log; then
        test -d "$OUT2" || mkdir -p "$OUT2"
    fi
}

function config::resolve::port {
    if _Resolving port; then
        :
    fi
}

# Sets OUT to the canonical absolute path, OUT2 to its parent, and OUT3 to OUT
# or a relative path to OUT, whichever is shorter.
function config::resolve::filelist {
    # This cannot be specified in config as it is deemed internal
    if _ResolvingPath filelist workdir filelist; then
        test -d "$OUT2" || mkdir -p "$OUT2"
    fi
}

# Sets OUT to the canonical absolute path, OUT2 to its parent, and OUT3 to OUT
# or a relative path to OUT, whichever is shorter.
function config::resolve::filelists {
    # This cannot be specified in config as it is deemed internal
    if _ResolvingPath filelists workdir filelists; then
        test -d "$OUT2" || mkdir -p "$OUT2"
    fi
}

# Sets OUT to the canonical absolute path, OUT2 to its parent, and OUT3 to OUT
# or a relative path to OUT, whichever is shorter.
function config::resolve::repos-json {
    # This cannot be specified in config as it is deemed internal
    if _ResolvingPath repos-json webdir static/repos.json; then
        test -d "$OUT2" || mkdir -p "$OUT2"
    fi
}

# Sets OUT to the canonical absolute path, OUT2 to its parent, and OUT3 to OUT
# or a relative path to OUT, whichever is shorter.
function config::resolve::repos-manifest {
    # This cannot be specified in config as it is deemed internal
    if _ResolvingPath repos-manifest workdir repos.mf; then
        test -d "$OUT2" || mkdir -p "$OUT2"
    fi
}

# Sets OUT to the canonical absolute path, OUT2 to its parent, and OUT3 to OUT
# or a relative path to OUT, whichever is shorter.
function config::resolve::webdir {
    if _ResolvingPath webdir; then
        test -d "$OUT" || mkdir -p "$OUT"
    fi
}

# Sets OUT to the canonical absolute path, OUT2 to its parent, and OUT3 to OUT
# or a relative path to OUT, whichever is shorter.
function config::resolve::timefile {
    if _ResolvingPath timefile workdir csearch.time; then
        test -d "$OUT2" || mkdir -p "$OUT2"
    fi
}

# Sets OUT to the canonical absolute path, OUT2 to its parent, and OUT3 to OUT
# or a relative path to OUT, whichever is shorter.
function config::resolve::workdir {
    if _ResolvingPath workdir; then
        local workdir="$OUT"
        local marker="$workdir"/.updater.marker
        if test -d "$workdir"
        then
            if ! test -e "$marker"
            then
                local dummyPath
                for dummyPath in "$workdir"/*
                do
                    Fail "Refuse to manage work directory '$workdir': " \
                         "Does not appear to have been made by this program: " \
                         "Remove directory or all files in directory"
                done
            fi
        else
            mkdir -p "$workdir" || Fail "Failed to create workdir '$workdir'"
            touch "$marker" || Fail "Failed to create file in workdir '$marker'"
        fi
    fi
}

ResolveGitHubServer() {
    local server="$1"

    test -n "$server" || Fail "Illegal server: '$server'"
    VerifyConfig

    local api
    api="${GITHUB_API_URLS[$server]}"
    test -n "$api" || Fail "No such server: '$server'"

    local token
    token="${GITHUB_TOKENS[$server]}"

    # TODO: return all server-related variables: Remove GITHUB_* from public API

    OUT="$api"
    OUT2="$token"
}

# Returns a set of manifest IDs. Use ResolveManifestSection to resolve each.
ResolveManifestSections() {
    VerifyConfig
    OUTA=("${_CONFIG_MANIFESTS[@]}")
}

ResolveManifestSection() {
    VerifyConfig
    local id="$1"
    OUT="$id" # path
    OUTA=(${_CONFIG_MANIFEST_COMMANDS["$id"]}) # (program arg1 arg2 ...)
}

# $1 is the canonical absolute path of the config directory, which must exist.
# $2 is a user provided resolved as follows:
#  - If it starts with a "~" component, it is replaced by $HOME.
#  - If relative, it is relative $1.
# The resulting path may not exist.  OUT is set to the canonical absolute path.
_ResolveConfigPath() {
    local configdir="$1"
    local path="$2"

    local resolved
    if test "${path:0:1}" == /; then
        resolved="$path"
    elif test "$path" == "~"; then
        resolved="$HOME"
    elif test "${path:0:2}" == "~/"; then
        resolved="$HOME/${path:2}"
    else
        resolved="$configdir/$path"
    fi

    OUT=$(realpath -m "$resolved")
    OUT2=$(realpath -m "$resolved" --relative-to .)
}
