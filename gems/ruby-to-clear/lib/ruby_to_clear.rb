# frozen_string_literal: true

require_relative "ruby_to_clear/version"
require_relative "ruby_to_clear/transpiler"

module RubyToClear
  class Error < StandardError; end

  def self.transpile(source_code)
    result = Prism.parse(source_code)
    raise Error, "Failed to parse Ruby source: #{result.errors.map(&:message).join(', ')}" if result.failure?

    Transpiler.new(source_code).transpile(result.value)
  end

  def self.transpile_file(path)
    result = Prism.parse_file(path)
    raise Error, "Failed to parse Ruby file #{path}: #{result.errors.map(&:message).join(', ')}" if result.failure?

    Transpiler.new(File.read(path)).transpile(result.value)
  end
end
