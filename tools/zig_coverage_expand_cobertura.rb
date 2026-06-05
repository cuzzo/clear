#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "zig_coverage_support"

path = ARGV.fetch(0) do
  warn "usage: ruby tools/zig_coverage_expand_cobertura.rb PATH"
  exit 2
end

ZigCoverageSupport.expand_cobertura!(File.expand_path(path, Dir.pwd))
