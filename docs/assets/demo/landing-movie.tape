# README demo for `container`, rendered with VHS (https://github.com/charmbracelet/vhs).
#
# Don't run this tape directly. Regenerate the GIF from the repository root with:
#
#   make demo-gif
#
# which runs scripts/record-demo.sh to pre-warm images, set up a scratch
# project directory, record, and clean up. The recording runs real commands
# on the host, but the user is anonymized to `jappleseed` (see
# docs/assets/demo/demo-env.bash).
#
# The tape records into .build/demo-gif, along with a text transcript of every
# screen. The script checks the transcript for errors before it optimizes the
# GIF and copies it to docs/assets/landing-movie.gif.
#
# Captions are typed off-camera as `note '...'`, which replaces the typed line
# with the caption (`note + '...'` continues the previous caption). The GIF is
# rendered at twice the size of the 830-pixel README column on GitHub, so it's
# sharp on Retina displays, which gives a 112-column terminal: keep each caption
# line and command within that, splitting long commands with `\`. VHS can't
# capture 2x frames much faster than about 16 per second; if the framerate is
# set higher, it drops frames and the GIF plays back too fast.
#
# The screen is cleared off-camera between sections, so each one plays as a
# single screen. Scrolling forces the whole screen to be re-encoded in every
# frame, which made up nearly all of the GIF's size; keep each section within
# the screen's height (about 37 rows). After a clear, the first caption should say
# where we are (the Mac or the Ubuntu machine).

Output .build/demo-gif/landing-movie.gif
Output .build/demo-gif/landing-movie.txt

Require container
Require curl

Set Shell "bash"
Set Theme "Homebrew"
Set FontFamily "SF Mono"
Set FontSize 24
Set LetterSpacing 0
Set Width 1660
Set Height 1120
Set Padding 12
Set TypingSpeed 40ms
Set Framerate 12
Set CursorBlink false

Hide
Type `source "$DEMO_ENV" && cd "$DEMO_DIR" && clear`
Enter
Sleep 500ms
Show

# Introduction

Hide
Type "note 'container: run Linux containers on your Mac, written in Swift and optimized for Apple silicon.'"
Enter
Sleep 200ms
Show
Sleep 3.5s

# Containers

Hide
Type "note 'container runs as a service. The first time you use it, it offers to install a Linux kernel for you.'"
Enter
Sleep 200ms
Show
Sleep 3s

Type "container system start"
Sleep 500ms
Enter
Wait@120s /@mac \S+ %\s*$/
Sleep 2s

Hide
Type "note 'Run any OCI image from any registry. Each container runs in its own lightweight VM,'"
Enter
Sleep 200ms
Type "note + 'so every container has the isolation properties of a full VM.'"
Enter
Sleep 200ms
Show
Sleep 4.5s

