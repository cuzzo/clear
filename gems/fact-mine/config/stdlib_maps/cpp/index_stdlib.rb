#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "json"
require "open3"

INDEXER_VERSION = "0.4.0"
INDEXER_SHA256 = "06fd18c576f979a726c651594644ec4a35db4f471f2160b3f72eb89fa6001784"
source_root, output, standard, surface = ARGV
abort "usage: index_stdlib.rb SOURCE_ROOT OUTPUT.scip C++_STANDARD SURFACE" unless source_root && output && standard && surface
abort "unsupported C++ standard #{standard.inspect}" unless %w[c++17 c++20].include?(standard)
abort "invalid surface #{surface.inspect}" unless surface.match?(/\A[a-z][a-z0-9-]*\z/)

def executable(environment, fallback)
  configured = ENV[environment]
  return File.expand_path(configured) if configured && !configured.empty?

  candidate = ENV.fetch("PATH", "").split(File::PATH_SEPARATOR)
    .map { |directory| File.join(directory, fallback) }
    .find { |path| File.file?(path) && File.executable?(path) }
  abort "#{fallback} was not found; set #{environment}" unless candidate

  candidate
end

def capture!(*command, chdir:)
  stdout, stderr, status = Open3.capture3(*command, chdir: chdir)
  abort "#{command.join(' ')} failed:\n#{stderr}" unless status.success?

  stdout
end

source_root = File.expand_path(source_root)
output = File.expand_path(output)
compiler = executable("CLANGXX", "clang++-20")
indexer = executable("SCIP_CLANG", "scip-clang")
version = capture!(indexer, "--version", chdir: source_root)
abort "scip-clang #{INDEXER_VERSION} is required" unless version.lines.first&.strip == "scip-clang #{INDEXER_VERSION}"
abort "unexpected scip-clang binary" unless Digest::SHA256.file(indexer).hexdigest == INDEXER_SHA256

implementation = File.join(source_root, "preprocessed", standard, "#{surface}.cpp")
abort "preprocessed surface was not found at #{implementation}" unless File.file?(implementation)
arguments = [
  compiler,
  "-std=#{standard}",
  "-c",
  implementation
]
File.write(
  File.join(source_root, "compile_commands.json"),
  JSON.pretty_generate([{
    "directory" => source_root,
    "file" => implementation,
    "arguments" => arguments
  }])
)
capture!("git", "init", "--quiet", chdir: source_root)
capture!(
  indexer,
  "--compdb-path",
  "compile_commands.json",
  "--index-output-path",
  output,
  "--no-progress-report",
  "-j",
  "1",
  chdir: source_root
)
abort "scip-clang did not produce #{output}" unless File.size?(output)
