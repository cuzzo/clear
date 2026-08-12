#!/usr/bin/env ruby
# frozen_string_literal: true

begin
  require 'bundler/setup'
rescue LoadError
end

require 'fileutils'
require 'open3'
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
      corpus: 'smoke',
      generated_root: File.join(LexerHarnessSupport::ROOT, 'compiler', 'src')
    }

    OptionParser.new do |parser|
      parser.banner = 'Usage: ruby tools/parser_compat.rb [--out DIR] [--keep]'
      parser.on('--out DIR', 'Output directory for MessagePack artifacts') { |value| options[:out_dir] = File.expand_path(value) }
      parser.on('--corpus NAME', 'Corpus to run: smoke (default)') { |value| options[:corpus] = value }
      parser.on('--generated-root DIR', 'Root of the generated CLEAR tree to test') { |value| options[:generated_root] = File.expand_path(value) }
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
    when Type
      # Type memoizes derived state into ivars on demand, so encoding it by
      # instance_variables makes the bytes depend on which accessors happened
      # to run. Its resolved form is the stable identity both sides agree on.
      canonical_object('Type', { 'resolved' => value.resolved })
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

    # Annotator stamps are not parser output. The CLEAR encoder omits them by
    # construction; a Ruby Struct always carries its members, so drop them here
    # too or the two sides disagree on a field neither parser populates.
    fields = fields.reject { |field, _| STAMP_FIELDS.include?(field) }
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
    # A fresh mktmpdir per run gave the emitted Zig a new path every time, so
    # Zig's own cache never hit and every run paid the full link (tens of
    # minutes). One stable directory lets an unchanged harness reuse it.
    dir = File.join(options[:out_dir], 'build')
    FileUtils.mkdir_p(dir)
    begin
      source = File.join(dir, 'parser_compat.clear')
      binary = File.join(dir, 'parser_compat')
      File.write(source, clear_harness_source(cases, options[:generated_root]))

      env = {
        'CLEAR_DISABLE_BUILD_ZIG' => '1',
        'CLEAR_EXTRA_LINK_LIBS' => 'pcre2-8',
        'CLEAR_EXTRA_NATIVE_DIRS' => options[:generated_root]
      }
      LexerHarnessSupport.run!(
        LexerHarnessSupport::CLEAR, 'build', source,
        '-o', binary,
        '--no-stack-check',
        # Recursive descent over a union whose clone frame is megabytes: the
        # 64 KB debug default faults in the prologue.
        '--main-tier', 'service',
        # Zig's self-hosted x86_64 backend miscompiles the lexer's keyword
        # comparison after the first parse in a process, so `END` lexes as a
        # TYPE_ID and every parse but the first fails. Building through LLVM
        # is correct; drop this once the default backend is fixed.
        *ENV.fetch('PARSER_COMPAT_BUILD_FLAGS', '--safe').split,
        # '--force' removed: it defeated incremental compilation on every build
        *package_flags(options[:generated_root]),
        env: env
      )
      # A case that crashes the process (rather than raising) still produced
      # output for every case before it. Report those instead of losing the
      # whole run to one bad case.
      stdout, stderr, status = Open3.capture3(binary)
      stdout = stderr if stdout.empty?
      unless status.success?
        warn "parser_compat: CLEAR exited #{status.exitstatus || status.termsig}; reporting the cases it completed"
      end

      if options[:keep]
        FileUtils.cp(source, File.join(options[:out_dir], 'parser_compat.clear'))
        FileUtils.cp(binary, File.join(options[:out_dir], 'parser_compat'))
      end

      {
        'schema' => SCHEMA,
        'implementation' => 'clear',
        'cases' => parse_clear_output(stdout)
      }
    ensure
      FileUtils.rm_rf(dir) unless options[:keep] || ENV['PARSER_COMPAT_REUSE_BUILD']
    end
  end

  # Generated CLEAR REQUIREs each dependency as `pkg:rtoc_<hex of relative path>`,
  # so every file in the tree must be registered before the root will resolve.
  STDLIB_PACKAGES = { 'fs' => 'stdlib/fs/src/lib.clear', 'path' => 'stdlib/path/src/lib.clear' }.freeze

  def generated_relatives(generated_root)
    Dir[File.join(generated_root, '**/*.clear')].sort.map { |t| t.delete_prefix("#{generated_root}/") }
  end

  def package_name(relative)
    "rtoc_#{relative.unpack1('H*')}"
  end

  # Generated REQUIRE graph over the tree, keyed by relative path.
  #
  # ruby-to-clear emits two REQUIRE spellings: the older `pkg:rtoc_<hex>` form
  # and a plain relative path (`REQUIRE "../ast/type.clear"`). Reading only the
  # hex form leaves the graph almost edgeless, so no SCC is found, no multi-file
  # package is formed, and the compiler reports a raw circular dependency.
  def generated_graph(generated_root)
    present = generated_relatives(generated_root).to_h { |rel| [rel, true] }
    present.keys.to_h do |rel|
      dir = File.dirname(File.join(generated_root, rel))
      deps = File.read(File.join(generated_root, rel))
                 .scan(/REQUIRE\s+"([^"]+)"/).flatten
                 .filter_map { |spec| resolve_require(spec, dir, generated_root) }
                 .select { |dep| present[dep] && dep != rel }
                 .uniq
      [rel, deps]
    end
  end

  # A REQUIRE spec as a path relative to the generated root, or nil when it
  # names something outside the tree (a stdlib package).
  def resolve_require(spec, dir, generated_root)
    if spec.start_with?('pkg:rtoc_')
      [spec.delete_prefix('pkg:rtoc_')].pack('H*')
    elsif spec.end_with?('.clear')
      File.expand_path(spec, dir).delete_prefix("#{generated_root}/")
    end
  end

  # Mutually-referential generated modules must compile as ONE multi-file
  # package: CLEAR's acyclic-import rule applies between packages, not within
  # one. Each SCC larger than a single file becomes a package group.
  def package_groups(generated_root)
    graph = generated_graph(generated_root)
    groups = {}
    strongly_connected_components(graph).each do |component|
      next unless component.length > 1

      members = component.sort
      groups["scc_#{File.basename(members.fetch(0), '.clear')}_#{members.length}"] = members
    end
    groups
  end

  def strongly_connected_components(graph)
    index = {}
    low = {}
    on_stack = {}
    stack = []
    components = []
    counter = 0

    graph.each_key do |root_node|
      next if index.key?(root_node)

      work = [[root_node, 0]]
      until work.empty?
        node, child = work.last
        if child.zero?
          index[node] = counter
          low[node] = counter
          counter += 1
          stack.push(node)
          on_stack[node] = true
        end

        recursed = false
        neighbours = graph.fetch(node, [])
        while child < neighbours.length
          neighbour = neighbours[child]
          child += 1
          work[-1][1] = child
          unless index.key?(neighbour)
            work.push([neighbour, 0])
            recursed = true
            break
          end
          low[node] = [low[node], index[neighbour]].min if on_stack[neighbour]
        end
        next if recursed

        if low[node] == index[node]
          component = []
          loop do
            member = stack.pop
            on_stack.delete(member)
            component << member
            break if member == node
          end
          components << component
        end
        work.pop
        low[work.last[0]] = [low[work.last[0]], low[node]].min unless work.empty?
      end
    end
    components
  end

  def package_flags(generated_root)
    groups = package_groups(generated_root)
    generated = generated_relatives(generated_root).flat_map do |relative|
      ['--pkg', "#{package_name(relative)}=#{File.join(generated_root, relative)}"]
    end
    grouped = groups.flat_map do |name, members|
      spec = members.map { |rel| File.join(generated_root, rel) }.join(',')
      ['--pkg', "#{name}=#{spec}"]
    end
    stdlib = STDLIB_PACKAGES.flat_map do |name, path|
      ['--pkg', "#{name}=#{File.join(LexerHarnessSupport::ROOT, path)}"]
    end
    generated + grouped + stdlib
  end

  # The harness must enter the parser through whatever package actually owns
  # it: its SCC group when it is cyclic, otherwise the file itself.
  # Type lives in a different SCC group than the parser, so the harness has to
  # require it explicitly to call type__resolved.
  def type_require_spec(generated_root)
    group = package_groups(generated_root).find { |_name, members| members.include?('ast/type.clear') }
    group ? "pkg:#{group.first}" : File.join(generated_root, 'ast', 'type.clear')
  end

  # The lexer is its own package; the harness tokenizes before parsing.
  def lexer_require_spec(generated_root)
    group = package_groups(generated_root).find { |_name, members| members.include?('ast/lexer.clear') }
    group ? "pkg:#{group.first}" : "pkg:#{package_name('ast/lexer.clear')}"
  end

  def parser_require_spec(generated_root)
    group = package_groups(generated_root).find { |_name, members| members.include?('ast/parser.clear') }
    return "pkg:#{group.first}" if group

    File.join(generated_root, 'ast', 'parser.clear')
  end

  # --- generated node encoders -------------------------------------------
  #
  # The old hand-written encodeCompat() walked values with Ruby-style
  # reflection (`object.class().members()`), which CLEAR does not have, so it
  # never compiled. Instead, emit one encoder per node type: Ruby's Struct
  # members define WHICH fields are encoded (matching canonical_ruby_object)
  # and the CLEAR declarations define HOW each is encoded.

  STAMP_FIELDS = %w[
    can_fail coerced_type_object collection_return container_borrow error_kind
    error_type implicit_layout_cost kept_edge_plan kept_edge_plans
    layout_transport matched_signature matched_stdlib_def mutates_receiver
    needs_heap_create needs_mut_ref resource_close_plan slot_size source_range
    stdlib_allocates storage_override tense_plan type_object var_mutated
    var_used was_moved zig_pattern symbol generic_params
  ].freeze

  def clear_struct_fields(generated_root)
    @clear_struct_fields ||= begin
      table = {}
      Dir[File.join(generated_root, 'ast', '**', '*.clear')].each do |path|
        File.read(path).scan(/^(?:PUB )?STRUCT (\w+) \{(.*?)\n\}/m) do |name, body|
          # A field type can hold commas (`[]Tuple<A, B>`), so match to end of
          # line and drop the trailing separator instead of stopping at `,`.
          table[name] = body.scan(/^\s*(\w+):\s*(.+?),?\s*$/).to_h
        end
      end
      table
    end
  end

  # Union types the translated sources declare, as {name => [[variant, payload]]}.
  # A union encodes as its ACTIVE variant's payload, which is exactly what the
  # Ruby side wrote before the translation gave the slot a name.
  def clear_union_variants(generated_root)
    @clear_union_variants ||= begin
      table = {}
      # ast/ and the parser are the translation under test; a same-named union
      # elsewhere (mir/, semantic/) is a different type and would collide with
      # the struct encoder of that name.
      Dir[File.join(generated_root, 'ast', '**', '*.clear')].each do |path|
        File.read(path).scan(/^(?:PUB )?UNION (\w+) \{(.+?)\}$/) do |name, body|
          table[name] = body.split(',').filter_map do |pair|
            variant, payload = pair.split(':', 2).map(&:strip)
            [variant, payload] if variant && payload && !variant.empty?
          end
        end
      end
      table
    end
  end

  # Node classes actually produced by the corpus. Anything outside this set
  # gets a loud panic rather than a silently wrong encoding.
  # AST nodes are a mix of Ruby Structs and T::Structs.
  def struct_member_names(klass)
    klass.respond_to?(:members) ? klass.members.map(&:to_s) : klass.props.keys.map(&:to_s)
  end

  def corpus_node_classes(cases)
    seen = {}
    @never_populated = Hash.new { |h, k| h[k] = {} }
    walk = lambda do |value, guard|
      return if value.nil? || guard.include?(value.object_id)
      guard << value.object_id
      case value
      when Array then value.each { |item| walk.call(item, guard) }
      when Hash then value.each { |k, v| walk.call(k, guard); walk.call(v, guard) }
      when Lexer::Token then nil
      when Struct
        name = value.class.name.split('::').last
        seen[name] = value.class
        value.members.each do |m|
          @never_populated[name][m.to_s] = @never_populated[name].fetch(m.to_s, true) && value[m].nil?
          walk.call(value[m], guard)
        end
      when Type, T::Enum
        # Encoded by identity, not by walking their fields.
        nil
      when T::Struct
        # AST nodes are not all plain Structs -- EffectSpan is a T::Struct, and
        # missing it here marked the class dead, so the generated encoder was a
        # panic stub that fired the moment a case populated it.
        name = value.class.name.split('::').last
        seen[name] = value.class
        value.class.props.keys.each do |m|
          member = value.public_send(m)
          @never_populated[name][m.to_s] = @never_populated[name].fetch(m.to_s, true) && member.nil?
          walk.call(member, guard)
        end
      end
    end
    cases.each do |entry|
      ast = ClearParser.new(Lexer.new(entry['source']).tokenize, entry['source']).parse
      walk.call(ast, Set.new)
    end
    seen
  end

  def clear_base_type(type)
    type.to_s.sub(/@[\w:]+(\(\d+\))?/, '').strip
  end

  # Returns [prelude_statements, expression] encoding `expr`, which has
  # declared type `type`. Collections need a loop, so they emit a prelude.
  def clear_value_encoder(type, expr, fields, slot = 'v0')
    bare = clear_base_type(type)
    # A @boxed field holds its value indirectly (the AST's recursive edges are
    # boxed so Zig can size the types). Copy the pointee out before encoding --
    # the wire format describes the value, not the indirection.
    # Only when the indirection is on THIS value, not nested inside a
    # collection element -- `{String}T@multiowned` must recurse to the element,
    # not copy the whole map.
    if type.to_s =~ /\A\??[A-Za-z_][\w<>, ]*@boxed\z/
      return clear_value_encoder(bare, "COPY #{expr}", fields, slot)
    end
    # A retained handle needs OWN COPY: plain COPY is a memcpy and is illegal
    # on a live @multiowned value.
    if type.to_s =~ /\A\??[A-Za-z_][\w<>, ]*@multiowned\z/
      return clear_value_encoder(bare, "OWN COPY #{expr}", fields, slot)
    end

    # encodeTokenValue already takes the optional -- it is how Token#value is
    # encoded on both sides -- so do not unwrap it first.
    return ['', "encodeTokenValue(#{expr})"] if bare == '?TokenValue'

    if bare.start_with?('?')
      # Recurse on the ORIGINAL type minus the `?`, not on `bare`: clear_base_type
      # has already dropped the capability, and `?String@symbol` must still encode
      # as a symbol once unwrapped.
      pre, inner = clear_value_encoder(type.to_s.sub(/\A\?/, ''), "#{slot}_some", fields, "#{slot}i")
      body = pre.empty? ? "" : pre + "\n"
      return [
        "  MUTABLE #{slot} = \"N\";\n  IF #{expr} EXISTS AS #{slot}_some THEN\n#{body}    #{slot} = #{inner};\n  END",
        slot
      ]
    end

    # Ruby keys HashLit#pairs by AST node; CLEAR carries it as a list of pairs
    # (a map keyed by the recursive Locatable union closes a type cycle Zig
    # cannot size). The WIRE format stays Ruby's Hash encoding.
    if (tup = bare[/\A\[\]Tuple<(.+?),\s*(.+)>\z/, 0])
      kt = bare[/\A\[\]Tuple<(.+?),\s*(.+)>\z/, 1]
      vt = bare[/\A\[\]Tuple<(.+?),\s*(.+)>\z/, 2]
      kpre, kexp = clear_value_encoder(kt, "#{slot}_k", fields, "#{slot}k")
      vpre, vexp = clear_value_encoder(vt, "#{slot}_v", fields, "#{slot}v")
      kbody = kpre.empty? ? "" : kpre + "\n"
      vbody = vpre.empty? ? "" : vpre + "\n"
      return [
        "  MUTABLE #{slot}_pairs: String[] = [];\n" \
        "  MUTABLE #{slot}_n = 0;\n" \
        "  WHILE #{slot}_n < #{expr}.length() DO\n" \
        "    #{slot}_k, #{slot}_v = UNWRAP (#{expr}[#{slot}_n]);\n#{kbody}#{vbody}" \
        "    &#{slot}_pairs.append(#{kexp} $+ #{vexp});\n" \
        "    #{slot}_n += 1;\n" \
        "  END\n" \
        "  #{slot}_pairs = #{slot}_pairs |> ORDER_BY _;\n" \
        "  MUTABLE #{slot} = \"H\" $+ #{slot}_pairs.length().toString() $+ \"[\" $+ #{slot}_pairs.join(\"\") $+ \"]\";",
        slot
      ]
    end

    if (elem = bare[/\A\[\](.+)\z/, 1])
      pre, inner = clear_value_encoder(elem, "#{slot}_item", fields, "#{slot}i")
      body = pre.empty? ? "" : pre + "\n"
      return [
        "  MUTABLE #{slot} = \"A\" $+ #{expr}.length().toString() $+ \"[\";\n" \
        "  MUTABLE #{slot}_n = 0;\n" \
        "  WHILE #{slot}_n < #{expr}.length() DO\n" \
        "    #{slot}_item = #{expr}[#{slot}_n]?;\n#{body}" \
        "    #{slot} = #{slot} $+ #{inner};\n" \
        "    #{slot}_n += 1;\n" \
        "  END\n" \
        "  #{slot} = #{slot} $+ \"]\";",
        slot
      ]
    end

    # A `[Set]T` value has no canonical_encode case on the Ruby side, so there
    # is no wire format to match. Panic rather than invent one; the smoke
    # corpus leaves these slots empty, and a mismatch should be loud.
    if bare.start_with?('[Set]')
      return ["  panic(\"parser compat: no wire format for #{bare}\");", '""']
    end

    if (m = bare.match(/\A\{(.+?)\}(.+)\z/))
      kpre, kexp = clear_value_encoder(m[1], "#{slot}_k", fields, "#{slot}k")
      vpre, vexp = clear_value_encoder(m[2], "#{slot}_v", fields, "#{slot}v")
      kbody = kpre.empty? ? "" : kpre + "\n"
      vbody = vpre.empty? ? "" : vpre + "\n"
      return [
        "  MUTABLE #{slot}_pairs: String[] = [];\n" \
        "  #{expr}.keys() |> EACH {\n" \
        "    #{slot}_k = _;\n" \
        "    #{slot}_v = #{expr}[_]?;\n#{kbody}#{vbody}" \
        "    &#{slot}_pairs.append(#{kexp} $+ #{vexp});\n" \
        "  };\n" \
        "  #{slot}_pairs = #{slot}_pairs |> ORDER_BY _;\n" \
        "  MUTABLE #{slot} = \"H\" $+ #{slot}_pairs.length().toString() $+ \"[\" $+ #{slot}_pairs.join(\"\") $+ \"]\";",
        slot
      ]
    end

    simple =
      if bare == 'TokenValue' then "encodeTokenValue(#{expr})"
      elsif bare == 'Token' then "encodeToken(#{expr})"
      elsif bare == 'Type' then "encodeType(#{expr})"
      elsif bare == 'Locatable' then "encodeLocatable(#{expr})"
      elsif bare == 'ContractClauseValue' then "encodeContractClauseValue(#{expr})"
      elsif bare == 'PassStateValue' then "encodePassStateValue(#{expr})"
      elsif @generated_root && clear_union_variants(@generated_root).key?(bare)
        (@union_encoders_needed ||= Set.new) << bare
        "encode#{bare}(#{expr})"
      elsif type.to_s.include?('@symbol') then "lengthEncoded(\"Y\", CAST(#{expr} AS String))"
      elsif bare == 'String' then "lengthEncoded(\"S\", #{expr})"
      elsif %w[Int64 UInt64].include?(bare) then "(\"I\" $+ #{expr}.toString() $+ \";\")"
      elsif bare == 'Float64' then "(\"F\" $+ floatValueText(#{expr}) $+ \";\")"
      elsif bare == 'Bool' then "(IF #{expr} THEN \"B1\" ELSE \"B0\" END)"
      elsif fields.key?(bare) then "encode#{bare}(#{expr})"
      end

    simple ? ['', simple] : nil
  end

  def struct_class_for(name)
    [AST, Object].each do |scope|
      next unless scope.const_defined?(name, false)
      candidate = scope.const_get(name, false)
      next unless candidate.is_a?(Class)
      return candidate if candidate < Struct || candidate.respond_to?(:props)
    end
    nil
  end

  # An emitted encoder can reference a struct the corpus never instantiated
  # (an always-empty Capture list, say). Close over those so every referenced
  # type has an encoder.
  def close_over_referenced_types!(classes, fields)
    loop do
      added = false
      classes.keys.each do |name|
        (fields[name] || {}).each_value do |decl|
          base = clear_base_type(decl).sub(/\A\?/, '').sub(/\A\[\]/, '').sub(/\A\{[^}]*\}/, '')
          next if classes.key?(base) || !fields.key?(base)
          klass = struct_class_for(base)
          next unless klass
          classes[base] = klass
          (@closure_added ||= Set.new) << base
          added = true
        end
      end
      break unless added
    end
  end

  def node_encoders(cases, generated_root)
    @generated_root = generated_root
    fields = clear_struct_fields(generated_root)
    classes = corpus_node_classes(cases)
    close_over_referenced_types!(classes, fields)
    emitted = []
    unsupported = []

    classes.sort.each do |name, klass|
      decls = fields[name]
      next unless decls

      # Reached only through a collection the corpus never populates, so this
      # encoder is dead. Emit it so the referencing encoder compiles, and panic
      # rather than invent an encoding that was never exercised.
      if (@closure_added ||= Set.new).include?(name)
        emitted << "PRIVATE FN encode#{name}(node: #{name}) RETURNS String EFFECTS REENTRANT ->\n" \
                   "  panic(\"parser compat: #{name} reached but never encoded\");\n" \
                   "  RETURN \"\";\nEND"
        next
      end

      members = struct_member_names(klass).reject { |m| STAMP_FIELDS.include?(m) }.sort
      parts = members.each_with_index.map do |member, slot_index|
        decl = decls[member]
        pair = decl && clear_value_encoder(decl, "node.#{member}", fields, "f#{slot_index}")
        if pair.nil? && @never_populated[name][member]
          # The translation left this field untyped (Any) and the corpus never
          # populates it. Encode the nil Ruby also emits, but assert it rather
          # than assume -- a populated field must fail loudly, not silently
          # diverge.
          # `== NIL` on an `Any@multiowned` slot compares the PAYLOAD (Any
          # resolves to f64) rather than the optional, so ask with EXISTS.
          # A NON-optional untyped slot cannot be asked at all -- it always
          # holds something -- so encode the nil Ruby emits and say so.
          pair = if clear_base_type(decl).to_s.start_with?('?')
            ["  IF node.#{member} EXISTS AS untyped_#{member}_set THEN\n" \
             "    ASSERT FALSE, \"parser compat: #{name}.#{member} is populated but untyped\";\n" \
             "  END", '"N"']
          else
            ["  # #{name}.#{member} is untyped and non-optional: unaskable here.", '"N"']
          end
        end
        unless pair
          unsupported << "#{name}.#{member} (#{decl.inspect})"
          next nil
        end
        prelude, expr = pair
        line = "  out = out $+ lengthEncoded(\"S\", #{member.inspect}) $+ #{expr};"
        prelude.empty? ? line : "#{prelude}\n#{line}"
      end
      next if parts.any?(&:nil?)

      emitted << <<~FN.chomp
        PRIVATE FN encode#{name}(node: #{name}) RETURNS String EFFECTS REENTRANT ->
          MUTABLE out = "O#{name.bytesize}:#{name}#{members.length}[";
        #{parts.join("\n")}
          RETURN out $+ "]";
        END
      FN
    end

    raise "parser compat: cannot encode #{unsupported.join(', ')}" if unsupported.any?

    [emitted.join("\n\n"), [locatable_dispatch(classes.keys, fields, generated_root),
                             union_encoders(generated_root, fields, classes.keys.to_set)].reject(&:empty?).join("\n\n")]
  end

  # One encoder per declared union: dispatch on the active variant and encode
  # its payload. Locatable keeps its hand-written dispatch (it names every AST
  # node and only the corpus-reachable ones get encoders).
  def union_encoders(generated_root, fields, encodable)
    clear_union_variants(generated_root).filter_map do |name, variants|
      next if name == 'Locatable'
      next unless @union_encoders_needed&.include?(name)
      # A union that already carries a Locatable variant does not need a
      # per-node arm as well: encodeLocatable dispatches those. Keeping them
      # expands one encoder into ~130 arms and pulls in every node encoder.
      covers_nodes = variants.any? { |_, payload| payload == 'Locatable' }
      node_variants = covers_nodes ? locatable_variants(generated_root) : Set.new
      arms = variants.filter_map do |variant, payload|
        next if covers_nodes && node_variants.include?(payload)
        # A variant the corpus never produces has no encoder to call. Leaving
        # its arm out drops it into the panic below, which is the same contract
        # the never-populated struct encoders use.
        bare = payload.sub(/\A\?/, '').sub(/\A\[\]/, '').sub(/\A\{[^}]*\}/, '').sub(/@\w+\z/, '')
        next if fields.key?(bare) && !encodable.include?(bare)
        slot = "u_#{name.downcase}_#{variant.downcase}"
        pre, expr = clear_value_encoder(payload, slot, fields, "u#{name}#{variant}")
        next if expr.nil?
        body = pre.to_s.empty? ? "" : "#{pre}\n"
        "  IF node IS_A #{name}.#{variant} AS #{slot} THEN\n#{body}    RETURN #{expr};\n  END"
      end
      "PRIVATE FN encode#{name}(node: #{name}) RETURNS String EFFECTS REENTRANT ->\n" \
        "#{arms.join("\n")}\n" \
        "  panic(\"parser compat: unsupported #{name} variant\");\nEND"
    end.join("\n\n")
  end

  def locatable_variants(generated_root)
    src = File.read(File.join(generated_root, 'ast', 'ast.clear'))
    src[/^(?:PUB )?UNION Locatable \{(.*?)\}/m, 1].to_s.scan(/(\w+):/).flatten.to_set
  end

  def locatable_dispatch(names, fields, generated_root)
    variants = locatable_variants(generated_root)
    arms = names.select { |n| fields.key?(n) && variants.include?(n) }.sort.map do |n|
      "  IF node IS_A Locatable.#{n} AS item THEN RETURN encode#{n}(item); END"
    end
    <<~FN.chomp
      PRIVATE FN encodeLocatable(node: Locatable) RETURNS String EFFECTS REENTRANT ->
      #{arms.join("\n")}
        panic("parser compat: unsupported AST node");
      END

      PRIVATE FN encodePassStateValue(node: PassStateValue) RETURNS String EFFECTS REENTRANT ->
        panic("parser compat: pass state reached but never populated by the parser");
      END

      PRIVATE FN encodeContractClauseValue(node: ContractClauseValue) RETURNS String EFFECTS REENTRANT ->
        IF node IS_A String AS text THEN RETURN lengthEncoded("S", text); END
        IF node IS_A Locatable AS item THEN RETURN encodeLocatable(item); END
        panic("parser compat: unsupported contract clause value");
      END
    FN
  end

  def clear_harness_source(cases, generated_root)
    parser_path = parser_require_spec(generated_root)
    type_path = type_require_spec(generated_root)
    lexer_path = lexer_require_spec(generated_root)
    encoders, dispatch = node_encoders(cases, generated_root)
    node_encoders_source = "#{encoders}\n\n#{dispatch}\n"

    calls = cases.each_with_index.map do |entry, index|
      "  dumpCase(#{LexerHarnessSupport.clear_string_expr(entry['source'])}, #{index}, #{LexerHarnessSupport.clear_string_expr(entry['name'])}) OR_ELSE reportCaseFailure(#{index}, #{LexerHarnessSupport.clear_string_expr(entry['name'])});"
    end.join("\n")

    <<~CLEAR
      REQUIRE #{LexerHarnessSupport.clear_string_literal(parser_path)};
      REQUIRE #{LexerHarnessSupport.clear_string_literal(type_path)};
      REQUIRE #{LexerHarnessSupport.clear_string_literal(lexer_path)};

      PRIVATE FN escapeCompat(value: String) RETURNS String ->
        MUTABLE out = "";
        MUTABLE i = 0;
        WHILE i < value.length() DO
          MUTABLE ch = value.charAt(i);
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

      PRIVATE FN encodeTokenValue(value: ?TokenValue) RETURNS String ->
        IF value EXISTS AS payload THEN
          IF payload IS_A TokenValue.StringValue AS item THEN RETURN lengthEncoded("S", item); END
          IF payload IS_A TokenValue.Int64Value AS item THEN RETURN "I" $+ item.toString() $+ ";"; END
          IF payload IS_A TokenValue.Float64Value AS item THEN RETURN "F" $+ floatValueText(item) $+ ";"; END
          IF payload IS_A TokenValue.BoolValue AS item THEN RETURN IF item THEN "B1" ELSE "B0" END; END
        END
        RETURN "N";
      END

      PRIVATE FN encodeType(value: Type) RETURNS String ->
        RETURN "O4:Type1[" $+ lengthEncoded("S", "resolved") $+
          lengthEncoded("Y", CAST(type__resolved(value) AS String)) $+ "]";
      END

      PRIVATE FN encodeToken(token: Token) RETURNS String ->
        RETURN "O5:Token4[" $+
          lengthEncoded("S", "column") $+ "I" $+ token.column.toString() $+ ";" $+
          lengthEncoded("S", "line") $+ "I" $+ token.line.toString() $+ ";" $+
          lengthEncoded("S", "type") $+ lengthEncoded("Y", token.type) $+
          lengthEncoded("S", "value") $+ encodeTokenValue(token.value) $+
          "]";
      END

#{node_encoders_source}
      # One failing case used to abort the whole run, hiding every case after it.
      PRIVATE FN reportCaseFailure(index: Int64, name: String) RETURNS Void ->
        print("CASE|" $+ index.toString() $+ "|" $+ escapeCompat(name) $+ "|error|parse_failed");
        print("ENDCASE");
        RETURN;
      END
      PRIVATE FN dumpCase(source: String@raw, index: Int64, name: String) RETURNS !Void ->
        program = clearParser__parse_source(CAST(source AS String)) OR_ELSE RAISE;
        print("CASE|" $+ index.toString() $+ "|" $+ escapeCompat(name) $+ "|ok|");
        print("AST|" $+ escapeCompat(encodeProgram(program)));
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
      when /\A\[Scheduler\]/, /\A(Segmentation fault|thread \d+ panic|Aborted)/
        # The CLEAR side aborted partway -- a scheduler error, or a crash that
        # takes the process down. Report what it DID produce so the cases that
        # work can still be byte-compared.
        warn "parser_compat: CLEAR aborted after #{cases.length} case(s): #{line}"
        break
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
