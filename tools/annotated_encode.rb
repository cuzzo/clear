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
# So: include the stamps, and give every composite an identity so a revisit
# emits a back-reference instead of recursing. The parser encoder stays
# untouched -- its 8/8 byte-identical result must not regress.
require_relative 'parser_compat'

module AnnotatedEncode
  extend self

  # A back-reference is "R<ordinal>;" where the ordinal is assignment order in
  # a depth-first walk. Both sides must assign in the same order for the bytes
  # to agree, which is why ordinals come from the walk and not from object_id.
  def encode(root)
    seen = {}
    encode_value(root, seen)
  end

  def encode_value(value, seen)
    case value
    when nil then 'N;'
    when true then 'T;'
    when false then 'B;'
    when Symbol then ParserCompat.send(:length_encoded, 'Y', value.to_s)
    when String then ParserCompat.send(:length_encoded, 'S', value)
    when Integer then "I#{value};"
    when Float then "F#{ParserCompat.send(:float_text, value)};"
    when Lexer::Token
      composite(value, seen) do
        object('Token', { 'column' => value.column, 'line' => value.line,
                          'type' => value.type, 'value' => value.value }, seen)
      end
    when Array
      composite(value, seen) do
        "A#{value.length}[#{value.map { |item| encode_value(item, seen) }.join}]"
      end
    when Hash
      composite(value, seen) do
        pairs = value.map { |key, item| [encode_value(key, seen), encode_value(item, seen)] }
        pairs.sort_by! { |key, item| key + item }
        "H#{pairs.length}[#{pairs.flatten.join}]"
      end
    when Type
      # Same reasoning as the parser encoder: Type memoises derived state into
      # ivars on demand, so encoding by instance_variables makes the bytes
      # depend on which accessors happened to run.
      composite(value, seen) { object('Type', { 'resolved' => value.resolved }, seen) }
    when T::Enum
      object(value.class.name.split('::').last, { 'value' => value.serialize }, seen)
    else
      composite(value, seen) { ruby_object(value, seen) }
    end
  end

  # Identity is per-object. The first visit assigns an ordinal and encodes the
  # body; any later visit emits the ordinal alone, which is what stops a cyclic
  # annotated graph from recursing forever.
  def composite(value, seen)
    existing = seen[value.object_id]
    return "R#{existing};" if existing

    ordinal = seen.length
    seen[value.object_id] = ordinal
    "D#{ordinal}:#{yield}"
  end

  def object(name, fields, seen)
    encoded = fields.sort_by { |field, _| field }.map do |field, value|
      ParserCompat.send(:length_encoded, 'S', field) + encode_value(value, seen)
    end.join
    "O#{name.bytesize}:#{name}#{fields.length}[#{encoded}]"
  end

  # Unlike the parser encoder this keeps STAMP_FIELDS: they are the payload.
  def ruby_object(value, seen)
    fields = if value.is_a?(Struct)
               # value.class.members, not value.members: AST nodes are Structs,
               # and some of them (protocol/impl bodies) have their OWN `members`
               # field holding FunctionDefs, which shadows Struct#members. The
               # class-level reader is never shadowed.
               value.class.members.to_h { |member| [member.to_s, value[member]] }
             elsif value.class.respond_to?(:props)
               value.class.props.keys.to_h { |name| [name.to_s, value.public_send(name)] }
             else
               value.instance_variables.to_h do |ivar|
                 [ivar.to_s.delete_prefix('@'), value.instance_variable_get(ivar)]
               end
             end
    raise "unsupported annotated value: #{value.class}" if fields.empty?

    object(value.class.name.split('::').last, fields, seen)
  end
end
