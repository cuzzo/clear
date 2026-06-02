source 'https://rubygems.org'

gem 'msgpack', '~> 1.7', '>= 1.7.2'

group :development do
  gem 'byebug', '~> 12.0'
  gem 'rspec'
  gem 'parallel_rspec'
  gem 'tty-cursor', require: false
  gem 'tty-reader', require: false
  gem 'tty-screen', require: false

  # Static analysis / quality
  gem 'rubycritic', require: false
  gem 'reek', require: false
  gem 'flog', require: false
  gem 'flay', require: false
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
  gem 'nil-kill', path: 'gems/nil-kill', require: false

  # Rubocop with the rubocop-sorbet plugin. We don't run general
  # Rubocop style — only the `Sorbet/EnforceSignatures` cop, which
  # gates that every method definition has a `sig {}` block. This
  # prevents new untyped methods from landing while we incrementally
  # type the existing ~2100 methods.
  gem 'rubocop', require: false
  gem 'rubocop-sorbet', require: false
end

gem "stackprof", "~> 0.2.28"
