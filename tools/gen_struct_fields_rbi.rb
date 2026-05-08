#!/usr/bin/env ruby
# Generate sorbet/rbi/ast-struct-fields.rbi.
#
# Sorbet auto-types `Struct.new(:foo, :bar)` accessors as T.untyped,
# which means typed-true source code can never get dead-check signals
# (7034 / 7016) on patterns like `node.token&.line` -- Sorbet has
# nothing to compare against. RBI overrides DO take precedence over
# Struct's auto-generated sigs (verified in a sandbox), so this
# generator emits a per-class override declaring each Struct field.
#
# Two-level policy:
#
#   1. Field type (TYPE_POLICY, by field name):
#        :token  -> Token
#        :args   -> T::Array[T.untyped]
#        ...
#        unmapped -> T.untyped (no nilability fire from Sorbet anyway)
#
#   2. Nilability (per-(class, field), from construction-site prover):
#        prover says NON_NIL  -> emit `Type` directly (fires 7034 on dead &.)
#        prover says NILABLE  -> emit `T.nilable(Type)`
#        prover says UNTESTED -> emit `T.nilable(Type)` (conservative)
#
# Output is written to sorbet/rbi/ast-struct-fields.rbi. The prover
# is tools/struct_field_nilability.rb -- run it first to refresh data.
#
# Usage:
#   bundle exec ruby tools/struct_field_nilability.rb > /tmp/nilability.tsv
#   bundle exec ruby tools/gen_struct_fields_rbi.rb > sorbet/rbi/ast-struct-fields.rbi

require 'prism'

# field_name (Symbol) -> sig return type (String, ready to splice
# inside `sig { returns(...) }`).
TYPE_POLICY = {
  token:        'Token',
  args:         'T::Array[T.untyped]',
  body:         'T::Array[T.untyped]',
  items:        'T::Array[T.untyped]',
  branches:     'T::Array[T.untyped]',
  cases:        'T::Array[T.untyped]',
  arms:         'T::Array[T.untyped]',
  # :fields varies between Hash and Array per class — leave T.untyped.
  params:       'T::Array[T.untyped]',
  type_params:  'T::Array[T.untyped]',
  pairs:        'T::Array[T.untyped]',
  statements:   'T::Array[T.untyped]',
  captures:     'T::Array[T.untyped]',
  capabilities: 'T::Array[T.untyped]',
}.freeze

# Per-(class, field) overrides for fields whose type varies by class.
# Falls back to TYPE_POLICY (global by field name), then DEFAULT_TYPE.
PER_CLASS_POLICY = {
  # Identifier.name is always a String (from token.value or string interp).
  # Other AST nodes' :name fields can be GetIndex / GetField / etc., so
  # they stay T.untyped until per-call narrowing is feasible.
  ['AST::Identifier', :name] => 'String',
  # LambdaLit's body is a single expression (parse_expression), not an
  # Array — overriding the global :body => T::Array policy.
  ['AST::LambdaLit', :body] => 'T.untyped',
  # HashLit's pairs is a Hash (constructed via pairs.to_h), not an Array.
  ['AST::HashLit', :pairs] => 'T::Hash[T.untyped, T.untyped]',
}.freeze
DEFAULT_TYPE = 'T.untyped'

# Load the prover output if present. Format is TSV: class \t idx \t
# field \t nil_count \t nonnil_count \t verdict.
PROVER_PATH = '/tmp/nilability.tsv'
proven_non_nil = {}  # [class_path, field_sym] => true
if File.exist?(PROVER_PATH)
  File.readlines(PROVER_PATH).drop(1).each do |line|
    cls, _idx, field, _nl, _nn, verdict = line.chomp.split("\t")
    proven_non_nil[[cls, field.to_sym]] = true if verdict == 'NON_NIL'
  end
  warn "Loaded #{proven_non_nil.size} (class, field) NON_NIL proofs from #{PROVER_PATH}"
else
  warn "WARNING: #{PROVER_PATH} not found. All fields will be T.nilable. " \
       "Run tools/struct_field_nilability.rb first."
end

# class_path (String) -> Array<Symbol> of Struct field names in order.
discovered = {}

walk = nil
walk = lambda do |node, scope|
  return unless node
  case node
  when Prism::ModuleNode, Prism::ClassNode
    name = node.constant_path.is_a?(Prism::ConstantReadNode) ? node.constant_path.name : node.constant_path.full_name
    walk.(node.body, scope + [name.to_s])
    return # body already walked with namespaced scope; don't double-walk
  when Prism::ConstantWriteNode
    if node.value.is_a?(Prism::CallNode) &&
       node.value.name == :new &&
       node.value.receiver.is_a?(Prism::ConstantReadNode) &&
       node.value.receiver.name == :Struct
      class_path = (scope + [node.name.to_s]).join('::')
      args = node.value.arguments&.arguments || []
      fields = args.filter_map do |a|
        a.value.to_sym if a.is_a?(Prism::SymbolNode)
      end
      discovered[class_path] = fields if fields.any?
    end
  when Prism::DefNode
    return
  end
  if node.respond_to?(:child_nodes)
    node.child_nodes.compact.each { |c| walk.(c, scope) }
  end
end

# Walk only the AST and schemas source files. Other Struct.new calls
# elsewhere in src/ (helpers, tools) don't need typed Struct fields
# yet -- adding them later is a one-line change to the glob.
SOURCES = %w[src/ast/ast.rb src/ast/schemas.rb].freeze

SOURCES.each do |f|
  parsed = Prism.parse_file(f)
  next unless parsed.success?
  walk.(parsed.value, [])
end

warn "Struct-field RBI: #{discovered.size} classes, #{discovered.values.map(&:size).sum} fields"

puts <<~HDR
  # typed: true
  # frozen_string_literal: true
  #
  # AUTO-GENERATED. Do not edit by hand. Regenerate with:
  #   bundle exec ruby tools/gen_struct_fields_rbi.rb > sorbet/rbi/ast-struct-fields.rbi
  #
  # Sorbet auto-types `Struct.new(:foo, :bar)` accessors as T.untyped,
  # which masks nil-safety errors. This shim declares typed sigs for
  # each Struct field so dead `&.` and `.nil?` checks become 7034
  # signals.
  #
  # Type policy is encoded in tools/gen_struct_fields_rbi.rb's
  # TYPE_POLICY table. Initial pass tightens only :token (the most
  # common attr). Other fields default to T.untyped and can be
  # ratcheted up by extending the policy.

HDR

discovered.keys.sort.each do |cls|
  fields = discovered[cls]
  next if fields.empty?
  puts "class #{cls}"
  fields.each do |field|
    base_type = PER_CLASS_POLICY[[cls, field]] || TYPE_POLICY.fetch(field, DEFAULT_TYPE)
    # T.untyped already accepts nil; wrapping it adds nothing.
    # Otherwise wrap in T.nilable unless the prover proved non-nil.
    type = if base_type == 'T.untyped' || proven_non_nil[[cls, field]]
             base_type
           else
             "T.nilable(#{base_type})"
           end
    puts "  sig { returns(#{type}) }"
    puts "  def #{field}; end"
  end
  puts "end"
  puts
end
