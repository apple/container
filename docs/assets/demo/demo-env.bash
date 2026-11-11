# Shell setup for the README demo, sourced off-camera by landing-movie.tape.
#
# The demo shows an anonymous user (jappleseed) instead of whoever records it.
# The Mac prompt shows user@host and the current directory, like zsh,
# `container machine create` gets `--user jappleseed`, and the new machine's
# prompt shows only the current directory's name, which keeps the real macOS
# home directory path out of view. Every other command passes straight through
# to the real `container` CLI.

PS1='jappleseed@mac \w % '
NOTE_PROMPT_LEN=25  # length of "jappleseed@mac ~/hello % "

# Prints a caption. The tape types `note '...'` while recording is hidden, so
# this erases that command line (however many rows it wrapped onto) and leaves
# only the caption on screen. A caption starts with a blank line unless the
# first argument is `+`, which continues the previous caption. With `-k`, the
# prompt itself is kept, so the first prompt in a new shell stays visible.
note() {
    local gap='\n' column=1 typed="note '$*'"
    if [ "$1" = + ]; then
        gap=''
        shift
        typed="note + '$*'"
    elif [ "$1" = -k ]; then
        gap='\n\n'
        column=$((NOTE_PROMPT_LEN + 1))
        shift
        typed="note -k '$*'"
    fi
    local cols=${COLUMNS:-$(tput cols)}
    local rows=$(( (NOTE_PROMPT_LEN + ${#typed} + cols - 1) / cols ))
    printf "\033[${rows}A\033[${column}G\033[J${gap}\033[97m# %s\033[0m\n" "$*"
}

container() {
    if [ "$1" != machine ] || [ "$2" != create ]; then
        command container "$@"
        return
    fi

    shift 2
    local name="" prev=""
    for arg in "$@"; do
        if [ "$prev" = --name ] || [ "$prev" = -n ]; then
            name=$arg
        fi
        prev=$arg
    done

    command container machine create --user jappleseed "$@" || return
    {
        echo "PS1='\[\033[92m\]\u@\h\[\033[00m\]:\[\033[96m\]\W\[\033[00m\]\$ '"
        echo "NOTE_PROMPT_LEN=25"  # length of "jappleseed@ubuntu:hello$ "
        declare -f note
    } | command container machine run -i -n "$name" -- sh -c 'cat >> ~/.bashrc'
}
