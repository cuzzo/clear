#!/usr/bin/env ruby
# frozen_string_literal: true

# Byte-compatibility harness for the ANNOTATOR, the counterpart to
# tools/parser_compat.rb.
#
# The parser harness compares a parsed AST between the Ruby and the self-hosted
# CLEAR implementation. The annotator's output is not a new tree: it is the same
# tree with STAMPS on it (type_info/full_type, was_moved, storage, provenance,
# bindings, ...). Byte compatibility therefore means "the annotated tree encodes
# identically", so this harness encodes the tree AFTER annotation, with the
# stamps included, and compares those bytes.
#
# The Ruby side runs today and is what defines the byte-exact contract the CLEAR
# annotator has to meet. The CLEAR side is wired to the same shape and turns on
# once compiler/src's annotator closure compiles -- until then `--ruby-only` is
# the mode that does useful work: it pins the encoding so the target cannot
# drift while the migration is in progress.
#
#   ruby tools/annotator_compat.rb --out tmp/annotator-compat --ruby-only
#
# Cases come from the same corpus the parser harness uses, so a case that
# already parses byte-identically is a case whose annotation can be compared
# without first arguing about the parse.

require 'json'
require 'msgpack'
require 'fileutils'
require 'optparse'
require 'open3'

# parser_compat.rb runs itself when it is the program; borrow its helpers by
# taking that name away for the duration of the require.
INVOKED_DIRECTLY = $PROGRAM_NAME.end_with?('annotator_compat.rb')
$PROGRAM_NAME = 'annotator_compat_support' if INVOKED_DIRECTLY
require_relative 'parser_compat'
require_relative '../compiler/ruby/compiler/compiler_frontend'