Type `container run -d --name web -p 8080:80 python:slim \`
Enter
Type `  sh -c "echo 'Hello, world!' > index.html; python3 -m http.server 80"`
Sleep 500ms
Enter
Wait@60s /@mac \S+ %\s*$/
Sleep 3s

Hide
Type "note 'Each container has its own IP address, CPU, and memory allocation.'"
Enter
Sleep 200ms
Show
Sleep 2.5s

Type "container ls"
Sleep 500ms
Enter
Wait /@mac \S+ %\s*$/
Sleep 3.5s

Hide
Type "note '-p 8080:80 published the web server on localhost, so reach it from your Mac:'"
Enter
Sleep 200ms
Show
Sleep 3s

Type "curl localhost:8080"
Sleep 500ms
Enter
Wait /@mac \S+ %\s*$/
Sleep 3s

Hide
Type "note 'Manage containers with familiar commands: logs, exec, stats, stop, and more.'"
Enter
Sleep 200ms
Show
Sleep 3s

Type "container logs web"
Sleep 500ms
Enter
Wait /@mac \S+ %\s*$/
Sleep 3s

Hide
Type "note 'Because each container is a VM, each one runs its own Linux kernel:'"
Enter
Sleep 200ms
Show
Sleep 2.5s

Type "container exec web uname -sr"
Sleep 500ms
Enter
Wait /@mac \S+ %\s*$/
Sleep 3.5s

Hide
Type "clear"
Enter
Sleep 300ms
Type "note 'Beyond this demo, container can also:'"
Enter
Sleep 200ms
Type "note + '  - build images from a Dockerfile or Containerfile, and run both arm64 and amd64 images'"
Enter
Sleep 200ms
Type "note + '  - give containers DNS names, like web.test, with its built-in DNS service'"
Enter
Sleep 200ms
Type "note + '  - share files with containers through volumes and bind mounts'"
Enter
Sleep 200ms
Type "note + '  - run local Kubernetes clusters for development and testing'"
Enter
Sleep 200ms
Show
Sleep 7s

Hide
Type `note "...but there's more."`
Enter
Sleep 200ms
Show
Sleep 2.5s

# Container machines

Hide
Type "note 'Container machines are different: persistent Linux environments for everyday work.'"
Enter
Sleep 200ms
Type "note + 'By default, they use your Mac username and share your home directory, and run background services.'"
Enter
Sleep 200ms
Show
Sleep 5s

Type "container machine create ubuntu-machine:26.10 --name ubuntu"
Sleep 500ms
Enter
Wait@120s /@mac \S+ %\s*$/
Sleep 2s

Hide
Type `note "Open a shell. By default, you're the same user, in the same directory, as on your Mac."`
Enter
Sleep 200ms
Show
Sleep 3s

Type "container machine run -n ubuntu"
Sleep 500ms
Enter
Wait@60s /\$\s*$/
Sleep 2s

Hide
Type "note -k 'Your Mac files are right here: edit on the Mac, build in Linux.'"
Enter
Sleep 200ms
Show
Sleep 3s

Type "ls"
Sleep 300ms
Enter
Wait /\$\s*$/
Sleep 3s

Hide
Type "note 'It starts up like any Linux system, with systemd running its background services:'"
Enter
Sleep 200ms
Show
Sleep 3.5s

Type "ps -e -o pid,comm"
Sleep 300ms
Enter
Wait /\$\s*$/
Sleep 6s

Hide
Type "clear"
Enter
Sleep 300ms
Type "note 'Still in Ubuntu: you have sudo access, so install software with apt:'"
Enter
Sleep 200ms
Show
Sleep 3s

Type "sudo apt install -y fastfetch"
Sleep 500ms
Enter
Wait@120s /\$\s*$/
Sleep 4s

Hide
Type "clear"
Enter
Sleep 300ms
Type "note 'Run the newly installed fastfetch, still inside the Ubuntu machine:'"
Enter
Sleep 200ms
Show
Sleep 2.5s

Type "fastfetch"
Sleep 300ms
Enter
Wait /\$\s*$/
Sleep 5s

Hide
Type "clear"
Enter
Sleep 300ms
Type "note 'Files you create in Ubuntu show up on your Mac:'"
Enter
Sleep 200ms
Show
Sleep 2.5s

Type "uname -a > hello-from-linux.txt"
Sleep 300ms
Enter
Wait /\$\s*$/
Sleep 1s

Type "exit"
Sleep 300ms
Enter
Wait /@mac \S+ %\s*$/
Sleep 1s

Type "cat hello-from-linux.txt"
Sleep 500ms
Enter
Wait /@mac \S+ %\s*$/
Sleep 3s

Hide
Type "note 'The machine keeps running in the background:'"
Enter
Sleep 200ms
Show
Sleep 2.5s

Type "container machine ls"
Sleep 500ms
Enter
Wait /@mac \S+ %\s*$/
Sleep 3s

Hide
Type "note 'Reconnect at any time, and everything you installed is still there:'"
Enter
Sleep 200ms
Show
Sleep 3s

Type "container machine run -n ubuntu"
Sleep 500ms
Enter
Wait@60s /\$\s*$/
Sleep 1s

Type "fastfetch --version"
Sleep 300ms
Enter
Wait /\$\s*$/
Sleep 3s

Type "exit"
Sleep 300ms
Enter
Wait /@mac \S+ %\s*$/
Sleep 1s

# Wrap-up

Hide
Type "note 'Get started at github.com/apple/container'"
Enter
Sleep 200ms
Show
Sleep 5s
