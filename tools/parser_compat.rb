#!/usr/bin/env ruby
# frozen_string_literal: true

begin
  require 'bundler/setup'
rescue LoadError
end

require 'fileutils'
require 'json'
require 'msgpack'
require 'optparse'
require 'tmpdir'

require_relative 'lexer_harness_support'
require_relative '../compiler/ruby/ast/parser'

module ParserCompat
  module_function

  SCHEMA = 'clear.parser.compat.v1'

  SMOKE_CASES = [
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
        FN names(items: Item[]) RETURNS String[] ->
          RETURN items |> WHERE _.enabled |> SELECT _.name;
        END
      CLEAR
    },
    {
      'name' => 'reentrant_effect',
      'source' => <<~CLEAR
        FN walk(n: Int64) RETURNS Int64 EFFECTS REENTRANT:TAIL_CALL ->
          RETURN n;
        END
      CLEAR
    }
  ].freeze

  def main(argv)
    options = {
      out_dir: File.join(LexerHarnessSupport::ROOT, 'tmp', 'parser-compat'),
      keep: false,
      corpus: 'smoke'
    }

    OptionParser.new do |parser|
      parser.banner = 'Usage: ruby tools/parser_compat.rb [--out DIR] [--keep]'
      parser.on('--out DIR', 'Output directory for MessagePack artifacts') { |value| options[:out_dir] = File.expand_path(value) }
      parser.on('--corpus NAME', 'Corpus to run: smoke (default)') { |value| options[:corpus] = value }
      parser.on('--keep', 'Keep generated CLEAR harness source and binary') { options[:keep] = true }
    end.parse!(argv)

    cases = corpus(options[:corpus])
    FileUtils.mkdir_p(options[:out_dir])

    ruby_payload = implementation_payload('ruby', cases) { |source| ruby_parse(source) }
    clear_payload = run_clear_payload(cases, options)
    diff_payload = compare_payloads(ruby_payload, clear_payload)

    write_msgpack(File.join(options[:out_dir], 'ruby.msgpack'), ruby_payload)
    write_msgpack(File.join(options[:out_dir], 'clear.msgpack'), clear_payload)
    write_msgpack(File.join(options[:out_dir], 'diff.msgpack'), diff_payload)
    File.write(File.join(options[:out_dir], 'summary.json'), JSON.pretty_generate(diff_payload))

    puts "parser compatibility cases: #{cases.length}"
    puts "ruby msgpack: #{File.join(options[:out_dir], 'ruby.msgpack')}"
    puts "clear msgpack: #{File.join(options[:out_dir], 'clear.msgpack')}"
    puts "diff msgpack: #{File.join(options[:out_dir], 'diff.msgpack')}"
    puts "mismatches: #{diff_payload['mismatches'].length}"

    if diff_payload['mismatches'].any?
      diff_payload['mismatches'].first(10).each do |mismatch|
        puts "- #{mismatch['case']}: #{mismatch['message']}"
      end
      exit 1
    end
  end

  def corpus(name)
    return SMOKE_CASES if name == 'smoke'

    raise "unknown corpus: #{name}"
  end

  def implementation_payload(name, cases)
    {
      'schema' => SCHEMA,
      'implementation' => name,
      'cases' => cases.map do |entry|
        begin
          {
            'name' => entry['name'],
            'status' => 'ok',
            'ast' => yield(entry['source'])
          }
        rescue StandardError => e
          {
            'name' => entry['name'],
            'status' => 'error',
            'error_class' => e.class.name.split('::').last,
            'error' => e.message,
            'ast' => nil
          }
        end
      end
    }
  end

  def ruby_parse(source)
    ast = ClearParser.new(Lexer.new(source).tokenize, source).parse
    CanonicalDecoder.new(canonical_encode(ast)).parse
  end

  def canonical_encode(value)
    case value
    when nil
      'N'
    when true
      'B1'
    when false
      'B0'
    when Symbol
      length_encoded('Y', value.to_s)
    when String
      length_encoded('S', value)
    when Integer
      "I#{value};"
    when Float
      "F#{float_text(value)};"
    when Lexer::Token
      canonical_object('Token', {
        'column' => value.column,
        'line' => value.line,
        'type' => value.type,
        'value' => value.value
      })
    when Array
      "A#{value.length}[#{value.map { |item| canonical_encode(item) }.join}]"
    when Hash
      pairs = value.map { |key, item| [canonical_encode(key), canonical_encode(item)] }
      pairs.sort_by! { |key, item| key + item }
      "H#{pairs.length}[#{pairs.flatten.join}]"
    when T::Enum
      canonical_object(value.class.name.split('::').last, { 'value' => value.serialize })
    else
      canonical_ruby_object(value)
    end
  end

  def canonical_ruby_object(value)
    fields = if value.is_a?(Struct)
               value.members.to_h { |member| [member.to_s, value[member]] }
             elsif value.class.respond_to?(:props)
               value.class.props.keys.to_h { |name| [name.to_s, value.public_send(name)] }
             else
               value.instance_variables.to_h do |ivar|
                 [ivar.to_s.delete_prefix('@'), value.instance_variable_get(ivar)]
               end
             end
    raise "unsupported parser value: #{value.class}" if fields.empty?

    canonical_object(value.class.name.split('::').last, fields)
  end

  def canonical_object(name, fields)
    encoded_fields = fields.sort_by { |field, _| field }.map do |field, value|
      length_encoded('S', field) + canonical_encode(value)
    end.join
    "O#{name.bytesize}:#{name}#{fields.length}[#{encoded_fields}]"
  end

  def length_encoded(tag, value)
    "#{tag}#{value.bytesize}:#{value}"
  end

  def float_text(value)
    text = format('%.6f', value)
    text.sub!(/0+\z/, '')
    text << '0' if text.end_with?('.')
    text
  end

  def run_clear_payload(cases, options)
    Dir.mktmpdir('parser-compat-', options[:out_dir]) do |dir|
      source = File.join(dir, 'parser_compat.clear')
      binary = File.join(dir, 'parser_compat')
      File.write(source, clear_harness_source(cases))

      env = {
        'CLEAR_DISABLE_BUILD_ZIG' => '1',
        'CLEAR_EXTRA_LINK_LIBS' => 'pcre2-8',
        'CLEAR_EXTRA_NATIVE_DIRS' => File.join(LexerHarnessSupport::ROOT, 'compiler', 'src')
      }
      LexerHarnessSupport.run!(
        LexerHarnessSupport::CLEAR, 'build', source,
        '-o', binary,
        '--no-stack-check',
        '--force',
        env: env
      )
      stdout, stderr = LexerHarnessSupport.run!(binary)
      stdout = stderr if stdout.empty?

      if options[:keep]
        FileUtils.cp(source, File.join(options[:out_dir], 'parser_compat.clear'))
        FileUtils.cp(binary, File.join(options[:out_dir], 'parser_compat'))
      end

      {
        'schema' => SCHEMA,
        'implementation' => 'clear',
        'cases' => parse_clear_output(stdout)
      }
    end
  end

  def clear_harness_source(cases)
    parser_path = File.join(LexerHarnessSupport::ROOT, 'compiler', 'src', 'ast', 'parser.clear')
    calls = cases.each_with_index.map do |entry, index|
      "  dumpCase(#{LexerHarnessSupport.clear_string_expr(entry['source'])}, #{index}, #{LexerHarnessSupport.clear_string_expr(entry['name'])}) OR_ELSE RAISE;"
    end.join("\n")

    <<~CLEAR
      REQUIRE #{LexerHarnessSupport.clear_string_literal(parser_path)};

      PRIVATE FN escapeCompat(value: String) RETURNS String ->
        MUTABLE out = "";
        MUTABLE i = 0;
        WHILE i < value.length() DO
          ch = value.charAt(i);
          IF ch == "\\\\" THEN
            out = out $+ "\\\\\\\\";
          ELSE_IF ch == "\\n" THEN
            out = out $+ "\\\\n";
          ELSE_IF ch == "\\r" THEN
            out = out $+ "\\\\r";
          ELSE_IF ch == "\\t" THEN
            out = out $+ "\\\\t";
          ELSE_IF ch == "\\0" THEN
            out = out $+ "\\\\0";
          ELSE_IF ch == "|" THEN
            out = out $+ "\\\\p";
          ELSE
            out = out $+ ch;
          END
          i += 1;
        END
        RETURN out;
      END

      PRIVATE FN lengthEncoded(tag: String, value: String) RETURNS String ->
        RETURN tag $+ value.length().toString() $+ ":" $+ value;
      END

      PRIVATE FN trimTrailingZeros(value: String) RETURNS String ->
        MUTABLE end_index = value.length();
        WHILE end_index > 0 AND value.substr(end_index - 1, 1) == "0" DO
          end_index -= 1;
        END
        IF end_index == 0 THEN
          RETURN "0";
        END
        RETURN value.substr(0, end_index);
      END

      PRIVATE FN floatValueText(value: Float64) RETURNS String ->
        MUTABLE current = value;
        MUTABLE prefix = "";
        IF current < 0.0 THEN
          prefix = "-";
          current = 0.0 - current;
        END
        MUTABLE whole = toInt(current);
        frac = current - whole.toFloat();
        MUTABLE scaled = toInt((frac * 1_000_000.0) + 0.5);
        IF scaled >= 1_000_000 THEN
          whole += 1;
          scaled -= 1_000_000;
        END
        IF scaled == 0 THEN
          RETURN prefix $+ whole.toString() $+ ".0";
        END
        MUTABLE frac_text = scaled.toString();
        WHILE frac_text.length() < 6 DO
          frac_text = "0" $+ frac_text;
        END
        RETURN prefix $+ whole.toString() $+ "." $+ trimTrailingZeros(frac_text);
      END

      PRIVATE FN encodeTokenValue(value: TokenValue) RETURNS String ->
        RETURN MATCH value START
          TokenValue.Nil -> "N",
          TokenValue.Str AS item -> lengthEncoded("S", item),
          TokenValue.Int AS item -> "I" $+ item.toString() $+ ";",
          TokenValue.UInt AS item -> "I" $+ item.toString() $+ ";",
          TokenValue.Float AS item -> "F" $+ floatValueText(item) $+ ";",
        END;
      END

      PRIVATE FN encodeToken(token: Token) RETURNS String ->
        RETURN "O5:Token4[" $+
          lengthEncoded("S", "column") $+ "I" $+ token.column.toString() $+ ";" $+
          lengthEncoded("S", "line") $+ "I" $+ token.line.toString() $+ ";" $+
          lengthEncoded("S", "type") $+ lengthEncoded("Y", token.type) $+
          lengthEncoded("S", "value") $+ encodeTokenValue(token.value) $+
          "]";
      END

      PRIVATE FN encodeCompat(value: Any) RETURNS String EFFECTS REENTRANT ->
        IF value == NIL THEN
          RETURN "N";
        ELSE_IF value IS_A Token AS token THEN
          RETURN encodeToken(token);
        ELSE_IF value IS_A String@symbol AS symbol_value THEN
          RETURN lengthEncoded("Y", CAST(symbol_value AS String));
        ELSE_IF value IS_A String AS string_value THEN
          RETURN lengthEncoded("S", string_value);
        ELSE_IF value IS_A Bool AS bool_value THEN
          RETURN IF bool_value THEN "B1" ELSE "B0" END;
        ELSE_IF value IS_A Int64 AS int_value THEN
          RETURN "I" $+ int_value.toString() $+ ";";
        ELSE_IF value IS_A UInt64 AS uint_value THEN
          RETURN "I" $+ uint_value.toString() $+ ";";
        ELSE_IF value IS_A Float64 AS float_value THEN
          RETURN "F" $+ floatValueText(float_value) $+ ";";
        ELSE_IF value IS_A Any[] AS items THEN
          MUTABLE encoded = "A" $+ items.length().toString() $+ "[";
          MUTABLE i = 0;
          WHILE i < items.length() DO
            encoded = encoded $+ encodeCompat(items[i]);
            i += 1;
          END
          RETURN encoded $+ "]";
        ELSE_IF value IS_A HashMap<Any> AS values THEN
          MUTABLE pairs: String[] = [];
          values.keys() |> EACH {
            pairs.append(encodeCompat(_) $+ encodeCompat(values[_]));
          };
          pairs = pairs.sort();
          RETURN "H" $+ pairs.length().toString() $+ "[" $+ pairs.join("") $+ "]";
        ELSE_IF value IS_A Struct AS object THEN
          MUTABLE members = object.class().members().sort();
          MUTABLE encoded = "O" $+ object.class().name().length().toString() $+ ":" $+
            object.class().name() $+ members.length().toString() $+ "[";
          MUTABLE i = 0;
          WHILE i < members.length() DO
            member = members[i];
            encoded = encoded $+ lengthEncoded("S", member) $+ encodeCompat(object[member]);
            i += 1;
          END
          RETURN encoded $+ "]";
        END
        panic("unsupported parser compatibility value");
      END

      PRIVATE FN dumpCase(source: String@raw, index: Int64, name: String) RETURNS !Void ->
        tokens = tokenizeSource(source) OR_ELSE RAISE;
        MUTABLE parser = clearParser__new(tokens, source);
        program = parse(parser);
        IF program == NIL THEN
          panic("parser returned NIL");
        END
        print("CASE|" $+ index.toString() $+ "|" $+ escapeCompat(name) $+ "|ok|");
        print("AST|" $+ escapeCompat(encodeCompat(program?)));
        print("ENDCASE");
        RETURN;
      END

      FN main() RETURNS Void ->
      #{calls}
        RETURN;
      END
    CLEAR
  end

  def parse_clear_output(stdout)
    cases = []
    current = nil

    stdout.each_line(chomp: true) do |line|
      next if line.empty?

      tag = line.split('|', 2).first
      case tag
      when 'CASE'
        _, index, name, status, error = line.split('|', 5)
        current = {
          'index' => index.to_i,
          'name' => unescape_compat(name),
          'status' => status,
          'ast' => nil
        }
        current['error_class'] = error if status == 'error'
      when 'AST'
        raise "AST outside CASE: #{line}" unless current

        current['ast'] = CanonicalDecoder.new(unescape_compat(line.delete_prefix('AST|'))).parse
      when 'ENDCASE'
        raise 'ENDCASE outside CASE' unless current

        current.delete('index')
        cases << current
        current = nil
      else
        raise "unexpected CLEAR parser output: #{line}"
      end
    end

    cases
  end

  def unescape_compat(value)
    out = +''
    i = 0
    while i < value.length
      if value[i] == '\\' && i + 1 < value.length
        i += 1
        out << case value[i]
               when 'n' then "\n"
               when 'r' then "\r"
               when 't' then "\t"
               when '0' then "\0"
               when 'p' then '|'
               when '\\' then '\\'
               else value[i]
               end
      else
        out << value[i]
      end
      i += 1
    end
    out
  end

  def compare_payloads(ruby_payload, clear_payload)
    mismatches = []
    ruby_payload['cases'].each_with_index do |ruby_case, index|
      clear_case = clear_payload['cases'][index]
      if clear_case.nil?
        mismatches << { 'case' => ruby_case['name'], 'message' => 'missing CLEAR case' }
        next
      end
      if ruby_case['name'] != clear_case['name']
        mismatches << { 'case' => ruby_case['name'], 'message' => "case name mismatch: #{clear_case['name']}" }
        next
      end
      if ruby_case['status'] != clear_case['status']
        mismatches << { 'case' => ruby_case['name'], 'message' => "status ruby=#{ruby_case['status']} clear=#{clear_case['status']}" }
        next
      end
      next if ruby_case['status'] == 'error'
      next if ruby_case['ast'] == clear_case['ast']

      mismatches << {
        'case' => ruby_case['name'],
        'message' => first_difference(ruby_case['ast'], clear_case['ast'])
      }
    end

    {
      'schema' => 'clear.parser.compat.diff.v1',
      'cases' => ruby_payload['cases'].length,
      'mismatches' => mismatches
    }
  end

  def first_difference(ruby_value, clear_value, path = '$')
    return "#{path}: ruby=#{ruby_value.inspect} clear=#{clear_value.inspect}" unless ruby_value.class == clear_value.class

    case ruby_value
    when Array
      return "#{path}: length ruby=#{ruby_value.length} clear=#{clear_value.length}" unless ruby_value.length == clear_value.length

      ruby_value.each_index do |index|
        next if ruby_value[index] == clear_value[index]

        return first_difference(ruby_value[index], clear_value[index], "#{path}[#{index}]")
      end
    when Hash
      keys = (ruby_value.keys + clear_value.keys).uniq.sort_by(&:to_s)
      keys.each do |key|
        return "#{path}: missing Ruby key #{key.inspect}" unless ruby_value.key?(key)
        return "#{path}: missing CLEAR key #{key.inspect}" unless clear_value.key?(key)
        next if ruby_value[key] == clear_value[key]

        return first_difference(ruby_value[key], clear_value[key], "#{path}.#{key}")
      end
    end
    "#{path}: ruby=#{ruby_value.inspect} clear=#{clear_value.inspect}"
  end

  def write_msgpack(path, payload)
    File.binwrite(path, MessagePack.pack(payload))
  end

  class CanonicalDecoder
    def initialize(source)
      @source = source
      @pos = 0
    end

    def parse
      value = parse_value
      raise "trailing canonical data at #{@pos}" unless @pos == @source.bytesize

      value
    end

    private

    def parse_value
      tag = take(1)
      case tag
      when 'N' then nil
      when 'B' then take(1) == '1'
      when 'I' then take_until(';').to_i
      when 'F' then take_until(';').to_f
      when 'S' then parse_string
      when 'Y' then { '$symbol' => parse_string_body }
      when 'A' then parse_array
      when 'H' then parse_hash
      when 'O' then parse_object
      else raise "unknown canonical tag #{tag.inspect} at #{@pos - 1}"
      end
    end

    def parse_string
      parse_string_body
    end

    def parse_string_body
      length = take_until(':').to_i
      take(length)
    end

    def parse_array
      count = take_until('[').to_i
      values = Array.new(count) { parse_value }
      expect(']')
      values
    end

    def parse_hash
      count = take_until('[').to_i
      pairs = Array.new(count) { [parse_value, parse_value] }
      expect(']')
      { '$hash' => pairs }
    end

    def parse_object
      name = parse_string_body
      count = take_until('[').to_i
      fields = {}
      count.times do
        raise 'object field name must be a string' unless take(1) == 'S'

        fields[parse_string_body] = parse_value
      end
      expect(']')
      { 'class' => name.split('::').last, 'fields' => fields }
    end

    def expect(value)
      actual = take(value.bytesize)
      raise "expected #{value.inspect}, got #{actual.inspect}" unless actual == value
    end

    def take_until(delimiter)
      index = @source.index(delimiter, @pos)
      raise "missing #{delimiter.inspect} at #{@pos}" unless index

      value = @source.byteslice(@pos, index - @pos)
      @pos = index + delimiter.bytesize
      value
    end

    def take(length)
      value = @source.byteslice(@pos, length)
      raise "canonical data ended at #{@pos}" unless value&.bytesize == length

      @pos += length
      value
    end
  end
end

ParserCompat.main(ARGV) if $PROGRAM_NAME == __FILE__
