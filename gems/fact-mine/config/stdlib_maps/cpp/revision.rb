#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"

EXPECTED = "cab188eb89bb4b5cf99c97a16f9d1d3196d1d2ce9536ea70a9f74b782bc7bec2"

root = ARGV.fetch(0) { abort "usage: revision.rb SOURCE_ROOT" }
include_root = File.join(File.expand_path(root), "include")
digest = Digest::SHA256.new
Dir.glob(File.join(include_root, "**/*"), File::FNM_DOTMATCH)
  .select { |path| File.file?(path) }
  .sort
  .each do |path|
    relative = path.delete_prefix("#{include_root}#{File::SEPARATOR}")
    digest << relative << "\0" << Digest::SHA256.file(path).hexdigest << "\n"
  end
actual = digest.hexdigest
abort "unexpected effective libstdc++ digest #{actual}" unless actual == EXPECTED

puts "libstdcxx-13.3.0 effective sha256:#{actual}"
