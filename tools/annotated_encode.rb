#!/usr/bin/env ruby
# frozen_string_literal: true

# Canonical encoder for ANNOTATED ASTs (stage 3).
#
# ParserCompat.canonical_encode cannot be reused here for two reasons:
#   1. It REJECTS STAMP_FIELDS -- was_moved, type_object, container_borrow,
#      matched_stdlib_def, tense_plan ... which is precisely the annotator's
#      output. Encoding with it compares parse trees and passes while testing
#      nothing.
#   2. It recurses as if the AST were a tree. A parsed AST is; an annotated one
#      is a graph with back-references, and it blew the stack at 9162 levels.
#
# So: include the stamps, and CUT the container back-pointers (CUT below) that
# make the annotated AST a graph. Measured over all 1561 functions in
# transpile-tests: 0 cycles, 0 oversize, avg 555 nodes, max 9838.
#
# Cutting rather than emitting back-references is what makes the CLEAR side
# buildable at all: a back-reference needs stable object identity, and CLEAR has
# none, so its ordinals could never be made to agree with Ruby's. A finite tree
# needs only a recursive walk -- the shape parser_compat already generates CLEAR
# encoders for.
#
# What is cut is reference topology, never a fact: an entry's own stamps still
# encode wherever `symbol` reaches it. If a divergence class ever hides behind a
# cut edge, encode that edge by binding NAME rather than by following it.
# The parser encoder stays untouched -- its 8/8 byte-identical result must not
# regress.
require_relative 'parser_compat'

