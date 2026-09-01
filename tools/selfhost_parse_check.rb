#!/usr/bin/env ruby
# frozen_string_literal: true

# Parse ONE generated file -- no package assembly, no type check.
#
# The unit checker takes minutes because it builds the whole SCC package and
# runs the full annotator. A syntax slip does not need any of that: the lexer
# and parser see one file at a time. Catching those here keeps the slow checker
# for the errors that actually need a package.
#
#   ruby tools/selfhost_parse_check.rb mir/lowering/concurrency.clear ...
#   ruby tools/selfhost_parse_check.rb --all

$LOAD_PATH.unshift(File.expand_path('../compiler/ruby', __dir__))
require 'ast/lexer'
require 'ast/parser'

ROOT = File.expand_path('..', __dir__)
GENERATED = File.join(ROOT, 'compiler', 'src')

files =
  if ARGV.first == '--all'
    Dir.glob(File.join(GENERATED, '**', '*.clear')).map { |f| f.sub("#{GENERATED}/", '') }.sort
  else
    ARGV
  end
abort 'usage: selfhost_parse_check.rb <relative.clear>... | --all' if files.empty?

failed = 0
files.each do |rel|
  path = File.join(GENERATED, rel)
  source = File.read(path)
  begin
    ClearParser.new(Lexer.new(source).tokenize, source).parse
  rescue StandardError => e
    failed += 1
    puts "#{rel}: #{e.message.lines.first&.strip}"
  end
end
puts "#{files.size - failed}/#{files.size} parse"
exit(failed.zero? ? 0 : 1)
