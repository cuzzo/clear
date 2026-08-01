#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "open3"

EXPECTED_INDEXER = "0.2.14"
TARGET_FRAMEWORK = "net10.0"

source_root, output = ARGV
abort "usage: index_corelib.rb SOURCE_ROOT OUTPUT.scip" unless source_root && output

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

  stdout
end

source_root = File.expand_path(source_root)
output = File.expand_path(output)
dotnet = executable("DOTNET", "dotnet")
indexer = executable("SCIP_DOTNET", "scip-dotnet")
runtime_root = ENV["DOTNET_ROOT"]
runtime_root = File.dirname(dotnet) if runtime_root.nil? || runtime_root.empty?
environment = {
  "DOTNET_ROOT" => runtime_root,
  "PATH" => "#{File.dirname(dotnet)}#{File::PATH_SEPARATOR}#{ENV.fetch('PATH', '')}"
}
environment["NUGET_PACKAGES"] = ENV["NUGET_PACKAGES"] if ENV["NUGET_PACKAGES"]
version = capture!(indexer, "--version", chdir: source_root, env: environment).strip
unless version == EXPECTED_INDEXER || version.start_with?("#{EXPECTED_INDEXER}+")
  abort "scip-dotnet #{EXPECTED_INDEXER} is required, got #{version.inspect}"
end

project = File.join(source_root, "FactMine.CoreLib.csproj")
File.write(project, <<~XML)
  <Project Sdk="Microsoft.NET.Sdk">
    <PropertyGroup>
      <TargetFramework>#{TARGET_FRAMEWORK}</TargetFramework>
      <EnableDefaultCompileItems>false</EnableDefaultCompileItems>
      <Nullable>enable</Nullable>
      <ImplicitUsings>disable</ImplicitUsings>
      <NoWarn>0436</NoWarn>
    </PropertyGroup>
    <ItemGroup>
      <Compile Include="src/libraries/System.Private.CoreLib/src/System/Collections/**/*.cs" />
      <Compile Include="src/libraries/System.Private.CoreLib/src/System/String.cs" />
      <Compile Include="src/libraries/System.Private.CoreLib/src/System/Array.cs" />
    </ItemGroup>
  </Project>
XML

capture!(dotnet, "restore", project, chdir: source_root, env: environment)
FileUtils.mkdir_p(File.dirname(output))
capture!(
  indexer,
  "index",
  File.basename(project),
  "--skip-dotnet-restore",
  "--output",
  output,
  chdir: source_root,
  env: environment
)
abort "scip-dotnet did not produce #{output}" unless File.size?(output)