module AnnotatorCompat
  extend self

  SCHEMA = 'clear.annotator.compat.v1'

  # Stamps the annotator owns. Encoding only these keeps the comparison about
  # annotation rather than about parse details the parser harness already
  # covers, and keeps a stamp added later from silently widening the contract.
  STAMPED_ATTRIBUTES = %w[
    type_object coerced_type_object storage_override was_moved var_used
    container_borrow slot_size matched_stdlib_def stdlib_allocates
    mutates_receiver can_fail error_kind error_type module_alias
  ].freeze


  # The annotator's corpus is its OWN, not the parser's: a parse-only case is
  # allowed to reference an undeclared type or carry an effect the checker
  # rejects, and neither can be annotated. Every case here is a complete
  # program, chosen so that between them they exercise each stamp in
  # STAMPED_ATTRIBUTES.
  CASES = [
    { 'name' => 'assignment', 'source' => "answer = 42;\n" },
    { 'name' => 'literals', 'source' => "name = \"clear\"; enabled = TRUE; missing = NIL; ratio = 3.5;\n" },
    { 'name' => 'collections', 'source' => "items = [1, 2, 3]; pairs = {\"a\": 1, \"b\": 2};\n" },
    {
      'name' => 'function',
      'source' => <<~CLEAR
        FN add(left: Int64, right: Int64 = 1) RETURNS Int64 ->
          total = left + right;
          RETURN total;
        END
      CLEAR
    },
    {
      'name' => 'struct_and_types',
      'source' => <<~CLEAR
        STRUCT Point { x: Int64, y: ?Float64 }
        FN main() RETURNS Void ->
          MUTABLE values: Int64[3];
          values[0] = 1;
          RETURN;
        END
      CLEAR
    },
    {
      'name' => 'control_flow',
      'source' => <<~CLEAR
        FN classify(value: Int64) RETURNS String ->
          IF value > 0 THEN
            RETURN "positive";
          ELSE
            RETURN "other";
          END
        END
      CLEAR
    },
    {
      'name' => 'pipeline',
      'source' => <<~CLEAR
        STRUCT Item { name: String, enabled: Bool }
        FN names(items: []Item) RETURNS []String ->
          RETURN items |> WHERE _.enabled |> SELECT COPY _.name;
        END
      CLEAR
    },
    {
      'name' => 'recursive_effect',
      'source' => <<~CLEAR
        FN walk(n: Int64) RETURNS Int64 EFFECTS REENTRANT:TAIL_CALL ->
          IF n <= 0 THEN
            RETURN 0;
          END
          RETURN walk(n - 1);
        END
      CLEAR
    },
    {
      'name' => 'ownership_transfer',
      'source' => <<~CLEAR
        FN consume(TAKES text: String) RETURNS Int64 ->
          RETURN text.length();
        END
        FN main() RETURNS Void ->
          MUTABLE greeting = "hello";
          used = consume(GIVE greeting);
          RETURN;
        END
      CLEAR
    },
    {
      'name' => 'error_tense',
      'source' => <<~CLEAR
        FN parse(text: String) RETURNS !Int64 ->
          IF text.length() == 0 THEN
            RAISE "empty";
          END
          RETURN text.length();
        END
        FN main() RETURNS !Void ->
          count = TRY (parse("abc"));
          RETURN;
        END
      CLEAR
    },
    {
      'name' => 'optional_tense',
      'source' => <<~CLEAR
        FN first(items: []Int64) RETURNS ?Int64 ->
          RETURN items[0];
        END
        FN main() RETURNS Void ->
          value = first([1, 2]) OR_ELSE 0;
          RETURN;
        END
      CLEAR
    },
    {
      'name' => 'struct_methods',
      'source' => <<~CLEAR
        STRUCT Counter { total: Int64 }
        FN counter__bump(MUTABLE self: Counter, by: Int64) RETURNS Void ->
          self.total = self.total + by;
        END
        FN main() RETURNS Void ->
          MUTABLE c = Counter{ total: 0 };
          counter__bump(&c, 2);
          RETURN;
        END
      CLEAR
    }
  ].freeze

  def main(argv)
    options = {
      out_dir: File.expand_path('tmp/annotator-compat'),
      ruby_only: false,
      limit: nil,
      generated_root: File.expand_path('compiler/src')
    }
    OptionParser.new do |parser|
      parser.banner = 'Usage: ruby tools/annotator_compat.rb [options]'
      parser.on('--out DIR') { |value| options[:out_dir] = File.expand_path(value) }
      parser.on('--ruby-only', 'Encode the Ruby side only (the CLEAR annotator is not built yet)') { options[:ruby_only] = true }
      parser.on('--limit N', Integer) { |value| options[:limit] = value }
      parser.on('--generated-root DIR') { |value| options[:generated_root] = File.expand_path(value) }
      parser.on('-h', '--help') { puts parser; exit 0 }
    end.parse!(argv)

    FileUtils.mkdir_p(options[:out_dir])
    cases = CASES
    cases = cases.first(options[:limit]) if options[:limit]

    ruby_payload = payload('ruby', cases)
    ParserCompat.write_msgpack(File.join(options[:out_dir], 'ruby.msgpack'), ruby_payload)

    ok = ruby_payload['cases'].count { |entry| entry['status'] == 'ok' }
    puts "annotator cases: #{ok}/#{ruby_payload['cases'].length} annotated"
    puts "ruby msgpack: #{File.join(options[:out_dir], 'ruby.msgpack')}"

    if options[:ruby_only]
      puts 'clear side: skipped (--ruby-only)'
      return ok == ruby_payload['cases'].length ? 0 : 1
    end

    clear_payload = run_clear_payload(cases, options)
    ParserCompat.write_msgpack(File.join(options[:out_dir], 'clear.msgpack'), clear_payload)
    puts "clear msgpack: #{File.join(options[:out_dir], 'clear.msgpack')}"

    identical = compare(ruby_payload, clear_payload)
    puts "annotator byte-compat: #{identical}/#{cases.length} cases byte-identical"
    identical == cases.length ? 0 : 1
  end

  # The CLEAR side is the parser harness's pipeline with one step inserted:
  # parse, ANNOTATE, then encode through the very same generated encoders. The
  # stamps live on the AST nodes those encoders already walk, so annotation
  # compatibility is the parse encoding of an annotated tree -- no second
  # encoder, and no chance of the two sides encoding different field sets.
  def run_clear_payload(cases, options)
    generated_root = options[:generated_root]
    dir = File.join(options[:out_dir], 'build')
    FileUtils.mkdir_p(dir)
    source = File.join(dir, 'annotator_compat.clear')
    binary = File.join(dir, 'annotator_compat')
    File.write(source, clear_harness_source(cases, generated_root))

    env = {
      'CLEAR_DISABLE_BUILD_ZIG' => '1',
      'CLEAR_EXTRA_LINK_LIBS' => 'pcre2-8',
      'CLEAR_EXTRA_NATIVE_DIRS' => generated_root
    }
    build = [LexerHarnessSupport::CLEAR, 'build', source, '-o', binary,
             '--no-stack-check', '--main-tier', 'service',
             *ENV.fetch('ANNOTATOR_COMPAT_BUILD_FLAGS', '--safe').split,
             *ParserCompat.package_flags(generated_root)]
    _out, err, status = Open3.capture3(env, *build)
    unless status.success?
      limit = ENV.fetch('ANNOTATOR_COMPAT_ERROR_LIMIT', '8').to_i
      warn "annotator_compat: CLEAR build failed\n#{err.lines.grep(/Error|error/).first(limit).join}"
      return { 'schema' => SCHEMA, 'implementation' => 'clear', 'cases' => [] }
    end

    stdout, _stderr, _status = Open3.capture3(env, binary)
    { 'schema' => SCHEMA, 'implementation' => 'clear', 'cases' => ParserCompat.parse_clear_output(stdout) }
  end

  # The Ruby side carries `tree` plus `stamps`; the CLEAR side carries the same
  # encoded tree. Compare the trees, which is where the stamps live.
  def compare(ruby_payload, clear_payload)
    clear_by_name = clear_payload['cases'].to_h { |entry| [entry['name'], entry] }
    ruby_payload['cases'].count do |ruby_case|
      clear_case = clear_by_name[ruby_case['name']]
      next false unless clear_case && clear_case['status'] == 'ok' && ruby_case['status'] == 'ok'

      same = clear_case['ast'] == ruby_case['ast']['tree']
      warn "MISMATCH #{ruby_case['name']}" unless same
      same
    end
  end

  # Reuses ParserCompat's generated node encoders verbatim: the same encoder
  # text, the same escaping, the same output protocol.
  def clear_harness_source(cases, generated_root)
    parser_source = ParserCompat.clear_harness_source(cases, generated_root)
    annotator_spec = annotator_require_spec(generated_root)

    unless parser_source.sub!(
      'program = clearParser__parse_source(CAST(source AS String)) OR_ELSE RAISE;',
      "program = clearParser__parse_source(CAST(source AS String)) OR_ELSE RAISE;\n" \
      "        MUTABLE annotator = semanticAnnotator__new(NIL, NIL, NIL, FALSE, CAST(source AS String));\n" \
      '        semanticAnnotator__annotate_mut(&annotator, &program) OR_ELSE RAISE;'
    )
      raise 'annotator_compat: parser harness no longer has the parse line to annotate after'
    end

    parser_source.sub(/\A/, "REQUIRE #{LexerHarnessSupport.clear_string_literal(annotator_spec)};\n")
  end

  def annotator_require_spec(generated_root)
    group = ParserCompat.package_groups(generated_root)
             .find { |_name, members| members.include?('annotator/annotator.clear') }
    group ? "pkg:#{group.first}" : File.join(generated_root, 'annotator', 'annotator.clear')
  end

  def payload(name, cases)
    {
      'schema' => SCHEMA,
      'implementation' => name,
      'cases' => cases.map { |entry| annotate_case(entry) }
    }
  end

  def annotate_case(entry)
    { 'name' => entry['name'], 'status' => 'ok', 'ast' => annotate_with_ruby(entry['source']) }
  rescue StandardError => e
    { 'name' => entry['name'], 'status' => 'error', 'error' => "#{e.class}: #{e.message}" }
  end

  # Parse, annotate, then encode the SAME canonical form the parser harness
  # uses, with the annotator's stamps folded in.
  def annotate_with_ruby(source)
    ast = ClearParser.new(Lexer.new(source).tokenize, source).parse
    SemanticAnnotator.new(source_code: source).annotate!(ast)
    {
      # The tree in the parser harness's canonical form, so a difference here
      # is a parse difference that harness already localizes.
      'tree' => ParserCompat::CanonicalDecoder.new(ParserCompat.canonical_encode(ast)).parse,
      # The annotator's own output: every stamp, addressed by its position in a
      # deterministic walk so the two implementations line up node for node.
      'stamps' => walk_stamps(ast)
    }
  end

  def walk_stamps(root)
    stamps = []
    index = 0
    visit = lambda do |node|
      return unless node.is_a?(Object) && node.respond_to?(:class)

      position = index
      index += 1
      collect_stamps(node).sort.each { |name, stamped| stamps << [position, node.class.name.to_s, name, stamped] }
      children(node).each { |child| visit.call(child) }
    end
    visit.call(root)
    stamps
  end

  # AST nodes are Structs: their children live in Struct MEMBERS, not in
  # instance variables (the ivars hold the annotator's own stamps). Walking
  # ivars alone reached the Program node and stopped.
  def children(node)
    return node.compact if node.is_a?(Array)
    return node.members.map { |member| node[member] }.compact if node.is_a?(Struct)
    return [] unless node.respond_to?(:instance_variables)

    node.instance_variables.flat_map do |ivar|
      value = node.instance_variable_get(ivar)
      case value
      when Array then value.compact
      else value.nil? ? [] : [value]
      end
    end
  end

  def collect_stamps(node)
    return {} unless node.respond_to?(:respond_to?)

    STAMPED_ATTRIBUTES.each_with_object({}) do |name, stamps|
      next unless node.respond_to?(name)

      stamped = begin
        node.public_send(name)
      rescue StandardError
        nil
      end
      next if stamped.nil?

      stamps[name] = stamped.respond_to?(:to_s) ? stamped.to_s : stamped
    end
  end
end

exit(AnnotatorCompat.main(ARGV)) if INVOKED_DIRECTLY
