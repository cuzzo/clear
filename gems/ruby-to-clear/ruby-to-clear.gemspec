# frozen_string_literal: true

require_relative "lib/ruby_to_clear/version"

Gem::Specification.new do |spec|
  spec.name = "ruby-to-clear"
  spec.version = RubyToClear::VERSION
  spec.summary = "Transpiler from Ruby code to Clear language code using Prism."
  spec.authors = ["Clear contributors"]
  spec.license = "PolyForm-Noncommercial-1.0.0"
  spec.required_ruby_version = ">= 3.2"

  spec.files = Dir.glob("{exe,lib}/**/*", base: __dir__).select { |path| File.file?(File.join(__dir__, path)) }
  spec.bindir = "exe"
  spec.executables = ["ruby-to-clear"]
  spec.require_paths = ["lib"]

  spec.add_dependency "prism", ">= 0.19.0"

  spec.add_development_dependency "rspec"
  spec.add_development_dependency "simplecov"
end
