#!/usr/bin/env ruby
# frozen_string_literal: true

# Record what every annotator function is GIVEN and what it RETURNS, over a
# corpus, straight out of the Ruby compiler.
#
# A function that compiles says nothing about whether it behaves. This captures
# the oracle: for each Ruby method the self-hosted tree mirrors, every
# (arguments, result) pair the real compiler produced. Values are encoded with
# parser_compat's canonical encoder, which handles any Ruby object by
# reflection, so AST nodes, Types and SymbolEntries record as faithfully as
# scalars.
#
#   ruby tools/fn_io_record.rb --corpus transpile-tests --out tmp/fn-io
#
# The output is one JSONL row per call: {fn, args, result}. `--summary` reports
# how many distinct functions were exercised, which is the denominator for
# "what percentage actually works".
require 'json'
require 'fileutils'
require 'optparse'
require 'set'

saved = $PROGRAM_NAME
$PROGRAM_NAME = 'fn_io_record_support'
require_relative 'parser_compat'
$PROGRAM_NAME = saved

module FnIoRecord
  extend self

  ROOT = File.expand_path('..', __dir__)
  SRC = File.join(ROOT, 'compiler', 'src')

  # `camelCaseOwner__method` is how rtoc names a method of `CamelCaseOwner`.
  # The owner is resolved against the Ruby constants actually loaded.
  # rtoc renders a Ruby bang as `_mut`, so `stamp_type!` arrives as
  # `stamp_type_mut` and never matches a live method. That is most of the
  # annotator: without the bang form the oracle only ever saw the handful of
  # non-mutating entry points.
  def clear_name_to_ruby(name)
    owner, method = name.split('__', 2)
    return nil unless method

    const = owner[0].upcase + owner[1..]
    candidates = [method]
    candidates << "#{method.delete_suffix('_mut')}!" if method.end_with?('_mut')
    [const, candidates]
  end

  def scc_functions
    group = ParserCompat.package_groups(SRC).max_by { |_n, m| m.length }.last
    group.flat_map do |rel|
      File.read(File.join(SRC, rel)).scan(/^(?:PUB |PRIVATE )?FN ([\w?!]+)/).flatten
    end.uniq
  end

  # Find the Ruby class or module a CLEAR owner name refers to, wherever it
  # lives in the compiler's namespaces.
  def resolve_owner(short)
    @owners ||= begin
      seen = {}
      walk = lambda do |mod, depth|
        return if depth > 4

        mod.constants(false).each do |c|
          value = begin
            mod.const_get(c, false)
          rescue StandardError
            next
          end
          next unless value.is_a?(Module)

          seen[c.to_s] ||= value
          walk.call(value, depth + 1) unless value.name.to_s.start_with?('T::')
        end
      end
      walk.call(Object, 0)
      seen
    end
    @owners[short]
  end

  RECORDED = Hash.new { |h, k| h[k] = [] }
  LIMIT_PER_FN = 40

  MAX_DEPTH = 14

  # An ANNOTATED AST is cyclic -- a symbol entry points back at the node that
  # declared it -- so the parser's encoder cannot walk it directly. Bound the
  # depth and remember what is already on the stack; a revisit encodes as a
  # back-reference, which is stable between runs because the walk order is.
  def encode(value, depth = 0, seen = {})
    return 'DEPTH' if depth > MAX_DEPTH

    case value
    when nil, true, false, Symbol, String, Integer, Float
      ParserCompat.canonical_encode(value)
    when Array
      "A#{value.length}[#{value.map { |v| encode(v, depth + 1, seen) }.join}]"
    when Hash
      pairs = value.map { |k, v| [encode(k, depth + 1, seen), encode(v, depth + 1, seen)] }
      pairs.sort_by! { |k, v| k + v }
      "H#{pairs.length}[#{pairs.flatten.join}]"
    else
      key = value.object_id
      return "R#{seen[key]}" if seen.key?(key)

      seen = seen.merge(key => seen.length)
      fields =
        if value.is_a?(Struct) then value.members.to_h { |m| [m.to_s, value[m]] }
        elsif value.class.respond_to?(:props) then value.class.props.keys.to_h { |n| [n.to_s, safe_send(value, n)] }
        else value.instance_variables.to_h { |iv| [iv.to_s.delete_prefix('@'), value.instance_variable_get(iv)] }
        end
      name = value.class.name.to_s.split('::').last
      body = fields.sort_by(&:first).map { |f, v| "S#{f.bytesize}:#{f}#{encode(v, depth + 1, seen)}" }.join
      "O#{name.bytesize}:#{name}#{fields.length}[#{body}]"
    end
  rescue StandardError, SystemStackError => e
    "UNENCODABLE:#{e.class}"
  end

  # The same value as CLEAR source, so a probe can reconstruct the argument
  # Ruby was given. Anything that cannot be written as a literal -- a cycle, a
  # closure, a depth cutoff -- becomes NIL and the caller skips that call.
  # An AST node nests several layers deep before it bottoms out in tokens and
  # Types, so the old depth of 6 cut off most arguments mid-render.
  # The generated tree is the authority on what a field holds. A Ruby value
  # whose class is a variant of the field's declared UNION has to be written as
  # `Union{ Variant: <payload> }`; emitting the bare payload is a
  # FIELD_TYPE_MISMATCH, which was most of what stage 3 could not build.
  def schema
    @schema ||= begin
      structs = Hash.new { |h, k| h[k] = {} }
      unions = Hash.new { |h, k| h[k] = {} }
      Dir.glob(File.join(SRC, '**', '*.clear')).each do |f|
        text = File.read(f)
        # A declaration can span lines (STRUCT Token spells one field per
        # line), so take the body by balancing braces rather than by matching
        # to the end of the line.
        text.to_enum(:scan, /^(?:PUB |PRIVATE )?(STRUCT|UNION) (\w+)[^{\n]*\{/).each do
          kind, name = Regexp.last_match(1), Regexp.last_match(2)
          i = Regexp.last_match.end(0)
          depth = 1
          body = +''
          while i < text.length && depth.positive?
            ch = text[i]
            depth += 1 if ch == '{'
            depth -= 1 if ch == '}'
            body << ch if depth.positive?
            i += 1
          end
          into = kind == 'STRUCT' ? structs[name] : unions[name]
          # A declaration body carries comment lines; without dropping them the
          # comment text parses as a field and shadows the real one.
          body = body.lines.reject { |l| l.strip.start_with?('#') }.join
          split_fields(body).each do |part|
            field, type = part.split(':', 2)
            next unless field

            into[field.strip] = (type || field).strip
          end
        end
      end
      [structs, unions]
    end
  end

  # A field type can carry commas of its own ({String@symbol}Type, [4]Int64),
  # so only top-level commas separate declarations.
  def split_fields(body)
    out = []
    depth = 0
    current = +''
    body.each_char do |ch|
      case ch
      when '{', '[', '(' then depth += 1
      when '}', ']', ')' then depth -= 1
      end
      if ch == ',' && depth.zero?
        out << current
        current = +''
      else
        current << ch
      end
    end
    out << current
    out.reject { |p| p.strip.empty? }
  end

  # A Ruby scalar's CLEAR spelling. Matching on the Ruby class name alone sends
  # a Symbol to no variant at all (CLEAR spells it String@symbol) and a String
  # to whichever String-ish variant is declared first, symbol or not.
  CLEAR_TYPE_OF = {
    'Symbol' => 'String@symbol',
    'String' => 'String',
    'Integer' => 'Int64',
    'Float' => 'Float64',
    'TrueClass' => 'Bool',
    'FalseClass' => 'Bool',
  }.freeze

  # The variant of `union_name` whose payload type is `class_name`, if any.
  def variant_for(union_name, class_name)
    _structs, unions = schema
    variants = unions[union_name]
    return nil if variants.nil? || variants.empty?
    return class_name if variants.key?(class_name)

    wanted = CLEAR_TYPE_OF[class_name] || class_name
    exact = variants.find { |_v, t| t.delete_prefix('?') == wanted }
    return exact.first if exact

    # Only then fall back to ignoring capabilities, so String never lands on a
    # String@symbol variant while a plain String variant exists.
    variants.find { |_v, t| t.sub(/@\w+\z/, '').delete_prefix('?') == wanted }&.first
  end

  def wrap_for_field(owner_class, field, value, literal, depth = 0, seen = {})
    structs, _unions = schema
    declared = structs[owner_class] && structs[owner_class][field]
    return literal unless declared

    bare = declared.delete_prefix('?').sub(/@\w+\z/, '')
    # A collection field declares its ELEMENT type; the wrap belongs on each
    # element, not on the map or list as a whole.
    if (elem = element_type(bare))
      return render_collection(value, elem, depth, seen) || literal
    end

    variant = variant_for(bare, value.class.name.to_s.split('::').last)
    variant ? "#{bare}{ #{variant}: #{literal} }" : literal
  end

  # `{K}V`, `HashMap<K,V>`, `[]T` and `[Set]T` all name an element type.
  def element_type(type)
    case type
    when /\A\{[^}]*\}(.+)\z/ then Regexp.last_match(1)
    when /\AHashMap<[^,]+,\s*(.+)>\z/ then Regexp.last_match(1)
    when /\A\[\](.+)\z/, /\A\[Set\](.+)\z/ then Regexp.last_match(1)
    end
  end

  def render_collection(value, elem_type, depth, seen)
    bare = elem_type.delete_prefix('?').sub(/@\w+\z/, '')
    wrap = lambda do |v|
      lit = clear_literal(v, depth + 1, seen)
      return nil unless lit

      variant = variant_for(bare, v.class.name.to_s.split('::').last)
      variant ? "#{bare}{ #{variant}: #{lit} }" : lit
    end
    case value
    when Hash
      pairs = value.map do |k, v|
        kk = clear_literal(k, depth + 1, seen)
        vv = wrap.call(v)
        kk && vv ? "#{kk}: #{vv}" : nil
      end
      pairs.any?(&:nil?) ? nil : "{#{pairs.join(', ')}}"
    when Array
      items = value.map { |v| wrap.call(v) }
      if items.any?(&:nil?) then nil
      elsif items.empty? then 'List[]'
      else "[#{items.join(', ')}]"
      end
    end
  end

  def clear_literal(value, depth = 0, seen = {})
    return nil if depth > 14

    case value
    when nil then 'NIL'
    when true then 'TRUE'
    when false then 'FALSE'
    when Integer then value.to_s
    when Float then format('%f', value)
    when Symbol then ":#{value}"
    when String then value.inspect
    when Array
      items = value.map { |v| clear_literal(v, depth + 1, seen) }
      # An empty list literal is `List[]` in CLEAR; a bare `[]` does not parse.
      if items.any?(&:nil?) then nil
      elsif items.empty? then 'List[]'
      else "[#{items.join(', ')}]"
      end
    when Set
      items = value.map { |v| clear_literal(v, depth + 1, seen) }
      if items.any?(&:nil?) then nil
      elsif items.empty? then 'Set[]'
      else "Set[#{items.join(', ')}]"
      end
    when Hash
      pairs = value.map do |k, v|
        kk = clear_literal(k, depth + 1, seen)
        vv = clear_literal(v, depth + 1, seen)
        kk && vv ? "#{kk}: #{vv}" : nil
      end
      pairs.any?(&:nil?) ? nil : "{#{pairs.join(', ')}}"
    else
      return nil if seen.key?(value.object_id)

      seen = seen.merge(value.object_id => true)
      fields =
        if value.is_a?(Struct) then value.members.to_h { |m| [m.to_s, value[m]] }
        elsif value.class.respond_to?(:props) then value.class.props.keys.to_h { |n| [n.to_s, safe_send(value, n)] }
        # Type, SymbolEntry and friends are plain classes -- neither a Struct
        # nor a T::Struct -- and bailing here is what made nearly every
        # annotator argument unrenderable, so stage 3 had nothing to replay.
        # rtoc derives the CLEAR struct's fields from these same ivars.
        elsif !value.instance_variables.empty?
          value.instance_variables.to_h { |iv| [iv.to_s.delete_prefix('@'), value.instance_variable_get(iv)] }
        else return nil
        end
      # Ruby carries ivars the generated struct never declared. Emitting them
      # is a "has no field" error, and the struct literal has to name every
      # declared field anyway -- so the CLEAR declaration is the authority.
      declared_fields = schema[0][value.class.name.to_s.split('::').last]
      fields = fields.select { |f, _| declared_fields.key?(f) } if declared_fields&.any?
      owner_class = value.class.name.to_s.split('::').last
      parts = fields.map do |f, v|
        lit = clear_literal(v, depth + 1, seen)
        lit ? "#{f}: #{wrap_for_field(owner_class, f, v, lit, depth, seen)}" : nil
      end
      return nil if parts.any?(&:nil?)

      "#{value.class.name.to_s.split('::').last}{ #{parts.join(', ')} }"
    end
  rescue StandardError, SystemStackError
    nil
  end

  def safe_send(value, name)
    value.public_send(name)
  rescue StandardError
    nil
  end

  def install(names)
    installed = 0
    names.each do |clear_name|
      pair = clear_name_to_ruby(clear_name) or next
      short, candidates = pair
      owner = resolve_owner(short) or next
      method = nil
      target = nil
      candidates.each do |cand|
        t =
          if owner.respond_to?(cand, true) then owner.singleton_class
          elsif owner.is_a?(Class) && owner.method_defined?(cand) then owner
          elsif owner.is_a?(Module) && owner.instance_methods(false).include?(cand.to_sym) then owner
          end
        next unless t
        next unless t.method_defined?(cand) || t.private_method_defined?(cand)

        method = cand
        target = t
        break
      end
      next unless target

      # An instance method's receiver is implicit in Ruby and explicit in CLEAR:
      # `annotationProducts__complete?(self: AnnotationProducts)`. Record it as
      # the first argument or every replay is an arity mismatch.
      instance_method = target != owner.singleton_class
      recorder = Module.new do
        define_method(method) do |*args, **kwargs, &blk|
          result = super(*args, **kwargs, &blk)
          bucket = FnIoRecord::RECORDED[clear_name]
          if bucket.length < FnIoRecord::LIMIT_PER_FN
            args = [self] + args if instance_method
            bucket << { args: args.map { |a| FnIoRecord.encode(a) },
                        args_clear: args.map { |a| FnIoRecord.clear_literal(a) },
                        kwargs: kwargs.transform_values { |v| FnIoRecord.encode(v) },
                        result: FnIoRecord.encode(result),
                        result_class: result.class.name.to_s.split('::').last }
          end
          result
        end
      end
      target.prepend(recorder)
      installed += 1
    end
    installed
  end

  def main(argv)
    corpus = File.join(ROOT, 'transpile-tests')
    out = File.join(ROOT, 'tmp', 'fn-io')
    limit_files = 12
    OptionParser.new do |p|
      p.on('--corpus DIR') { |v| corpus = File.expand_path(v) }
      p.on('--out DIR') { |v| out = File.expand_path(v) }
      p.on('--files N', Integer) { |v| limit_files = v }
    end.parse!(argv)

    require_relative '../compiler/ruby/ast/lexer'
    require_relative '../compiler/ruby/ast/parser'
    require_relative '../compiler/ruby/annotator/annotator'
    require_relative '../compiler/ruby/compiler/module_importer'
    # The owners are resolved against loaded constants, so everything the SCC
    # mirrors has to be in memory before hooks go on.
    %w[mir/mir_lowering mir/mir_checker mir/mir_pass mir/hoist mir/control_flow
       mir/cleanup_classifier mir/fsm_transform mir/test_lowering
       semantic/escape_analysis semantic/ownership_graph backends/transpiler
       backends/mir_emitter].each do |rel|
      begin
        require_relative "../compiler/ruby/#{rel}"
      rescue LoadError, StandardError
        next
      end
    end

    names = scc_functions
    installed = install(names)
    warn "hooked #{installed} of #{names.length} SCC function names onto live Ruby methods"

    sources = Dir.glob(File.join(corpus, '**', '*.clear')).sort.first(limit_files)
    ok = 0
    sources.each do |path|
      text = File.read(path)
      begin
        ast = ClearParser.new(Lexer.new(text).tokenize, text).parse
        dir = File.dirname(File.expand_path(path))
        importer = ModuleImporter.new(base_dir: dir, use_mir: true)
        SemanticAnnotator.new(importer: importer, source_dir: dir).annotate!(ast)
        ok += 1
      rescue StandardError, SystemStackError => e
        warn "  skip #{File.basename(path)}: #{e.class}: #{e.message.to_s.lines.first.to_s.strip[0, 90]}"
        next
      end
    end
    warn "annotated #{ok}/#{sources.length} corpus files"

    FileUtils.mkdir_p(out)
    File.open(File.join(out, 'calls.jsonl'), 'w') do |f|
      RECORDED.each { |fn, rows| rows.each { |r| f.puts JSON.generate(r.merge(fn: fn)) } }
    end
    total = RECORDED.values.sum(&:length)
    puts "#{RECORDED.length} functions exercised, #{total} recorded calls"
    puts "wrote #{File.join(out, 'calls.jsonl')}"
    0
  end
end

exit(FnIoRecord.main(ARGV)) if $PROGRAM_NAME.end_with?('fn_io_record.rb')
