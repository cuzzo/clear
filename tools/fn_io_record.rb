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
  def clear_name_to_ruby(name)
    owner, method = name.split('__', 2)
    return nil unless method

    const = owner[0].upcase + owner[1..]
    [const, method]
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
  def clear_literal(value, depth = 0, seen = {})
    return nil if depth > 6

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
      items.any?(&:nil?) ? nil : "[#{items.join(', ')}]"
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
        else return nil
        end
      parts = fields.map do |f, v|
        lit = clear_literal(v, depth + 1, seen)
        lit ? "#{f}: #{lit}" : nil
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
      short, method = pair
      owner = resolve_owner(short) or next
      target =
        if owner.respond_to?(method, true) then owner.singleton_class
        elsif owner.is_a?(Class) && owner.method_defined?(method) then owner
        elsif owner.is_a?(Module) && owner.instance_methods(false).include?(method.to_sym) then owner
        end
      next unless target
      next unless target.method_defined?(method) || target.private_method_defined?(method)

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
