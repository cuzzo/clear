# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name = "nil-kill"
  spec.version = "0.1.0"
  spec.summary = "Runtime and static evidence tooling for tightening Sorbet nilability."
  spec.authors = ["Clear contributors"]
  spec.license = "PolyForm-Noncommercial-1.0.0"
  spec.required_ruby_version = ">= 3.2"

  spec.files = Dir.glob("{exe,lib}/**/*", base: __dir__).select { |path| File.file?(File.join(__dir__, path)) }
  spec.bindir = "exe"
  spec.executables = ["nil-kill"]
  spec.require_paths = ["lib"]

  spec.add_dependency "prism", ">= 1.6"
  spec.add_dependency "parlour"
  spec.add_dependency "rbs-trace"
  spec.add_dependency "sorbet-runtime"

  spec.add_development_dependency "parallel_rspec"
  spec.add_development_dependency "rspec"
  spec.add_development_dependency "ruby-prof"
  spec.add_development_dependency "simplecov"
  spec.add_development_dependency "simplecov-cobertura"
  spec.add_development_dependency "stackprof"
  spec.add_development_dependency "vernier"
end
