#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "zlib"

summary, output = ARGV
abort "usage: build_symbol_bridge.rb PRODUCER.json.gz OUTPUT.json" unless summary && output

producer = Zlib::GzipReader.open(summary) { |gzip| JSON.parse(gzip.read) }
symbols = producer.fetch("symbols")
  .select do |symbol, row|
    symbol.start_with?("cxx . . $ std/") &&
      row.fetch("bound_quality") == "upper_bound_exact_symbol"
  end
  .keys
  .sort
  .to_h { |symbol| [symbol, symbol] }
abort "producer exported no exact std symbols" if symbols.empty?

File.write(output, JSON.pretty_generate({
  "schema" => "fact-mine.symbol-bridge.v1",
  "symbols" => symbols
}))
