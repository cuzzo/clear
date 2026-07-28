#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"

EXPECTED = {
  "version" => "2.2.0",
  "sources_sha256" => "967ad9599254e3a60d96d6c789547cc35c22d770d9c8fb1e3f15fac3b4c3b65d",
  "binary_sha256" => "65d12d85a3b865c160db9147851712a64b10dadd68b22eea22a95bf8a8670dca"
}.freeze

source_root = File.expand_path(ARGV.fetch(0) { abort "usage: revision.rb SOURCE_ROOT" })
marker = JSON.parse(File.read(File.join(source_root, ".fact-mine-source.json")))
EXPECTED.each do |key, value|
  abort "Kotlin stdlib marker mismatch for #{key}" unless marker[key] == value
end

puts "kotlin-stdlib-2.2.0 sources sha256:#{EXPECTED.fetch('sources_sha256')}"