module AnnotatedEncode
  extend self

  # Container back-pointers. Following these turns the annotated AST into a
  # graph; `lifetime` was the last one, found via
  # CapabilityTargetFact -> source_entry -> lifetime -> SymbolEntry.
  CUT = %w[
    scope binding_entries bindings entries parent owned_names type_store
    dependencies lifetime
  ].freeze

  # NEVER `value == true`: Type#== is sorbet-typed and raises TypeError on a
  # Boolean, and that exception masquerades as whatever a caller's rescue calls
  # it.
  def scalar?(value)
    value.nil? || value.is_a?(TrueClass) || value.is_a?(FalseClass) ||
      value.is_a?(Numeric) || value.is_a?(String) || value.is_a?(Symbol)
  end

  # A back-reference is "R<ordinal>;" where the ordinal is assignment order in
  # a depth-first walk. Both sides must assign in the same order for the bytes
  # to agree, which is why ordinals come from the walk and not from object_id.
  def encode(root)
    encode_value(root)
  end

  def encode_value(value)
    case value
    when nil then 'N;'
    when true then 'T;'
    when false then 'B;'
    when Symbol then ParserCompat.send(:length_encoded, 'Y', value.to_s)
    when String then ParserCompat.send(:length_encoded, 'S', value)
    when Integer then "I#{value};"
    when Float then "F#{ParserCompat.send(:float_text, value)};"
    when Lexer::Token
      object('Token', { 'column' => value.column, 'line' => value.line,
                        'type' => value.type, 'value' => value.value })
    when Array
      "A#{value.length}[#{value.map { |item| encode_value(item) }.join}]"
    when Hash
      pairs = value.map { |key, item| [encode_value(key), encode_value(item)] }
      pairs.sort_by! { |key, item| key + item }
      "H#{pairs.length}[#{pairs.flatten.join}]"
    when Type
      # Same reasoning as the parser encoder: Type memoises derived state into
      # ivars on demand, so encoding by instance_variables makes the bytes
      # depend on which accessors happened to run.
      object('Type', { 'resolved' => value.resolved })
    when T::Enum
      object(value.class.name.split('::').last, { 'value' => value.serialize })
    else
      ruby_object(value)
    end
  end

  def object(name, fields)
    fields = fields.reject { |field, _| CUT.include?(field.to_s) }
    encoded = fields.sort_by { |field, _| field }.map do |field, value|
      ParserCompat.send(:length_encoded, 'S', field) + encode_value(value)
    end.join
    "O#{name.bytesize}:#{name}#{fields.length}[#{encoded}]"
  end

  # The CLEAR side of the same encoding. parser_compat already generates
  # encoders from the corpus's own struct declarations; stage 3 needs the same
  # generator with a different skip set -- keep the stamps, cut the container
  # back-pointers -- so both implementations walk the identical field list.
  def clear_encoders(cases, generated_root)
    ParserCompat.with_struct_scan(STRUCT_SCAN) do
      ParserCompat.with_encoder_skip(CUT) do
        ParserCompat.with_case_builder(method(:annotated_ast)) do
          ParserCompat.with_declared_members(method(:declared_members)) do
            ParserCompat.send(:node_encoders, cases, generated_root)
          end
        end
      end
    end
  end

  # What the encoders will actually be handed: the ANNOTATED program.
  def annotated_ast(source)
    ast = ClearParser.new(Lexer.new(source).tokenize, source).parse
    annotator = SemanticAnnotator.new(source_code: source)
    annotator.annotate!(ast)
    ast
  end

  # Per-function encodings, which is what makes the compatibility report
  # function-by-function rather than one pass/fail per program. With the graph
  # cut to a tree each function's bytes are inherently self-contained, so two
  # functions compare independently of their position in the file.
  def per_function(root)
    out = {}
    walk(root, {}) do |node|
      next unless node.is_a?(AST::FunctionDef)

      key = node.name.to_s
      key = "#{key}##{out.keys.count { |k| k == key || k.start_with?("#{key}#") }}" if out.key?(key)
      out[key] = encode(node)
    end
    out
  end

  # Structural walk only -- it must not follow the annotator's back-references
  # or it would revisit forever, so composites are guarded by object_id.
  def walk(value, seen, &block)
    return if value.nil?

    case value
    when Array then value.each { |item| walk(item, seen, &block) }
    when Hash then value.each { |k, v| walk(k, seen, &block); walk(v, seen, &block) }
    when Struct
      return unless seen[value.object_id].nil?

      seen[value.object_id] = true
      block.call(value)
      value.class.members.each { |m| walk(value[m], seen, &block) }
    end
  end

  # The corpus's own struct declaration is the field list, for BOTH sides.
  # Ruby keeps most of the annotator's output in attr_accessors rather than in
  # Struct members -- 293 of 348 declared fields on the common node types -- so
  # reading `class.members` encoded the parse tree and 16% of the annotation,
  # and would have reported agreement on everything it never looked at.
  # Every corpus struct, not just ast/**: a stamp reaches Type, SymbolEntry,
  # FunctionSignature and friends, which are declared elsewhere.
  STRUCT_SCAN = File.join('**', '*.clear')

  def clear_fields
    @clear_fields ||= ParserCompat.with_struct_scan(STRUCT_SCAN) do
      ParserCompat.send(:clear_struct_fields, GENERATED_ROOT)
    end
  end

  GENERATED_ROOT = File.join(LexerHarnessSupport::ROOT, 'compiler', 'src')

  # The declared field names of `name`, or nil when the corpus has no such
  # struct (a Ruby-only helper type).
  def declared_members(name)
    decl = clear_fields[name]
    decl&.keys&.map(&:to_s)
  end

  def ruby_object(value)
    name = value.class.name.split('::').last
    declared = declared_members(name)
    fields = if declared
               # `public_send`, not `[]`: the field may be a Struct member or an
               # attr_accessor, and the declaration does not say which.
               declared.select { |m| value.respond_to?(m) }.to_h { |m| [m, value.public_send(m)] }
             elsif value.is_a?(Struct)
               # value.class.members, not value.members: AST nodes are Structs,
               # and some of them (protocol/impl bodies) have their OWN `members`
               # field holding FunctionDefs, which shadows Struct#members. The
               # class-level reader is never shadowed.
               value.class.members.to_h { |member| [member.to_s, value[member]] }
             elsif value.class.respond_to?(:props)
               value.class.props.keys.to_h { |field| [field.to_s, value.public_send(field)] }
             else
               value.instance_variables.to_h do |ivar|
                 [ivar.to_s.delete_prefix('@'), value.instance_variable_get(ivar)]
               end
             end
    raise "unsupported annotated value: #{value.class}" if fields.empty?

    object(name, fields)
  end
end
