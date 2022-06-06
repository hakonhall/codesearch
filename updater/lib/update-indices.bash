declare -r UPDATE_INDICES_BASH= 2> /dev/null || return 0

set -e

source config.bash || exit 2
source util.bash || exit 2

UpdateIndices() {
    local configfile="$1"

    ReadConfig "$configfile"

    config::resolve::code
    local codeDir="$OUT3"

    config::resolve::filelist
    local filelist="$OUT3"

    config::resolve::filelists
    local filelists="$OUT3"

    config::resolve::fileindex
    local fileindexFile="$OUT3"

    config::resolve::gopath
    local cindexPath="$OUT3"/bin/cindex

    test -e "$cindexPath" ||
        Fail "cindex not found from configured gopath: '$cindexPath'"

    _UpdateFileIndex "$codeDir" "$filelist" "$filelists" "$fileindexFile" \
                     "$cindexPath"

    config::resolve::index
    local indexFile="$OUT3"

    _UpdateIndex "$indexFile" "$cindexPath" "$codeDir"
}

function _UpdateFileIndex {
    local git_dir="$1"
    local filelist="$2"
    local filelists_dir="$3"
    local fileindex="$4"
    local cindex="$5"

    Log "updating file index"

    find "$git_dir" -name .git -prune -o -type f -fprintf "$filelist".new '%P\n'

    if test -e "$filelist" && diff -q "$filelist"{,.new}
    then
        # No changes to the filelist, and hence to the file list directory
        rm "$filelist".new
        return 0
    fi

    _FillFilelists "$filelist".new "$filelists_dir".new

    # Since cindex uses absolute paths, we need to move to $filelists_dir before
    # indexing. So start doing everything as quickly as possible.  Should
    # probably do A-B switching.

    if test -e "$filelists_dir".old; then
        rm -rf "$filelists_dir".old
    fi
    if test -e "$filelists_dir"; then
        mv "$filelists_dir" "$filelists_dir".old
    fi
    mv "$filelists_dir".new "$filelists_dir"

    "$cindex" -index "$fileindex".new "$filelists_dir" &> /dev/null

    mv "$fileindex".new "$fileindex"
    mv "$filelist".new "$filelist"
}

function _FillFilelists {
    local filelist="$1"
    local filelists="$2"

    rm -rf "$filelists"
    mkdir -p "$filelists"

    local -i maxDirs=256 maxLines=128
    local -i dirIndex=0 fileIndex=0 lineIndex=0 nlines=0
    local dir="$filelists"/0
    local path="$dir"/0
    mkdir -p "$dir"

    while read -r
    do
        if (( lineIndex >= maxLines ))
        then
            lineIndex=0

            if (( fileIndex <= dirIndex ))
            then
                if (( fileIndex == 0 ))
                then
                    fileIndex=$(( dirIndex + 1 ))
                    dirIndex=0
                else
                    fileIndex+=-1
                fi
            else
                dirIndex+=1
            fi

            printf -v dir "%s/%x" "$filelists" "$dirIndex"
            printf -v path "%s/%x" "$dir" "$fileIndex"
            mkdir -p "$dir"
        fi

        echo "$REPLY" >> "$path"
        lineIndex+=1
        nlines+=1
    done < "$filelist"
}

function _UpdateIndex {
    local index="$1"
    local cindex="$2"
    local git_dir="$3"

    PrettyPath "$index"
    local shortIndex="$OUT"

    rm -f "$index".new
    Log "updating code search index"
    "$cindex" -index "$index".new "$git_dir"/* &> /dev/null
    mv "$index".new "$index"
}
