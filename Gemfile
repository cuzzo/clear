source 'https://rubygems.org'

# Automatically populate DECOMPLEX_TS_*_PATH environment variables if not set
# and the grammars are present under standard node_modules paths.
if defined?(Bundler)
  require "rbconfig"
  packages = {
    "ruby" => "tree-sitter-ruby",
    "python" => "tree-sitter-python",
    "javascript" => "tree-sitter-javascript",
    "typescript" => "tree-sitter-typescript",
    "go" => "tree-sitter-go",
    "rust" => "tree-sitter-rust",
    "zig" => "@tree-sitter-grammars/tree-sitter-zig",
    "lua" => "@tree-sitter-grammars/tree-sitter-lua",
    "c" => "tree-sitter-c",
    "cpp" => "tree-sitter-cpp",
    "csharp" => "tree-sitter-c-sharp",
    "java" => "tree-sitter-java",
    "swift" => "tree-sitter-swift",
    "kotlin" => "tree-sitter-kotlin"
  }

  host_os = case RbConfig::CONFIG["host_os"]
            when /linux/i then "linux"
            when /darwin/i then "darwin"
            when /mswin|mingw|cygwin/i then "win32"
            end
  host_arch = case RbConfig::CONFIG["host_cpu"]
              when /x86_64|amd64/i then "x64"
              when /aarch64|arm64/i then "arm64"
              end

  root_dir = __dir__

  packages.each do |lang, pkg|
    env_name = "DECOMPLEX_TS_#{lang.upcase}_PATH"
    next if ENV[env_name] && File.file?(ENV[env_name])

    # Try prebuild path
    if host_os && host_arch
      dir = File.join(root_dir, "node_modules", pkg, "prebuilds", "#{host_os}-#{host_arch}")
      files = Dir.glob(File.join(dir, "*.node"))
      if files.any?
        ENV[env_name] = files.first
        next
      end
    end

    # Try local build path
    local_dir = File.join(root_dir, "node_modules", pkg, "build", "Release")
    files = Dir.glob(File.join(local_dir, "*.node"))
    if files.any?
      ENV[env_name] = files.first
    end
  end
end

gem 'csv'
gem 'msgpack', '~> 1.7', '>= 1.7.2'
gem 'tree_sitter', '~> 0.1'


group :development do
  gem 'byebug', '~> 12.0'
  gem 'minitest', '~> 5.25'
  gem 'rspec'
  gem 'parallel_rspec'
  gem "parallel_tests", "~> 5.7", require: false
  gem 'tty-cursor', require: false
  gem 'tty-reader', require: false
  gem 'tty-screen', require: false

  # Static analysis / quality
  gem 'rubycritic', require: false
  gem 'reek', require: false
  gem 'flog', require: false
  gem 'debride', require: false
  gem 'simplecov', require: false
  # Cobertura XML output for Codecov / coveralls / GitLab integration
  gem 'simplecov-cobertura', require: false

  # Gradual typing — staged adoption per the self-host prep tracker
  # (TODO.md "Self-host preparation" P1 / tasks #10 + #20). `sorbet`
  # provides the static type checker (`srb tc`); `sorbet-runtime` is
  # the inline `T::Sig` API (no runtime cost when not invoked because
  # files start at `# typed: false`); `tapioca` generates RBI files
  # for our gems so Sorbet sees their public APIs.
  gem 'sorbet', require: false
  gem 'sorbet-runtime'
  gem 'tapioca', require: false

  # Local path while nil-kill is extracted as a standalone gem.
  gem 'fact-mine', path: 'gems/fact-mine', require: false
  gem 'decomplex', path: 'gems/decomplex', require: false
  gem 'espalier', path: 'gems/espalier', require: false
  gem 'nil-kill', path: 'gems/nil-kill', require: false
  gem 'auto-type', path: 'gems/auto-type', require: false
  gem 'boobytrap', path: 'gems/boobytrap', require: false

  # Rubocop with the rubocop-sorbet plugin. We don't run general
  # Rubocop style — only the `Sorbet/EnforceSignatures` cop, which
  # gates that every method definition has a `sig {}` block. This
  # prevents new untyped methods from landing while we incrementally
  # type the existing ~2100 methods.
  gem 'rubocop', require: false
  gem 'rubocop-sorbet', require: false

  # Mutation testing: catches tests that execute code without asserting on
  # the observable behavior. CI passes `--usage opensource`.
  gem 'mutant', require: false
  gem 'mutant-minitest', require: false
  gem 'mutant-rspec', require: false

  gem 'test-miser', path: 'gems/test-miser', require: false

  # Automatically run npm install in development mode during bundle install/update
  if defined?(Bundler) && (ARGV.empty? || ARGV.any? { |a| a =~ /\b(install|update)\b/ })
    without = Bundler.settings[:without] || []
    unless without.include?(:development) || without.include?("development")
      $stderr.puts "Bundler hook: Installing Tree-Sitter grammars..."
      Dir.chdir(__dir__) do
        system("npm install", out: :err)
      end
    end
  end
end



gem "stackprof", "~> 0.2.28"
