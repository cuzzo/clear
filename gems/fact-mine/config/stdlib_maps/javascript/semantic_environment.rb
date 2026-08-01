#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "json"
require "open3"

source_root, output = ARGV
abort "usage: semantic_environment.rb SOURCE_ROOT OUTPUT.json" unless source_root && output

def executable(environment, fallback)
  configured = ENV[environment]
  return File.expand_path(configured) if configured && !configured.empty?

  path = ENV.fetch("PATH", "").split(File::PATH_SEPARATOR)
    .map { |directory| File.join(directory, fallback) }
    .find { |candidate| File.file?(candidate) && File.executable?(candidate) }
  abort "#{fallback} was not found; set #{environment}" unless path

  path
end

def capture!(*command, chdir:)
  stdout, stderr, status = Open3.capture3(*command, chdir: chdir)
  abort "#{command.join(' ')} failed:\n#{stderr}" unless status.success?

  stdout.strip
end

source_root = File.expand_path(source_root)
node = executable("NODE", "node")
indexer = executable("SCIP_TYPESCRIPT", "scip-typescript")
versions = JSON.parse(capture!(
  node,
  "-p",
  "JSON.stringify(process.versions)",
  chdir: source_root
))
%w[node v8 modules].each do |key|
  abort "Node did not report process.versions.#{key}" if versions[key].to_s.empty?
end

File.write(output, JSON.pretty_generate({
  "schema" => "fact-mine.semantic-environment.v1",
  "claims" => {
    "javascript.runtime" => "node",
    "javascript.node.version" => versions.fetch("node"),
    "javascript.v8.version" => versions.fetch("v8"),
    "javascript.node.modules_abi" => versions.fetch("modules"),
    "javascript.node.sha256" => "sha256:#{Digest::SHA256.file(node).hexdigest}",
    "javascript.scip_typescript.version" =>
      capture!(indexer, "--version", chdir: source_root).lines.first.to_s,
    "javascript.scip_typescript.sha256" =>
      "sha256:#{Digest::SHA256.file(indexer).hexdigest}"
  }
}))
