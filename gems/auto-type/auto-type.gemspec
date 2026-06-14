# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name = "auto-type"
  spec.version = "0.1.0"
  spec.summary = "Verified source rewrite engine for Nil-kill evidence and future analyzer plans."
  spec.authors = ["Clear contributors"]
  spec.license = "PolyForm-Noncommercial-1.0.0"
  spec.required_ruby_version = ">= 3.2"

  spec.files = Dir.glob("{exe,lib}/**/*", base: __dir__).select { |path| File.file?(File.join(__dir__, path)) }
  spec.bindir = "exe"
  spec.executables = ["auto-type"]
  spec.require_paths = ["lib"]

  spec.add_dependency "nil-kill", "= 0.1.0"
  spec.add_dependency "sorbet-runtime"

  spec.add_development_dependency "parallel_rspec"
  spec.add_development_dependency "rspec"
  spec.add_development_dependency "simplecov"
  spec.add_development_dependency "simplecov-cobertura"
end
