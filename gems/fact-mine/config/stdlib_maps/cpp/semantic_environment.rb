#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "json"
require "open3"

source_root, output = ARGV
abort "usage: semantic_environment.rb SOURCE_ROOT OUTPUT.json" unless source_root && output

def overlay_digest(*roots)
  files = {}
  roots.each do |root|
    Dir.glob(File.join(root, "**/*"), File::FNM_DOTMATCH)
      .select { |path| File.file?(path) }
      .each do |path|
        relative = path.delete_prefix("#{root}#{File::SEPARATOR}")
        files[relative] = path
      end
  end
  digest = Digest::SHA256.new
  files.sort.each do |relative, path|
      digest << relative << "\0" << Digest::SHA256.file(path).hexdigest << "\n"
  end
  digest.hexdigest
end

def capture!(*command, chdir:)
  stdout, stderr, status = Open3.capture3(*command, chdir: chdir)
  abort "#{command.join(' ')} failed:\n#{stderr}" unless status.success?

  stdout.strip
end

source_root = File.expand_path(source_root)
database = JSON.parse(File.read(File.join(source_root, "compile_commands.json")))
arguments = database.fetch(0).fetch("arguments")
compiler = File.expand_path(arguments.fetch(0))
standard = arguments.find { |argument| argument.start_with?("-std=") }
abort "compile command has no explicit C++ standard" unless standard

semantic_flags = arguments.select do |argument|
  argument.start_with?("-std=", "-D", "-U")
end
base_headers = ENV.fetch("LIBSTDCXX_INCLUDE", "/usr/include/c++/13")
architecture_headers = ENV.fetch(
  "LIBSTDCXX_ARCH_INCLUDE",
  "/usr/include/x86_64-linux-gnu/c++/13"
)
abort "libstdc++ headers were not found at #{base_headers}" unless File.directory?(base_headers)
abort "architecture-specific libstdc++ headers were not found at #{architecture_headers}" unless File.directory?(architecture_headers)
macros = capture!(
  compiler,
  *semantic_flags,
  "-I#{base_headers}",
  "-I#{architecture_headers}",
  "-dM",
  "-E",
  "-x",
  "c++",
  "-include",
  "bits/c++config.h",
  "/dev/null",
  chdir: source_root
).lines.sort.join
indexer = ENV["SCIP_CLANG"]
indexer ||= ENV.fetch("PATH", "").split(File::PATH_SEPARATOR)
  .map { |directory| File.join(directory, "scip-clang") }
  .find { |path| File.file?(path) && File.executable?(path) }
abort "scip-clang was not found; set SCIP_CLANG" unless indexer

config = File.join(architecture_headers, "bits", "c++config.h")
version = capture!(compiler, "--version", chdir: source_root).lines.first.strip
target = capture!(compiler, "-dumpmachine", chdir: source_root)
indexer_version = capture!(indexer, "--version", chdir: source_root).lines.first.strip

File.write(output, JSON.pretty_generate({
  "schema" => "fact-mine.semantic-environment.v1",
  "claims" => {
    "cpp.stdlib.vendor" => "libstdc++",
    "cpp.stdlib.effective_headers.sha256" =>
      "sha256:#{overlay_digest(base_headers, architecture_headers)}",
    "cpp.stdlib.config.sha256" => "sha256:#{Digest::SHA256.file(config).hexdigest}",
    "cpp.compiler.version" => version,
    "cpp.compiler.target" => target,
    "cpp.compiler.sha256" => "sha256:#{Digest::SHA256.file(compiler).hexdigest}",
    "cpp.preprocessor_macros.sha256" => "sha256:#{Digest::SHA256.hexdigest(macros)}",
    "cpp.language_standard" => standard,
    "cpp.scip_clang.version" => indexer_version,
    "cpp.scip_clang.sha256" => "sha256:#{Digest::SHA256.file(indexer).hexdigest}"
  }
}))
