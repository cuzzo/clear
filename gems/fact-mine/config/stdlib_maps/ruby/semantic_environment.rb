#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"

source_root, output, runtime_version = ARGV
abort "usage: semantic_environment.rb CRUBY_SOURCE_ROOT OUTPUT.json RUBY_VERSION" unless runtime_version
abort "invalid Ruby runtime version #{runtime_version.inspect}" unless runtime_version.match?(/\A\d+\.\d+\.\d+\z/)
version_header = File.join(File.expand_path(source_root), "version.h")
abort "CRuby version.h was not found" unless File.file?(version_header)
header = File.read(version_header)
api_header = File.join(File.expand_path(source_root), "include", "ruby", "version.h")
abort "CRuby API version header was not found" unless File.file?(api_header)
api_header = File.read(api_header)
major, minor, teeny = runtime_version.split(".")
{
  "RUBY_API_VERSION_MAJOR" => major,
  "RUBY_API_VERSION_MINOR" => minor,
  "RUBY_VERSION_TEENY" => teeny
}.each do |name, value|
  source = name.start_with?("RUBY_API") ? api_header : header
  actual = source[/^#\s*define\s+#{name}\s+(\d+)/, 1]
  abort "CRuby version header #{name}=#{actual.inspect} does not match #{runtime_version}" unless actual == value
end

File.write(output, JSON.pretty_generate({
  "schema" => "fact-mine.semantic-environment.v1",
  "claims" => {
    "runtime.language" => "ruby",
    "runtime.engine" => "ruby",
    "runtime.version" => runtime_version,
    "runtime.engine_version" => runtime_version
  }
}))
