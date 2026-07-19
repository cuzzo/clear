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
require_relative '../compiler/ruby/ast/lexer'

module LexerCompat
  module_function

  def main(argv)
    options = {
      out_dir: File.join(LexerHarnessSupport::ROOT, 'tmp', 'lexer-compat'),
      keep: false,
      corpus: 'smoke'
    }

    OptionParser.new do |parser|
      parser.banner = 'Usage: ruby tools/lexer_compat.rb [--out DIR] [--keep]'
      parser.on('--out DIR', 'Output directory for MessagePack artifacts') { |value| options[:out_dir] = File.expand_path(value) }
      parser.on('--corpus NAME', 'Corpus to run: smoke (default)') { |value| options[:corpus] = value }
      parser.on('--keep', 'Keep generated CLEAR harness source') { options[:keep] = true }
    end.parse!(argv)

    cases = corpus(options[:corpus])
    FileUtils.mkdir_p(options[:out_dir])

    ruby_payload = implementation_payload('ruby', cases) do |source|
      ruby_tokenize(source)
    end

    clear_payload = run_clear_payload(cases, options)
    diff_payload = compare_payloads(ruby_payload, clear_payload)

    write_msgpack(File.join(options[:out_dir], 'ruby.msgpack'), ruby_payload)
    write_msgpack(File.join(options[:out_dir], 'clear.msgpack'), clear_payload)
    write_msgpack(File.join(options[:out_dir], 'diff.msgpack'), diff_payload)
    File.write(File.join(options[:out_dir], 'summary.json'), JSON.pretty_generate(diff_payload))

    puts "lexer compatibility cases: #{cases.length}"
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
    case name
    when 'smoke'
      LexerHarnessSupport::SMOKE_CASES
    else
      raise "unknown corpus: #{name}"
    end
  end

  def implementation_payload(name, cases)
    {
      'schema' => 'clear.lexer.compat.v1',
      'implementation' => name,
      'cases' => cases.map do |entry|
        begin
          {
            'name' => entry['name'],
            'status' => 'ok',
            'tokens' => yield(entry['source'])
          }
        rescue StandardError => e
          {
            'name' => entry['name'],
            'status' => 'error',
            'error_class' => e.class.name,
            'error' => e.message,
            'tokens' => []
          }
        end
      end
    }
  end

  def ruby_tokenize(source)
    Lexer.new(source).tokenize.map do |token|
      kind, value = canonical_value(token.type.to_s, token.value)
      {
        'type' => token.type.to_s,
        'kind' => kind,
        'value' => value,
        'line' => token.line,
        'column' => token.column
      }
    end
  end

  def canonical_value(type, value)
    case value
    when nil
      ['nil', nil]
    when String
      ['str', value]
    when Float
      ['float', value]
    when Integer
      [type == 'UINT64' ? 'uint' : 'int', value]
    else
      [value.class.name, value.to_s]
    end
  end

  def run_clear_payload(cases, options)
    Dir.mktmpdir('lexer-compat-', options[:out_dir]) do |dir|
      source = File.join(dir, 'lexer_compat.clear')
      binary = File.join(dir, 'lexer_compat')
      File.write(source, clear_harness_source(cases))
      FileUtils.cp(source, File.join(options[:out_dir], 'lexer_compat.clear')) if options[:keep]

      build_args = [
        LexerHarnessSupport::CLEAR, 'build', source,
        '-o', binary,
        '--no-stack-check',
        '--force'
      ]
      LexerHarnessSupport.run!(*build_args)
      stdout, stderr = LexerHarnessSupport.run!(binary)
      stdout = stderr if stdout.empty?
      parsed = parse_clear_output(stdout)

      if options[:keep]
        FileUtils.cp(binary, File.join(options[:out_dir], 'lexer_compat'))
      end

      {
        'schema' => 'clear.lexer.compat.v1',
        'implementation' => 'clear',
        'cases' => parsed
      }
    end
  end

  def clear_harness_source(cases)
    lexer_path = File.join(LexerHarnessSupport::ROOT, 'compiler', 'src', 'ast', 'lexer.clear')
    calls = cases.each_with_index.map do |entry, idx|
      "  dumpCase(#{LexerHarnessSupport.clear_string_expr(entry['source'])}, #{idx}, #{LexerHarnessSupport.clear_string_expr(entry['name'])}) OR_ELSE RAISE;"
    end.join("\n")

    <<~CLEAR
      REQUIRE #{LexerHarnessSupport.clear_string_literal(lexer_path)};

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

      PRIVATE FN tokenValueKind(token: Token) RETURNS String ->
        PARTIAL MATCH token.value START
          TokenValue.Nil -> RETURN "nil";,
          TokenValue.Str AS value -> RETURN "str";,
          TokenValue.Int AS value -> RETURN "int";,
          TokenValue.UInt AS value -> RETURN "uint";,
          TokenValue.Float AS value -> RETURN "float";,
        END
        RETURN "unknown";
      END

      PRIVATE FN tokenValueText(token: Token) RETURNS String ->
        PARTIAL MATCH token.value START
          TokenValue.Nil -> RETURN "";,
          TokenValue.Str AS value -> RETURN escapeCompat(value);,
          TokenValue.Int AS value -> RETURN value.toString();,
          TokenValue.UInt AS value -> RETURN value.toString();,
          TokenValue.Float AS value -> RETURN floatValueText(value);,
        END
        RETURN "";
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

      PRIVATE FN dumpToken(token: Token) RETURNS Void ->
        print(
          "TOKEN|" $+ token.type $+ "|" $+ tokenValueKind(token) $+ "|" $+
          token.line.toString() $+ "|" $+ token.column.toString() $+ "|" $+
          tokenValueText(token)
        );
        RETURN;
      END

      PRIVATE FN dumpCase(source: String@raw, index: Int64, name: String) RETURNS !Void ->
        print("CASE|" $+ index.toString() $+ "|" $+ escapeCompat(name) $+ "|ok|");
        tokens = tokenizeSource(source) OR_ELSE RAISE;
        MUTABLE i = 0;
        WHILE i < tokens.length() DO
          dumpToken(tokens[i]);
          i += 1;
        END
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
          'name' => unescape_compat(name),
          'status' => status,
          'tokens' => []
        }
        current['index'] = index.to_i
        current['error_class'] = error if status == 'error'
      when 'TOKEN'
        raise "TOKEN outside CASE: #{line}" unless current

        _, type, kind, line_no, column, value = line.split('|', 6)
        current['tokens'] << {
          'type' => type,
          'kind' => kind,
          'value' => parse_value(kind, unescape_compat(value || '')),
          'line' => line_no.to_i,
          'column' => column.to_i
        }
      when 'ENDCASE'
        raise 'ENDCASE outside CASE' unless current

        current.delete('index')
        cases << current
        current = nil
      else
        raise "unexpected CLEAR lexer output: #{line}"
      end
    end

    cases
  end

  def parse_value(kind, value)
    case kind
    when 'nil' then nil
    when 'int', 'uint' then value.to_i
    when 'float' then value.to_f
    else value
    end
  end

  def unescape_compat(value)
    out = +''
    i = 0
    while i < value.length
      ch = value[i]
      if ch == '\\' && i + 1 < value.length
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
        out << ch
      end
      i += 1
    end
    out
  end

  def compare_payloads(ruby_payload, clear_payload)
    mismatches = []
    ruby_cases = ruby_payload['cases']
    clear_cases = clear_payload['cases']

    ruby_cases.each_with_index do |ruby_case, index|
      clear_case = clear_cases[index]
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

      compare_tokens(ruby_case['name'], ruby_case['tokens'], clear_case['tokens'], mismatches)
    end

    {
      'schema' => 'clear.lexer.compat.diff.v1',
      'cases' => ruby_cases.length,
      'mismatches' => mismatches
    }
  end

  def compare_tokens(case_name, ruby_tokens, clear_tokens, mismatches)
    if ruby_tokens.length != clear_tokens.length
      mismatches << {
        'case' => case_name,
        'message' => "token count ruby=#{ruby_tokens.length} clear=#{clear_tokens.length}"
      }
      return
    end

    ruby_tokens.zip(clear_tokens).each_with_index do |(ruby_token, clear_token), index|
      next if ruby_token == clear_token

      mismatches << {
        'case' => case_name,
        'message' => "token #{index} ruby=#{ruby_token.inspect} clear=#{clear_token.inspect}"
      }
      return
    end
  end

  def write_msgpack(path, payload)
    File.binwrite(path, MessagePack.pack(payload))
  end
end

LexerCompat.main(ARGV) if $PROGRAM_NAME == __FILE__
