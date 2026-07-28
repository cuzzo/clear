#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "fileutils"
require "open3"

VERSION = "13.3.0-6ubuntu2~24.04.1"
TREE_SHA256 = "be6bb0b28e319291ad1c08d2aaee0509feb8eb98a24b67edff98fa047b33593a"
ARCH_TREE_SHA256 = "39dd70479b380d3552526891efea1103d478cd9804d8858ae48190d103b08823"
EFFECTIVE_TREE_SHA256 = "cab188eb89bb4b5cf99c97a16f9d1d3196d1d2ce9536ea70a9f74b782bc7bec2"
SURFACES = {
  ["c++17", "containers"] => %w[array atomic list memory tuple utility],
  ["c++17", "strings"] => %w[cctype iomanip iostream sstream string vector],
  ["c++20", "memory"] => %w[memory optional tuple utility]
}.freeze

workspace = ARGV.fetch(0) do
  abort "usage: materialize_source.rb WORKSPACE_ROOT"
end

def tree_digest(root)
  digest = Digest::SHA256.new
  Dir.glob(File.join(root, "**/*"), File::FNM_DOTMATCH)
    .select { |path| File.file?(path) }
    .sort
    .each do |path|
      relative = path.delete_prefix("#{root}#{File::SEPARATOR}")
      digest << relative << "\0" << Digest::SHA256.file(path).hexdigest << "\n"
    end
  digest.hexdigest
end

def executable(environment, fallback)
  configured = ENV[environment]
  return File.expand_path(configured) if configured && !configured.empty?

  candidate = ENV.fetch("PATH", "").split(File::PATH_SEPARATOR)
    .map { |directory| File.join(directory, fallback) }
    .find { |path| File.file?(path) && File.executable?(path) }
  abort "#{fallback} was not found; set #{environment}" unless candidate

  candidate
end

source = ENV.fetch("LIBSTDCXX_INCLUDE", "/usr/include/c++/13")
architecture = ENV.fetch(
  "LIBSTDCXX_ARCH_INCLUDE",
  "/usr/include/x86_64-linux-gnu/c++/13"
)
abort "libstdc++ headers were not found at #{source}" unless File.directory?(source)
abort "architecture-specific libstdc++ headers were not found at #{architecture}" unless File.directory?(architecture)
abort "unexpected libstdc++ tree digest" unless tree_digest(source) == TREE_SHA256
abort "unexpected architecture-specific libstdc++ tree digest" unless tree_digest(architecture) == ARCH_TREE_SHA256

cache = File.join(
  File.expand_path(workspace),
  ".cache",
  "stdlib-sources",
  "libstdcxx-#{VERSION}"
)
effective = File.join(cache, "include")
preprocessed = File.join(cache, "preprocessed")
marker = File.join(cache, ".complete")

complete = File.file?(marker) &&
  SURFACES.keys.all? do |standard, surface|
    File.file?(File.join(preprocessed, standard, "#{surface}.cpp"))
  end &&
  File.directory?(effective) &&
  tree_digest(effective) == EFFECTIVE_TREE_SHA256
unless complete
  temporary = "#{cache}.#{Process.pid}.tmp"
  FileUtils.rm_rf(temporary)
  FileUtils.mkdir_p(File.join(temporary, "include"))
  FileUtils.cp_r("#{source}/.", File.join(temporary, "include"))
  FileUtils.cp_r("#{architecture}/.", File.join(temporary, "include"))

  compiler = executable("CLANGXX", "clang++-20")
  SURFACES.each do |(standard, surface), headers|
    audit = File.join(temporary, "#{surface}-#{standard}.cpp")
    File.write(audit, headers.map { |header| "#include <#{header}>\n" }.join)
    stdout, stderr, status = Open3.capture3(
      compiler,
      "-std=#{standard}",
      "-I#{File.join(temporary, 'include')}",
      "-E",
      "-P",
      audit
    )
    abort "failed to preprocess #{surface} for #{standard}:\n#{stderr}" unless status.success?

    destination = File.join(temporary, "preprocessed", standard, "#{surface}.cpp")
    FileUtils.mkdir_p(File.dirname(destination))
    File.write(destination, stdout)
    FileUtils.rm_f(audit)
  end
  File.write(File.join(temporary, ".complete"), "#{VERSION}\n")
  FileUtils.mkdir_p(File.dirname(cache))
  FileUtils.rm_rf(cache)
  FileUtils.mv(temporary, cache)
end

abort "materialized libstdc++ include tree is missing" unless File.directory?(effective)
abort "materialized libstdc++ preprocessed surfaces are missing" unless File.directory?(preprocessed)
puts cache
