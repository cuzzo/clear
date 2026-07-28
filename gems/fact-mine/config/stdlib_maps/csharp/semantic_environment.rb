#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "json"
require "open3"

EXPECTED_INDEXER = "0.2.14"
TARGET_FRAMEWORK = "net10.0"

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

def capture!(*command, chdir:, env: {})
  stdout, stderr, status = Open3.capture3(env, *command, chdir: chdir)
  abort "#{command.join(' ')} failed:\n#{stderr}" unless status.success?

  stdout.strip
end

source_root = File.expand_path(source_root)
dotnet = executable("DOTNET", "dotnet")
indexer = executable("SCIP_DOTNET", "scip-dotnet")
runtime_root = ENV["DOTNET_ROOT"]
runtime_root = File.dirname(dotnet) if runtime_root.nil? || runtime_root.empty?
environment = {
  "DOTNET_ROOT" => runtime_root,
  "PATH" => "#{File.dirname(dotnet)}#{File::PATH_SEPARATOR}#{ENV.fetch('PATH', '')}"
}
indexer_version = capture!(indexer, "--version", chdir: source_root, env: environment)
unless indexer_version == EXPECTED_INDEXER || indexer_version.start_with?("#{EXPECTED_INDEXER}+")
  abort "scip-dotnet #{EXPECTED_INDEXER} is required, got #{indexer_version.inspect}"
end

reference = Dir[File.join(
  runtime_root,
  "packs/Microsoft.NETCore.App.Ref/10.0.*/ref/#{TARGET_FRAMEWORK}/System.Runtime.dll"
)].max
abort "the .NET 10 System.Runtime reference assembly was not found below #{runtime_root}" unless reference

indexer_dll = Dir[File.join(
  File.dirname(indexer),
  ".store/scip-dotnet/#{EXPECTED_INDEXER}/scip-dotnet/#{EXPECTED_INDEXER}/tools/**/scip-dotnet.dll"
)].first
indexer_dll ||= indexer
revision = capture!("git", "rev-parse", "HEAD", chdir: source_root)

File.write(output, JSON.pretty_generate({
  "schema" => "fact-mine.semantic-environment.v1",
  "claims" => {
    "csharp.runtime.source" => "dotnet/runtime@#{revision}",
    "csharp.target_framework" => TARGET_FRAMEWORK,
    "csharp.reference_pack.system_runtime.sha256" =>
      "sha256:#{Digest::SHA256.file(reference).hexdigest}",
    "csharp.scip_dotnet.release" => EXPECTED_INDEXER,
    "csharp.scip_dotnet.sha256" =>
      "sha256:#{Digest::SHA256.file(indexer_dll).hexdigest}"
  }
}))
