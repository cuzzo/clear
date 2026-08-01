#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "open-uri"
require "open3"

VERSION = "2.2.0"
SOURCES_SHA256 = "967ad9599254e3a60d96d6c789547cc35c22d770d9c8fb1e3f15fac3b4c3b65d"
BINARY_SHA256 = "65d12d85a3b865c160db9147851712a64b10dadd68b22eea22a95bf8a8670dca"
BASE_URL = "https://repo.maven.apache.org/maven2/org/jetbrains/kotlin/kotlin-stdlib/#{VERSION}"

workspace = ARGV.fetch(0) do
  abort "usage: materialize_source.rb WORKSPACE_ROOT"
end
cache = File.join(File.expand_path(workspace), ".cache", "stdlib-sources", "kotlin-stdlib-#{VERSION}")
archive_dir = File.join(cache, "artifacts")
source_root = File.join(cache, "source")
marker = File.join(source_root, ".fact-mine-source.json")
FileUtils.mkdir_p(archive_dir)

def download(url, destination, sha256)
  if File.file?(destination) && Digest::SHA256.file(destination).hexdigest == sha256
    return
  end

  temporary = "#{destination}.download-#{Process.pid}"
  URI.open(url) { |input| File.open(temporary, "wb") { |output| IO.copy_stream(input, output) } }
  actual = Digest::SHA256.file(temporary).hexdigest
  abort "digest mismatch for #{url}: expected #{sha256}, got #{actual}" unless actual == sha256

  File.rename(temporary, destination)
ensure
  FileUtils.rm_f(temporary) if defined?(temporary)
end

sources = File.join(archive_dir, "kotlin-stdlib-#{VERSION}-sources.jar")
binary = File.join(archive_dir, "kotlin-stdlib-#{VERSION}.jar")
download("#{BASE_URL}/kotlin-stdlib-#{VERSION}-sources.jar", sources, SOURCES_SHA256)
download("#{BASE_URL}/kotlin-stdlib-#{VERSION}.jar", binary, BINARY_SHA256)

expected_marker = {
  "version" => VERSION,
  "sources_sha256" => SOURCES_SHA256,
  "binary_sha256" => BINARY_SHA256,
  "binary" => binary
}
current_marker = JSON.parse(File.read(marker)) if File.file?(marker)
unless current_marker == expected_marker
  FileUtils.rm_rf(source_root)
  FileUtils.mkdir_p(source_root)
  _stdout, stderr, status = Open3.capture3("unzip", "-q", sources, "-d", source_root)
  abort "failed to extract #{sources}: #{stderr}" unless status.success?
  File.write(marker, JSON.pretty_generate(expected_marker))
end

puts source_root
