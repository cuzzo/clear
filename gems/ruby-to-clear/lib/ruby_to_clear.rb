# frozen_string_literal: true

require "json"

require_relative "ruby_to_clear/version"
require_relative "ruby_to_clear/helper_config"
require_relative "ruby_to_clear/transpiler"

module RubyToClear
  class Error < StandardError; end

  def self.transpile(source_code, raise_on_error: true, helper_config: nil)
    result = Prism.parse(source_code)
    raise Error, "Failed to parse Ruby source: #{result.errors.map(&:message).join(', ')}" if result.failure?

    Transpiler.new(source_code, raise_on_error: raise_on_error, helper_config: helper_config).transpile(result.value)
  end

  def self.transpile_file(path, raise_on_error: true, helper_config: nil, cfg_facts_path: nil,
                          typed_ir_report_path: nil)
    result = Prism.parse_file(path)
    raise Error, "Failed to parse Ruby file #{path}: #{result.errors.map(&:message).join(', ')}" if result.failure?

    transpiler = Transpiler.new(
      File.read(path), raise_on_error: raise_on_error, source_path: path,
      helper_config: helper_config, cfg_facts_path: cfg_facts_path
    )
    output = transpiler.transpile(result.value)
    if typed_ir_report_path
      File.write(typed_ir_report_path, JSON.pretty_generate(transpiler.typed_ir.analysis_report) + "\n")
    end
    output
  end
end
