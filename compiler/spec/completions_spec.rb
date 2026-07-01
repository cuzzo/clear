require 'rspec'
require_relative '../ruby/tools/completions' unless defined?(Completions)

RSpec.describe Completions do
  describe '.script_for' do
    it 'rejects unsupported shells' do
      expect { described_class.script_for('powershell') }
        .to raise_error(ArgumentError, /unsupported shell/)
    end

    it 'returns the bash script for "bash"' do
      out = described_class.script_for('bash')
      expect(out).to start_with('# bash completion for `clear`')
      expect(out).to include('complete -F _clear_complete clear')
    end

    it 'returns the zsh script for "zsh"' do
      out = described_class.script_for('zsh')
      expect(out).to start_with('#compdef clear')
      expect(out).to include('_files -g \'*.cht\'')
    end

    it 'returns the fish script for "fish"' do
      out = described_class.script_for('fish')
      expect(out).to start_with('# fish completion for `clear`')
      expect(out).to include('__fish_use_subcommand')
    end
  end

  describe 'bash script semantics' do
    let(:script) { described_class.send(:bash) }

    it 'enumerates every subcommand for first-position completion' do
      Completions::SUBCOMMANDS.each_key do |sub|
        expect(script).to include(sub),
                          "bash completion missing subcommand #{sub.inspect}"
      end
    end

    it 'filters file completion to *.cht for build-like subcommands' do
      expect(script).to include("compgen -f -X '!*.cht'")
    end

    it 'completes only directories for `doctor`' do
      expect(script).to match(/doctor\)\s*\n\s+# Prefer \*\.profile\/ directories/)
      expect(script).to include('compgen -d -- "$cur"')
    end

    it 'completes shell names for `completions`' do
      expect(script).to match(/completions\)\s*\n\s+COMPREPLY=\(.*"bash zsh fish"/m)
    end
  end

  describe 'zsh script semantics' do
    let(:script) { described_class.send(:zsh) }

    it 'tags every subcommand with its description for `_describe`' do
      Completions::SUBCOMMANDS.each do |sub, desc|
        expect(script).to include("'#{sub}:#{desc}'"),
                          "zsh completion missing entry for #{sub.inspect}"
      end
    end

    it 'filters `doctor` to *.profile directories via `_files -/`' do
      expect(script).to match(/doctor\)\s*\n\s+_files -\/ -g '\*\.profile'/)
    end

    it 'uses _describe for first-position subcommand completion' do
      expect(script).to include('_describe \'subcommand\' subcmds')
    end
  end

  describe 'fish script semantics' do
    let(:script) { described_class.send(:fish) }

    it 'declares one `complete` per subcommand' do
      Completions::SUBCOMMANDS.each_key do |sub|
        expect(script).to match(/-a #{sub} -d /),
                          "fish completion missing entry for #{sub.inspect}"
      end
    end

    it 'gates file completion on subcommand context' do
      expect(script).to include("__fish_seen_subcommand_from build run fmt format fix profile explain test benchmark")
      expect(script).to include("__fish_seen_subcommand_from doctor")
    end

    it 'escapes single quotes in descriptions' do
      # No subcommand description currently contains a quote, but if
      # someone adds one the script must still parse cleanly.
      stub_const('Completions::SUBCOMMANDS', { 'foo' => "it's a thing" })
      script = described_class.send(:fish)
      expect(script).to include("-d 'it\\'s a thing'")
    end
  end

  describe 'CLI integration' do
    let(:clear_bin) { File.expand_path('../../clear', __dir__) }

    it '`clear completions bash` prints the bash script and exits 0' do
      out = `#{clear_bin} completions bash`
      expect($?.exitstatus).to eq(0)
      expect(out).to start_with('# bash completion for `clear`')
    end

    it '`clear completions` with no shell prints usage to stderr and exits 1' do
      out = `#{clear_bin} completions 2>&1`
      expect($?.exitstatus).to eq(1)
      expect(out).to include('Usage: clear completions')
    end

    it '`clear completions powershell` prints usage and exits 1' do
      out = `#{clear_bin} completions powershell 2>&1`
      expect($?.exitstatus).to eq(1)
      expect(out).to include('Usage: clear completions')
    end
  end
end
