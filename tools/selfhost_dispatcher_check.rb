#!/usr/bin/env ruby
# frozen_string_literal: true

# Static gate: a method every variant of a union defines, where the union
# itself has no dispatcher.
#
# rtoc reliably emits the per-variant functions and sometimes omits the union
# dispatcher, so a call written against the union has nothing to reach. Three
# have turned up this way -- destroy_order_index and ctx_cleanup_target_name
# were missing while destroy_order_bucket, right beside them, was not.
#
# Only when EVERY variant defines it: a method on some variants is narrowed at
# the call site by design, which is how guard_field is meant to work.
$PROGRAM_NAME = 'selfhost_dispatcher_check_support'
require 'set'

GEN = File.join(File.expand_path('..', __dir__), 'compiler', 'src')
UNION = /^(?:PUB |PRIVATE )?UNION\s+(\w+)\s*\{(.*)\}/
FN = /^(?:PUB |PRIVATE )?FN\s+([a-z]\w*)__([a-z_]\w*[?!]?)\s*\(/

unions = {}
methods = Hash.new { |h, k| h[k] = Set.new }
Dir.glob(File.join(GEN, '**', '*.clear')).each do |path|
  File.readlines(path).each do |line|
    if (m = UNION.match(line))
      unions[m[1]] ||= m[2].scan(/:\s*([A-Z]\w*)/).flatten.uniq
    elsif (f = FN.match(line))
      methods[f[1]] << f[2]
    end
  end
end

def owner_key(type_name)
  "#{type_name[0].downcase}#{type_name[1..]}"
end

# every `owner__method(` token that appears anywhere, so a missing dispatcher
# is only reported where a call needs it
CALL_SITES = Set.new
Dir.glob(File.join(GEN, '**', '*.clear')).each do |path|
  File.read(path).scan(/([a-z]\w*__[a-z_]\w*[?!]?\()/).flatten.each { |c| CALL_SITES << c }
end

bad = 0
unions.each do |union, variants|
  next if variants.length < 2

  owners = variants.map { |v| owner_key(v) }
  next unless owners.all? { |o| methods.key?(o) }

  common = owners.map { |o| methods[o] }.reduce(:&)
  next if common.nil? || common.empty?

  have = methods[owner_key(union)]
  (common - have).sort.each do |meth|
    # Only when something actually CALLS it on the union. Most unions never
    # dispatch at the union level, and reporting those buries the real ones.
    call = "#{owner_key(union)}__#{meth}("
    next unless CALL_SITES.include?(call)

    puts "#{union}: every variant defines #{meth}, union has no dispatcher"
    bad += 1
  end
end
puts "unions missing a dispatcher every variant supports: #{bad}"
