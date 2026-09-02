#!/usr/bin/env ruby
# frozen_string_literal: true

# Rewrite `x.method()` into its union accessor, using the receiver type the
# compiler reported rather than inferring it.
#
# selfhost_method_to_accessor.rb walks backwards looking for a declaration to
# type the receiver; where that walk fails the call is left alone. The probe's
# UNKNOWN_INHERENT_METHOD diagnostic names the receiver type outright, so the
# rewrite needs no inference at all.
require 'json'
require 'set'
require 'optparse'

ROOT = File.expand_path('../compiler/src', __dir__)
probe = File.expand_path('../.fn_probe.json', __dir__)
apply = false
OptionParser.new do |p|
  p.on('--apply') { apply = true }
  p.on('--probe FILE') { |v| probe = v }
end.parse!

require_relative 'selfhost_union_accessor'
VARIANTS, STRUCT_FIELDS = SelfhostUnionAccessor.load_types(ROOT)

defined_fns = Set.new
Dir.glob(File.join(ROOT, '**', '*.clear')).each do |f|
  File.read(f).scan(/\bFN ([\w?!]+)\s*(?:<[^>]*>)?\(/) { |m| defined_fns << m[0] }
end

def bare(type) = type.to_s.sub(/@\w+\z/, '').delete_prefix('?').sub(/\A\[[^\]]*\]/, '')

# A field whose type differs across variants has no single-typed accessor; the
# AST module already publishes the reader those callers want.
ALIASES = {
  %w[Locatable value] => 'aST__node_value', %w[Node value] => 'aST__node_value',
  %w[Locatable name] => 'aST__node_name', %w[Node name] => 'aST__node_name',
  %w[Locatable right] => 'aST__node_right'
}.freeze

rows = JSON.parse(File.read(probe)).select do |r|
  !r['ok'] && r['line'] && r['error'].to_s.include?('UNKNOWN_INHERENT_METHOD')
end

by = Hash.new { |h, k| h[k] = [] }
rows.each do |r|
  m = r['error'].match(/Type ([\w@?\[\]{}]+) has no inherent METHOD named '([\w?!]+)'/)
  by[r['file']] << [r['line'], m[1], m[2]] if m
end

rewrites = 0
missing = Hash.new(0)
by.each do |f, hits|
  path = File.join(ROOT, f)
  lines = File.readlines(path)
  hits.uniq.each do |line_no, type, meth|
    i = line_no - 1
    next unless lines[i]

    b = bare(type)
    optional = type.start_with?('?')

    # A struct has no methods, but Ruby's attr reader translated as a call.
    # The field is right there: drop the parens rather than invent an accessor.
    if STRUCT_FIELDS[b]&.key?(meth) && !VARIANTS.key?(b)
      before = lines[i]
      lines[i] = lines[i].gsub(/(?<![\w.])([a-z_]\w*(?:\.[a-z_]\w*)*)\.#{Regexp.escape(meth)}\(\)/) do
        recv = Regexp.last_match(1)
        optional ? "UNWRAP (#{recv}).#{meth}" : "#{recv}.#{meth}"
      end
      rewrites += lines[i] == before ? 0 : 1
      next
    end

    fn = ALIASES[[b, meth]] || "#{b[0].to_s.downcase}#{b[1..]}__#{meth}"
    cast = nil
    unless defined_fns.include?(fn)
      # Fall back to the Locatable accessor when the union casts to Locatable.
      loc = ALIASES[['Locatable', meth]] || "locatable__#{meth}"
      candidate_cast = "cast#{b}ToLocatable"
      if defined_fns.include?(loc) && defined_fns.include?(candidate_cast)
        fn = loc
        cast = candidate_cast
      else
        missing["#{b}##{meth}"] += 1
        next
      end
    end

    # The receiver may be a path, an indexed element, a call, or an UNWRAP of
    # any of those; a bare-identifier pattern misses most real sites.
    recv_pat = /(?:UNWRAP\s*\((?:[^()]|\((?:[^()]|\([^()]*\))*\))*\)|[a-z_]\w*(?:__\w+)?\((?:[^()]|\((?:[^()]|\([^()]*\))*\))*\)|[a-z_]\w*(?:\[[^\]]*\])?(?:\.[a-z_]\w*(?:\[[^\]]*\])?)*)/
    new = lines[i].gsub(/(?<![\w.])(#{recv_pat})\.#{Regexp.escape(meth)}\(\)/) do
      recv = Regexp.last_match(1)
      recv = "UNWRAP (#{recv})" if optional
      recv = "UNWRAP (#{cast}(#{recv}))" if cast
      rewrites += 1
      "#{fn}(#{recv})"
    end
    lines[i] = new
  end
  File.write(path, lines.join) if apply
end

puts "#{rewrites} calls rewritten to the accessor the diagnostic names"
puts "no accessor: #{missing.values.sum}"
missing.sort_by { |_, v| -v }.first(12).each { |k, v| puts format('  %-46s %d', k, v) }
puts '(dry run -- pass --apply to write)' unless apply
