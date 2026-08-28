# Shell completions

Generate and install completion scripts for `zsh`, `bash`, and `fish`.

## Overview

The `container --generate-completion-script [zsh|bash|fish]` command generates completion scripts for the provided shell. Below is a detailed guide on how to install the completion scripts.

> [!NOTE]
> See the [swift-argument-parser documentation](https://apple.github.io/swift-argument-parser/documentation/argumentparser/installingcompletionscripts/#Installing-Zsh-Completions) for more information about generating and installing shell completion scripts.

## Installing `zsh` completions

If you have [oh-my-zsh](https://ohmyz.sh/) installed, you already have a directory of automatically loaded completion scripts — `.oh-my-zsh/completions`. Copy your new completion script to that directory. If the `completions` directory does not exist, simply make it.

```zsh
mkdir -p ~/.oh-my-zsh/completions
container --generate-completion-script zsh > ~/.oh-my-zsh/completions/_container
source ~/.oh-my-zsh/completions/_container
```

> [!NOTE]
> Your completion script must have the filename `_container`.

Without oh-my-zsh, you’ll need to add a path for completion scripts to your function path, and turn on completion script autoloading. First, add these lines to your `~/.zshrc` file:

```bash
fpath=(~/.zsh/completion $fpath)
autoload -U compinit
compinit
```

Next, create a directory at `~/.zsh/completion` and copy the completion script to the new directory.

```zsh
mkdir -p ~/.zsh/completion
container --generate-completion-script zsh > ~/.zsh/completion/_container
source ~/.zshrc
```

## Installing `bash` completions

If you have [bash-completion](https://github.com/scop/bash-completion) installed, you can just copy your new completion script to the `bash_completion.d` directory.

> [!NOTE]
> The path to the directory is dependent on how bash-completion was installed. Find the correct path and then copy the completion script there. For example, if you used homebrew to install `bash-completion`:
>  ```bash
>  container --generate-completion-script bash > /opt/homebrew/etc/bash_completion.d/container
>  source /opt/homebrew/etc/bash_completion.d/container
>  ```

Without bash-completion, you’ll need to source the completion script directly. Create and copy it to a directory such as `~/.bash_completions`. 

```bash
mkdir -p ~/.bash_completions
container --generate-completion-script bash >  ~/.bash_completions/container
source ~/.bash_completions/container
```

Furthermore, you can add the following line to `~/.bash_profile` or `~/.bashrc`, in order for every new bash session to have autocompletion ready.

```bash
source ~/.bash_completions/container
```

## Installing `fish` completions

Copy the completion script to any path listed in the environment variable `$fish_completion_path`.

```bash
container --generate-completion-script fish > ~/.config/fish/completions/container.fish
```
