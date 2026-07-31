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
require 'set'
require 'tmpdir'

require_relative 'lexer_harness_support'
require_relative '../compiler/ruby/ast/lexer'

module LexerCompat
  module_function

  def main(argv)
    options = {
      out_dir: File.join(LexerHarnessSupport::ROOT, 'tmp', 'lexer-compat'),
      keep: false,
      corpus: 'smoke',
      lexer_path: File.join(LexerHarnessSupport::ROOT, 'compiler', 'src', 'ast', 'lexer.clear'),
      generated: false
    }

    OptionParser.new do |parser|
      parser.banner = 'Usage: ruby tools/lexer_compat.rb [--out DIR] [--keep]'
      parser.on('--out DIR', 'Output directory for MessagePack artifacts') { |value| options[:out_dir] = File.expand_path(value) }
      parser.on('--corpus NAME', 'Corpus to run: smoke (default) or full') { |value| options[:corpus] = value }
      parser.on('--keep', 'Keep generated CLEAR harness source') { options[:keep] = true }
      parser.on('--lexer PATH', 'CLEAR lexer implementation to compare') { |value| options[:lexer_path] = File.expand_path(value) }
      parser.on('--generated', 'Use ruby-to-CLEAR lexer__new / lexer__tokenize entry points') { options[:generated] = true }
      parser.on('--file PATH', 'Use one CLEAR source file as the corpus') { |value| options[:file] = File.expand_path(value) }
      parser.on('--lines', 'With --file, compare each source line independently') { options[:lines] = true }
      parser.on('--offset N', Integer, 'Skip the first N corpus cases') { |value| options[:offset] = value }
      parser.on('--limit N', Integer, 'Run at most N corpus cases') { |value| options[:limit] = value }
      parser.on('--batch-size N', Integer, 'CLEAR harness cases per process') { |value| options[:batch_size] = value }
    end.parse!(argv)

    cases = options[:file] ? file_corpus(options[:file], lines: options[:lines]) : corpus(options[:corpus])
    cases = cases.drop(options.fetch(:offset, 0))
    cases = cases.first(options[:limit]) if options[:limit]
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
    when 'full'
      roots = %w[compiler/src examples benchmarks transpile-tests]
      paths = roots.flat_map do |root|
        Dir.glob(File.join(LexerHarnessSupport::ROOT, root, '**', '*.clear'))
      end.uniq.sort
      paths.map do |path|
        {
          'name' => path.delete_prefix("#{LexerHarnessSupport::ROOT}/"),
          'source' => File.binread(path).force_encoding(Encoding::UTF_8)
        }
      end
    else
      raise "unknown corpus: #{name}"
    end
  end

  def file_corpus(path, lines: false)
    source = File.binread(path).force_encoding(Encoding::UTF_8)
    return [{ 'name' => path, 'source' => source }] unless lines

    source.lines.each_with_index.map do |line, index|
      { 'name' => "#{path}:#{index + 1}", 'source' => line }
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
    default_batch_size = options[:corpus] == 'full' ? 10 : 40
    batches = cases.each_slice(options.fetch(:batch_size, default_batch_size)).to_a
    clear_cases = batches.each_with_index.flat_map do |batch, batch_index|
      warn "CLEAR lexer batch #{batch_index + 1}/#{batches.length} (#{batch.length} cases)"
      run_clear_batch(batch, options, batch_index)
    end

    {
      'schema' => 'clear.lexer.compat.v1',
      'implementation' => 'clear',
      'cases' => clear_cases
    }
  end

  def run_clear_batch(cases, options, batch_index)
    Dir.mktmpdir('lexer-compat-', options[:out_dir]) do |dir|
      source = File.join(dir, 'lexer_compat.clear')
      binary = File.join(dir, 'lexer_compat')
      File.write(source, clear_harness_source(cases, options))
      ffi_module = if options[:generated]
        File.join(File.dirname(options.fetch(:lexer_path)), 'compiler_regex.zig')
      else
        File.join(LexerHarnessSupport::ROOT, 'compiler', 'src', 'compiler_regex.zig')
      end
      FileUtils.cp(ffi_module, dir) if File.file?(ffi_module)
      if options[:keep]
        FileUtils.cp(source, File.join(options[:out_dir], "lexer_compat_#{batch_index}.clear"))
      end

      build_args = [
        LexerHarnessSupport::CLEAR, 'build', source,
        '-o', binary,
        '--no-stack-check',
        '--force',
        *lexer_package_args(options.fetch(:lexer_path), options)
      ]
      LexerHarnessSupport.run!(
        *build_args,
        env: { 'CLEAR_EXTRA_LINK_LIBS' => 'pcre2-8' }
      )
      stdout, stderr, status = Open3.capture3('timeout', '15s', binary)
      generated_done = options[:generated] && stderr.include?('LEXER_COMPAT_DONE')
      unless status.success? || generated_done
        raise "#{binary} failed with #{status.exitstatus}\nSTDOUT:\n#{stdout}\nSTDERR:\n#{stderr}"
      end
      if stdout.empty?
        stdout = generated_done ? stderr.split(/thread \d+ panic: LEXER_COMPAT_DONE/, 2).first : stderr
      end
      parsed = parse_clear_output(stdout)

      if options[:keep]
        FileUtils.cp(binary, File.join(options[:out_dir], "lexer_compat_#{batch_index}"))
      end

      parsed
    end
  ensure
    if options[:corpus] == 'full'
      FileUtils.rm_rf(File.join(LexerHarnessSupport::ROOT, 'zig', '.clear-cache'))
    end
  end

  # ruby-to-CLEAR represents local generated files as explicitly registered
  # packages. The compatibility harness copies the root source into a temporary
  # program, so normal relative package discovery cannot see that generated
  # tree. Register the complete generated dependency closure without teaching
  # the harness anything about a particular compiler file.
  def generated_package_args(root_path)
    generated_packages(root_path).sort.flat_map { |name, path| ['--pkg', "#{name}=#{path}"] }
  end

  # The harness consumes the generated lexer the same way the self-host
  # verifier proves it: as a registered package, never as an inlined local
  # module. Inline mode compiles the generated closure as one unit instead.
  def lexer_package_args(lexer_path, options)
    return generated_package_args(lexer_path) if options[:generated]

    ['--pkg', "#{lexer_package_name(lexer_path)}=#{File.expand_path(lexer_path)}",
     *generated_package_args(lexer_path)]
  end

  def lexer_package_name(lexer_path)
    source_root = generated_source_root(lexer_path)
    relative = if source_root
      File.expand_path(lexer_path).delete_prefix("#{source_root}/")
    else
      File.basename(lexer_path)
    end
    "rtoc_#{relative.unpack1('H*')}"
  end

  def generated_packages(root_path)
    source_root = generated_source_root(root_path)
    return {} unless source_root

    seen_paths = Set.new
    packages = {}
    pending = [File.expand_path(root_path)]
    until pending.empty?
      path = pending.shift
      next if seen_paths.include?(path)

      seen_paths.add(path)
      File.read(path).scan(/REQUIRE\s+"pkg:([^"]+)"/) do |match|
        name = match.fetch(0)
        relative = decode_generated_package_name(name)
        next unless relative

        target = File.expand_path(relative, source_root)
        next unless File.file?(target)

        packages[name] = target
        pending << target
      end
    end

    packages
  end

  def stage_generated_packages(destination, root_path)
    generated_packages(root_path).each do |name, path|
      package_dir = File.join(destination, 'packages', name, 'src')
      FileUtils.mkdir_p(package_dir)
      FileUtils.cp(path, File.join(package_dir, 'lib.clear'))
    end
  end

  def generated_inline_source(root_path)
    packages = generated_packages(root_path)
    ordered = []
    seen = Set.new
    visit = lambda do |path|
      return if seen.include?(path)

      seen.add(path)
      source = File.read(path)
      source.scan(/REQUIRE\s+"pkg:([^"]+)"/) do |match|
        dependency = packages[match.fetch(0)]
        visit.call(dependency) if dependency
      end
      ordered << source.gsub(/^REQUIRE\s+"pkg:[^"]+"(?:\s+AS\s+[A-Za-z_]\w*)?\s*\n/, '')
    end
    visit.call(File.expand_path(root_path))
    ordered.join("\n")
  end

  def generated_source_root(path)
    current = File.dirname(File.expand_path(path))
    loop do
      return current if current.end_with?(File.join('compiler', 'src'))

      parent = File.dirname(current)
      return nil if parent == current

      current = parent
    end
  end

  def decode_generated_package_name(name)
    return nil unless name.start_with?('rtoc_')

    encoded = name.delete_prefix('rtoc_')
    return nil unless encoded.match?(/\A[0-9a-f]+\z/) && encoded.length.even?

    [encoded].pack('H*')
  end

  def clear_harness_source(cases, options)
    lexer_path = options.fetch(:lexer_path)
    generated = options.fetch(:generated)
    lexer_source = generated ? generated_inline_source(lexer_path) : "REQUIRE \"pkg:#{lexer_package_name(lexer_path)}\" AS lexer_module"
    tokenize_code = "MUTABLE lexer = TRY lexer__new(source);\n        tokens = TRY lexer__tokenize(&lexer);"
    calls = cases.each_with_index.map do |entry, idx|
      call = "dumpCase(#{LexerHarnessSupport.clear_string_expr(entry['source'])}, #{idx}, #{LexerHarnessSupport.clear_string_expr(entry['name'])})"
      if generated
        "  TRY #{call};"
      else
        "  #{call} OR_ELSE RAISE;"
      end
    end.join("\n")
    dump_case_return = '!Void'
    dump_case_result = 'RETURN;'
    main_exit = '  RETURN;'
    nil_value_check = 'token.value == NIL'
    value_setup = 'payload = UNWRAP token.value;'
    value_ref = 'payload'

    <<~CLEAR
      #{lexer_source}

      EXTERN FN compilerFloatBits(value: Float64) RETURNS UInt64 EFFECTS :safe FROM "compiler_regex";

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
        IF #{nil_value_check} THEN RETURN "nil"; END
        #{value_setup}
        IF token.type == "UINT64" THEN RETURN "uint"; END
        IF #{value_ref} IS_A TokenValue.Str AS value THEN RETURN "str"; END
        IF #{value_ref} IS_A TokenValue.Int AS value THEN RETURN "int"; END
        IF #{value_ref} IS_A TokenValue.UInt AS value THEN RETURN "int"; END
        IF #{value_ref} IS_A TokenValue.Float AS value THEN RETURN "float"; END
        RETURN "unknown";
      END

      PRIVATE FN tokenValueText(token: Token) RETURNS String ->
        IF #{nil_value_check} THEN RETURN ""; END
        #{value_setup}
        IF #{value_ref} IS_A TokenValue.Str AS value THEN RETURN escapeCompat(value); END
        IF #{value_ref} IS_A TokenValue.Int AS value THEN RETURN value.toString(); END
        IF #{value_ref} IS_A TokenValue.UInt AS value THEN RETURN value.toString(); END
        IF #{value_ref} IS_A TokenValue.Float AS value THEN RETURN floatValueText(value); END
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
        RETURN compilerFloatBits(value).toString();
      END

      PRIVATE FN dumpToken(token: Token) RETURNS Void ->
        print(
          "TOKEN|" $+ token.type $+ "|" $+ tokenValueKind(token) $+ "|" $+
          token.line.toString() $+ "|" $+ token.column.toString() $+ "|" $+
          tokenValueText(token)
        );
        RETURN;
      END

      PRIVATE FN dumpCase(source: String@raw, index: Int64, name: String) RETURNS #{dump_case_return} ->
        print("CASE|" $+ index.toString() $+ "|" $+ escapeCompat(name) $+ "|ok|");
        #{tokenize_code}
        tokens |> EACH dumpToken;
        print("ENDCASE");
        #{dump_case_result}
      END

      FN main() RETURNS Void ->
      #{calls}
      #{main_exit}
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
        active = current ? current['name'] : '<no active case>'
        raise "unexpected CLEAR lexer output while parsing #{active}: #{line}"
      end
    end

    cases
  end

  def parse_value(kind, value)
    case kind
    when 'nil' then nil
    when 'int', 'uint' then value.to_i
    when 'float' then [value.to_i].pack('Q<').unpack1('E')
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
      # Ruby stores every integer literal as a bignum ("int"); the CLEAR
      # lexer's literal domain is UInt64 ("uint"). Same value = same token.
      if ruby_token.is_a?(Hash) && clear_token.is_a?(Hash) &&
         %w[int uint].include?(ruby_token['kind'].to_s) && %w[int uint].include?(clear_token['kind'].to_s) &&
         ruby_token.merge('kind' => 'int') == clear_token.merge('kind' => 'int')
        next
      end

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
