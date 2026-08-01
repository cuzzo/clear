#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "zlib"

producer_summary, output, runtime_version = ARGV
abort "usage: build_symbol_bridge.rb PRODUCER.json.gz OUTPUT.json RUNTIME_VERSION" unless runtime_version

summary = Zlib::GzipReader.open(producer_summary) { |gzip| JSON.parse(gzip.read) }
prefix = "scip-dotnet nuget . . "

def runtime_package(descriptor)
  case descriptor
  when /\A(?:System\/(?:Array|String))#/
    "System.Runtime"
  when /\A(?:Generic|ObjectModel)\//
    "System.Collections"
  when /\AConcurrent\//
    "System.Collections.Concurrent"
  when %r{\ACollections/(?:ArrayList|Hashtable|BitArray)#}
    "System.Collections.NonGeneric"
  when /\ACollections\/DictionaryEntry#/
    "System.Runtime"
  end
end

symbols = summary.fetch("symbols").keys.sort.filter_map do |symbol|
  next unless symbol.start_with?(prefix)

  descriptor = symbol.delete_prefix(prefix)
  package = runtime_package(descriptor)
  next unless package

  [symbol, "scip-dotnet nuget #{package} #{runtime_version} #{descriptor}"]
end.to_h
abort "no compatible C# runtime symbols were found" if symbols.empty?

File.write(output, JSON.pretty_generate({
  "schema" => "fact-mine.symbol-bridge.v1",
  "symbols" => symbols
}))
