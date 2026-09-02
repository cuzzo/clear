#!/usr/bin/env ruby
# frozen_string_literal: true

# Repair generated casts that MATCH a struct as though it were a union.
#
# rtoc emits `castXToY` by pattern-matching the source's variants. When the
# source is a STRUCT it has no variants, so the generated body matches on
# `X.StringValue` and the compiler reports "Struct 'X' has no field
# 'StringValue'". The cast the call sites actually want is the wrap: the
# target union carries a variant whose payload IS X, so the body is that one
# construction.
require 'set'
require 'optparse'
require_relative 'selfhost_union_accessor'

ROOT = File.expand_path('../compiler/src', __dir__)
apply = false
OptionParser.new { |p| p.on('--apply') { apply = true } }.parse!

variants, struct_fields = SelfhostUnionAccessor.load_types(ROOT)
fixed = 0
skipped = Hash.new(0)

Dir.glob(File.join(ROOT, '**', '*.clear')).sort.each do |path|
  text = File.read(path)
  out = text.gsub(
    /^(FN (?:cast\w+To\w+(?:__\w+)?)\(value: (\w+)\) RETURNS (\w+) ->\n)(.*?)(^END\n)/m
  ) do
    head = Regexp.last_match(1)
    src = Regexp.last_match(2)
    dst = Regexp.last_match(3)
    body = Regexp.last_match(4)
    tail = Regexp.last_match(5)
    whole = Regexp.last_match(0)

    # Only bodies that match the source as a union, where it is not one.
    next whole unless body.include?("PARTIAL MATCH value") && body.include?("#{src}.")
    next whole if variants.key?(src)
    next whole unless struct_fields.key?(src)

    members = variants[dst]
    unless members
      skipped[:target_not_union] += 1
      next whole
    end

    # An exact match beats a capability-carrying one: wrapping a plain value
    # into an @multiowned variant would claim a refcount it does not have.
    variant = members.find { |_, ty| ty.to_s == src } ||
              members.find { |_, ty| ty.to_s.sub(/@\w+\z/, '') == src }
    unless variant
      skipped[:no_matching_variant] += 1
      next whole
    end

    fixed += 1
    "#{head}  RETURN #{dst}{ #{variant[0]}: COPY value };\n#{tail}"
  end
  File.write(path, out) if apply && out != text
end

puts "#{fixed} struct cast(s) rewritten to the wrapping construction"
skipped.each { |k, v| puts "  skipped #{v} (#{k})" }
puts '(dry run -- pass --apply to write)' unless apply
