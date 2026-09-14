#!/usr/bin/env ruby
# frozen_string_literal: true

# Byte compatibility for the ANNOTATOR, the same way it was established for the
# parser: run both implementations over a corpus, canonically encode what each
# produced, and diff.
#
# The parser harness already owns every hard piece -- the Ruby-side canonical
# encoder, the GENERATED CLEAR-side encoders (built from the corpus's own struct
# and union declarations, so they track the tree), the payload comparison and
# the path-level first-difference report. The annotator differs in exactly two
# places: Ruby runs the annotator over the parsed program before encoding, and
# the generated CLEAR harness does the same before it encodes.
#
#   ruby tools/annotator_compat.rb --out tmp/annotator-compat
#
# The encoded value is the ANNOTATED program: annotation is stamps written onto
# the AST, so comparing the stamped tree is comparing the annotator's output.
$PROGRAM_NAME = 'annotator_compat_support'
require 'json'
require 'fileutils'
require 'optparse'

saved = $PROGRAM_NAME
$PROGRAM_NAME = 'parser_compat_support'
require_relative 'parser_compat'
$PROGRAM_NAME = saved

module AnnotatorCompat
  extend self

  ROOT = File.expand_path('..', __dir__)

  # Ruby oracle: parse, annotate, then encode the stamped program through the
  # same canonical encoder the parser comparison uses.
  def ruby_annotate(source)
    require_relative '../compiler/ruby/compiler/compiler_frontend'
    ast = ClearParser.new(Lexer.new(source).tokenize, source).parse
    annotator = SemanticAnnotator.new(source_code: source)
    annotator.annotate!(ast)
    ParserCompat::CanonicalDecoder.new(ParserCompat.canonical_encode(ast)).parse
  end

  def annotator_require_spec(generated_root)
    group = ParserCompat.package_groups(generated_root)
                        .find { |_name, members| members.include?('annotator/annotator.clear') }
    group ? "pkg:#{group.first}" : "pkg:#{ParserCompat.package_name('annotator/annotator.clear')}"
  end

  # The CLEAR harness is the parser one with annotation spliced in: the only
  # change is what `program` holds by the time it is encoded.
  def clear_harness_source(cases, generated_root)
    base = ParserCompat.clear_harness_source(cases, generated_root)
    annotator_require = %(REQUIRE "#{annotator_require_spec(generated_root)}";\n)

    parse_line = '        program = clearParser__parse_source(CAST(source AS String)) OR_ELSE RAISE;'
    raise 'parser harness shape changed; update the splice' unless base.include?(parse_line)

    annotated = <<~CLEAR.chomp
      #{parse_line}
              MUTABLE rtoc_annotator = semanticAnnotator__new(NIL, NIL, NIL, FALSE, source) OR_ELSE RAISE;
              semanticAnnotator__annotate_mut(&rtoc_annotator, &program) OR_ELSE RAISE;
    CLEAR
    annotator_require + base.sub(parse_line, annotated)
  end

  def main(argv)
    options = {
      out_dir: File.join(ROOT, 'tmp', 'annotator-compat'),
      corpus: 'smoke',
      generated_root: File.join(ROOT, 'compiler', 'src'),
      keep: false,
    }
    OptionParser.new do |p|
      p.on('--out DIR') { |v| options[:out_dir] = File.expand_path(v) }
      p.on('--corpus NAME') { |v| options[:corpus] = v }
      p.on('--generated-root DIR') { |v| options[:generated_root] = File.expand_path(v) }
      p.on('--keep') { options[:keep] = true }
      p.on('--emit-harness PATH', 'Write the generated CLEAR harness and stop') { |v| options[:emit] = v }
    end.parse!(argv)

    cases = ParserCompat.corpus(options[:corpus])
    if options[:emit]
      File.write(options[:emit], clear_harness_source(cases, options[:generated_root]))
      puts "harness: #{options[:emit]} (#{File.read(options[:emit]).lines.length} lines)"
      return 0
    end

    FileUtils.mkdir_p(options[:out_dir])
    ruby_payload = ParserCompat.implementation_payload('ruby', cases) { |source| ruby_annotate(source) }
    clear_payload = ParserCompat.run_clear_payload(cases, options.merge(harness: method(:clear_harness_source)))
    diff = ParserCompat.compare_payloads(ruby_payload, clear_payload)

    File.write(File.join(options[:out_dir], 'summary.json'), JSON.pretty_generate(diff))
    puts "annotator compatibility cases: #{cases.length}"
    puts "mismatches: #{diff['mismatches'].length}"
    diff['mismatches'].first(10).each { |m| puts "- #{m['case']}: #{m['message']}" }
    diff['mismatches'].empty? ? 0 : 1
  end
end

# $PROGRAM_NAME is reassigned above (the requires key off it), so the usual
# `__FILE__ == $0` guard cannot be used. __FILE__ alone is NOT a substitute: it
# names this file whether the file was run or required, so the old guard ran
# main() -- a full CLEAR build -- on `require_relative "tools/annotator_compat"`.
# At the top level of the entry script `caller` is empty; inside a require it
# is not.
exit(AnnotatorCompat.main(ARGV)) if caller.empty?
