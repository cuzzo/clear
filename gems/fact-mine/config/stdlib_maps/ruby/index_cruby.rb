#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "json"
require "open3"

INDEXER_VERSION = "0.4.0"
INDEXER_SHA256 = "06fd18c576f979a726c651594644ec4a35db4f471f2160b3f72eb89fa6001784"
CORE_SOURCES = %w[
  array.c bignum.c class.c compar.c dir.c enum.c error.c file.c hash.c io.c
  math.c numeric.c object.c proc.c random.c range.c re.c string.c struct.c
  time.c variable.c vm_method.c
].freeze

source_root, output = ARGV
abort "usage: index_cruby.rb CRUBY_SOURCE_ROOT OUTPUT.scip" unless source_root && output
source_root = File.expand_path(source_root)
output = File.expand_path(output)

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

compiler = executable("CLANG", "clang-20")
indexer = executable("SCIP_CLANG", "scip-clang")
version = capture!(indexer, "--version", chdir: source_root)
abort "scip-clang #{INDEXER_VERSION} is required" unless version.lines.first&.strip == "scip-clang #{INDEXER_VERSION}"
abort "unexpected scip-clang binary" unless Digest::SHA256.file(indexer).hexdigest == INDEXER_SHA256

files = CORE_SOURCES.map { |name| File.join(source_root, name) }
missing = files.reject { |path| File.file?(path) }
abort "CRuby core sources were not found: #{missing.join(', ')}" unless missing.empty?
database = files.map do |file|
  {
    "directory" => source_root,
    "file" => file,
    "arguments" => [compiler, "-I", source_root, "-DRUBY_EXPORT", "-c", file]
  }
end
database_path = File.join(File.dirname(output), "compile_commands.json")
File.write(database_path, JSON.pretty_generate(database))
capture!(
  indexer,
  "--compdb-path", database_path,
  "--index-output-path", output,
  "--no-progress-report",
  "-j", "1",
  chdir: source_root
)
abort "scip-clang did not produce #{output}" unless File.size?(output)
