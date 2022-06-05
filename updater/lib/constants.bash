declare -r CONSTANTS_BASH= 2>/dev/null || return 0

declare -r DNS_RE0='[a-z][a-z0-9-]+\.[a-z][a-z0-9.-]+' # at least 2 components

declare -r SECTION_VALUE_RE0='[a-zA-Z0-9_./-]+'

declare -r ORG_RE1='[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?'
declare -r REPO_RE0='[a-zA-Z0-9_.-]+'
declare -r ORGREPO_RE1="$ORG_RE1/$REPO_RE0"
declare -r ORGREPO_RE3="($ORG_RE1)/($REPO_RE0)"

declare -r GIT_REF_RE1='#([a-zA-Z0-9_./-]*)'

declare -r DIR_RE1='[a-zA-Z0-9.:_#-]+(/[a-zA-Z0-9.:_#-]+)*'
