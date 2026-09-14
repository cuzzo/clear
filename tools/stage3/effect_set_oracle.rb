#!/usr/bin/env ruby
# frozen_string_literal: true

# Ruby half of the effect_set stage-3 check: run every case through the real
# Ruby implementation and print one canonical line per observation. The CLEAR
# harness prints the same lines; byte compatibility is `diff` returning nothing.
$PROGRAM_NAME = 'stage3_effect_set_oracle'
require_relative '../parser_compat'
require_relative '../../compiler/ruby/semantic/effect_set'
require_relative 'effect_set_cases'

def label(list) = list.empty? ? '-' : list.join('|')

EffectSetCases.sets.each do |list|
  set = EffectSet.new(list)
  puts "empty?\t#{label(list)}\t#{set.empty?}"
  puts "hash\t#{label(list)}\t#{set.hash}"
  puts "to_a\t#{label(list)}\t#{set.to_a.join(',')}"
  puts "to_s\t#{label(list)}\t#{set}"
  EffectSetCases::KNOWN.each do |e|
    puts "include?\t#{label(list)}\t#{e}\t#{set.include?(e)}"
  end
end

EffectSetCases.pairs.each do |a, b|
  sa = EffectSet.new(a)
  sb = EffectSet.new(b)
  puts "union\t#{label(a)}\t#{label(b)}\t#{sa.union(sb).to_a.join(',')}"
  puts "equals\t#{label(a)}\t#{label(b)}\t#{sa == sb}"
end
