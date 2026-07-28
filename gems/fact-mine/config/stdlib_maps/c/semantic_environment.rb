#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "json"
require "open3"

source_root, output = ARGV
abort "usage: semantic_environment.rb SOURCE_ROOT OUTPUT.json" unless source_root && output

def capture!(*command, chdir:)
  stdout, stderr, status = Open3.capture3(*command, chdir: chdir)
  abort "#{command.join(' ')} failed:\n#{stderr}" unless status.success?

  stdout.strip
end

def executable(environment, fallback)
  configured = ENV[environment]
  return File.expand_path(configured) if configured && !configured.empty?

  path = ENV.fetch("PATH", "").split(File::PATH_SEPARATOR)
    .map { |directory| File.join(directory, fallback) }
    .find { |candidate| File.file?(candidate) && File.executable?(candidate) }
  abort "#{fallback} was not found; set #{environment}" unless path

  path
end

def files_digest(paths)
  digest = Digest::SHA256.new
  paths.map { |path| File.expand_path(path) }.sort.each do |path|
    abort "C libc compatibility input was not found at #{path}" unless File.file?(path)

    digest << path << "\0" << Digest::SHA256.file(path).hexdigest << "\n"
  end
  digest.hexdigest
end

source_root = File.expand_path(source_root)
database = JSON.parse(File.read(File.join(source_root, "compile_commands.json")))
entries = database.map { |entry| entry.fetch("arguments") }
abort "compile_commands.json has no entries" if entries.empty?

compiler = File.expand_path(entries.first.fetch(0))
abort "compile_commands.json uses multiple C compilers" unless entries.all? do |arguments|
  File.expand_path(arguments.fetch(0)) == compiler
end
semantic_flags = entries.flat_map do |arguments|
  arguments.select do |argument|
    argument.start_with?("-std=", "-D", "-U", "-m", "--target=")
  end
end.uniq.sort

headers = ENV.fetch(
  "C_LIBC_HEADERS",
  [
    "/usr/include/features.h",
    "/usr/include/string.h",
    "/usr/include/stdlib.h",
    "/usr/include/stdio.h",
    "/usr/include/unistd.h"
  ].join(File::PATH_SEPARATOR)
).split(File::PATH_SEPARATOR).reject(&:empty?)
libc = File.expand_path(ENV.fetch("C_LIBC_BINARY", "/lib/x86_64-linux-gnu/libc.so.6"))
indexer = executable("SCIP_CLANG", "scip-clang")
macros = capture!(
  compiler,
  *semantic_flags,
  "-dM",
  "-E",
  "-x",
  "c",
  "/dev/null",
  chdir: source_root
).lines.sort.join

claims = {
  "c.libc.implementation" => ENV.fetch("C_LIBC_IMPLEMENTATION", "glibc"),
  "c.libc.release" => capture!(libc, "--version", chdir: source_root).lines.first.to_s,
  "c.libc.binary.sha256" => "sha256:#{Digest::SHA256.file(libc).hexdigest}",
  "c.libc.headers.sha256" => "sha256:#{files_digest(headers)}",
  "c.compiler.version" => capture!(compiler, "--version", chdir: source_root).lines.first.to_s,
  "c.compiler.target" => capture!(compiler, "-dumpmachine", chdir: source_root),
  "c.compiler.sha256" => "sha256:#{Digest::SHA256.file(compiler).hexdigest}",
  "c.semantic_flags.sha256" =>
    "sha256:#{Digest::SHA256.hexdigest(semantic_flags.join("\0"))}",
  "c.preprocessor_macros.sha256" => "sha256:#{Digest::SHA256.hexdigest(macros)}",
  "c.scip_clang.version" => capture!(indexer, "--version", chdir: source_root).lines.first.to_s,
  "c.scip_clang.sha256" => "sha256:#{Digest::SHA256.file(indexer).hexdigest}"
}

File.write(output, JSON.pretty_generate({
  "schema" => "fact-mine.semantic-environment.v1",
  "claims" => claims
}))
