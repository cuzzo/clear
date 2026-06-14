# Shell-completion script generators for the `clear` CLI.
#
# Usage from the user side:
#   clear completions bash >> ~/.bashrc
#   clear completions zsh  > ~/.zsh/completions/_clear   # then `compinit`
#   clear completions fish > ~/.config/fish/completions/clear.fish
#
# Per-subcommand completion semantics:
#   build / run / fmt / fix / profile / explain  -> *.cht files (+ dirs)
#   test                                          -> *.cht files OR directories
#   doctor                                        -> *.profile/ directories
#   completions                                   -> bash | zsh | fish
module Completions
  SUBCOMMANDS = {
    'build'       => 'Build a .cht file to a native binary',
    'run'         => 'Build and run a .cht file',
    'test'        => 'Run tests in a .cht file or directory',
    'benchmark'   => 'Run a CLEAR benchmark',
    'profile'     => 'Build with profiling and run',
    'doctor'      => 'Analyze a .profile/ directory',
    'fix'         => 'Apply lint fixes to .cht files',
    'fmt'         => 'Format .cht files',
    'format'      => 'Alias for fmt',
    'explain'     => 'Explain a language feature',
    'completions' => 'Print shell completions',
    'help'        => 'Show help',
  }.freeze


  def self.script_for(shell)
    case shell
    when 'bash' then bash
    when 'zsh'  then zsh
    when 'fish' then fish
    else
      raise ArgumentError, "unsupported shell: #{shell.inspect} (expected bash, zsh, or fish)"
    end
  end

  # Bash uses `complete -F` with a function. We hand-roll the
  # subcommand dispatch so file completion is filtered to `.cht`
  # for build-like commands and to `.profile/` for `doctor`.
  def self.bash
    <<~BASH
      # bash completion for `clear`
      # Source from ~/.bashrc:  source <(clear completions bash)
      _clear_complete() {
        local cur prev cmd
        COMPREPLY=()
        cur="${COMP_WORDS[COMP_CWORD]}"
        prev="${COMP_WORDS[COMP_CWORD-1]}"
        cmd="${COMP_WORDS[1]}"

        if [ "$COMP_CWORD" -eq 1 ]; then
          COMPREPLY=( $(compgen -W "#{SUBCOMMANDS.keys.join(' ')}" -- "$cur") )
          return
        fi

        case "$cmd" in
          build|run|fmt|format|fix|profile|explain)
            COMPREPLY=( $(compgen -f -X '!*.cht' -- "$cur") $(compgen -d -- "$cur") )
            compopt -o filenames 2>/dev/null
            ;;
          test|benchmark)
            COMPREPLY=( $(compgen -f -X '!*.cht' -- "$cur") $(compgen -d -- "$cur") )
            compopt -o filenames 2>/dev/null
            ;;
          doctor)
            # Prefer *.profile/ directories. Falls back to all dirs so
            # the user can drill into a parent.
            COMPREPLY=( $(compgen -d -- "$cur") )
            local filtered=()
            local d
            for d in "${COMPREPLY[@]}"; do
              [[ "$d" == *.profile || -d "$d/.." ]] && filtered+=("$d")
            done
            COMPREPLY=("${filtered[@]}")
            compopt -o filenames 2>/dev/null
            ;;
          completions)
            COMPREPLY=( $(compgen -W "bash zsh fish" -- "$cur") )
            ;;
        esac
      }
      complete -F _clear_complete clear
    BASH
  end

  # Zsh's completion system is richer: `_describe` shows subcommand
  # descriptions inline, `_files -g GLOB` filters by glob.
  def self.zsh
    desc_lines = SUBCOMMANDS.map { |k, v| "    '#{k}:#{v}'" }.join("\n")
    <<~ZSH
      #compdef clear
      # zsh completion for `clear`
      # Install:  clear completions zsh > ~/.zsh/completions/_clear
      #           # ensure ~/.zsh/completions is in $fpath BEFORE compinit
      _clear() {
        local -a subcmds
        subcmds=(
      #{desc_lines}
        )

        if (( CURRENT == 2 )); then
          _describe 'subcommand' subcmds
          return
        fi

        case "${words[2]}" in
          build|run|fmt|format|fix|profile|explain|test|benchmark)
            _files -g '*.cht'
            ;;
          doctor)
            _files -/ -g '*.profile'
            ;;
          completions)
            _values 'shell' bash zsh fish
            ;;
        esac
      }
      _clear "$@"
    ZSH
  end

  # Fish completions are declarative: one `complete` call per arm.
  def self.fish
    sub_complete = SUBCOMMANDS.map do |k, v|
      desc = v.gsub("'", "\\\\'")
      "complete -c clear -n '__fish_use_subcommand' -a #{k} -d '#{desc}'"
    end.join("\n")

    <<~FISH
      # fish completion for `clear`
      # Install:  clear completions fish > ~/.config/fish/completions/clear.fish

      # Top-level subcommand list
      #{sub_complete}

      # File arguments per subcommand
      complete -c clear -n '__fish_seen_subcommand_from build run fmt format fix profile explain test benchmark' \\
        -F -k -a "(__fish_complete_path '*.cht')"

      # `doctor` wants *.profile/ directories
      complete -c clear -n '__fish_seen_subcommand_from doctor' \\
        -F -k -a "(__fish_complete_directories '' '*.profile')"

      # `completions` shell name
      complete -c clear -n '__fish_seen_subcommand_from completions' \\
        -a 'bash zsh fish'
    FISH
  end
  private_class_method :bash
  private_class_method :fish
  private_class_method :zsh

end
