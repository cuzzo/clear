#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "json"

source_root, output = ARGV
abort "usage: semantic_environment.rb SOURCE_ROOT OUTPUT.json" unless source_root && output

marker = JSON.parse(File.read(File.join(File.expand_path(source_root), ".fact-mine-source.json")))
binary = marker.fetch("binary")
actual = Digest::SHA256.file(binary).hexdigest
expected = marker.fetch("binary_sha256")
abort "Kotlin stdlib binary digest mismatch: expected #{expected}, got #{actual}" unless actual == expected

File.write(output, JSON.pretty_generate({
  "schema" => "fact-mine.semantic-environment.v1",
  "claims" => {
    "kotlin.platform" => "jvm",
    "kotlin.stdlib.version" => marker.fetch("version"),
    "kotlin.stdlib.binary.sha256" => "sha256:#{actual}"
  }
}))
