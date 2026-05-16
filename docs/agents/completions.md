# Shell completions

Tab-completion for `clear` subcommands, and file/directory arguments
filtered per subcommand:

| Subcommand | Completes to |
|---|---|
| `clear build`, `run`, `fmt`, `fix`, `profile`, `explain` | `*.cht` files (and directories to navigate) |
| `clear test`, `benchmark` | `*.cht` files or directories |
| `clear doctor` | `*.profile/` directories |
| `clear completions` | `bash` / `zsh` / `fish` |

Generate the script for your shell with `clear completions <shell>`,
then install per the instructions below.

## Bash

Add to `~/.bashrc`:

```sh
source <(clear completions bash)
```

Or write to the system completions dir (loaded by every interactive
shell, no rc-file edit):

```sh
clear completions bash | sudo tee /etc/bash_completion.d/clear > /dev/null
```

## Zsh

The convention is one `_<cmd>` file per command in a directory on
`$fpath`:

```sh
mkdir -p ~/.zsh/completions
clear completions zsh > ~/.zsh/completions/_clear
```

Then ensure `~/.zsh/completions` is on `$fpath` **before** `compinit`
runs. In `~/.zshrc`:

```sh
fpath=(~/.zsh/completions $fpath)
autoload -Uz compinit && compinit
```

Reopen the shell (or `compinit -u`) and tab-completion will pick up
descriptions for each subcommand.

## Fish

Fish auto-loads completions from `~/.config/fish/completions/`:

```sh
clear completions fish > ~/.config/fish/completions/clear.fish
```

No rc-file edit needed.

## Verifying

```sh
clear <TAB>                       # lists subcommands
clear doctor <TAB>                # lists *.profile/ dirs
clear profile examples/<TAB>      # lists *.cht files in examples/
```

## Updating

The completion script is generated from the live `Completions`
module (`src/tools/completions.rb`). When new subcommands are added,
re-run `clear completions <shell> > <file>` to refresh.
