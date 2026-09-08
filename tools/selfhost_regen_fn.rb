#!/usr/bin/env ruby
# frozen_string_literal: true

# Re-translate ONE function from Ruby and splice it into the generated tree.
#
# A translator fix only reaches the corpus through a re-translation, but a
# whole-file regeneration would discard every hand fix in the file. Splicing
# the functions that DO NOT COMPILE keeps the ones that do: a failing function
# has no fix worth keeping, so replacing it can only help.
#
#   ruby tools/selfhost_regen_fn.rb --source compiler/ruby/annotator/phases/type_analysis_session.rb \
#        --target compiler/src/annotator/phases/type_analysis_session.clear --fns a,b,c [--apply]
require 'optparse'

ROOT = File.expand_path('..', __dir__)

def function_spans(text)
  lines = text.lines
  spans = {}
  lines.each_with_index do |line, i|
    m = line.match(/^(?:PUB |PRIVATE )?FN ([\w?!]+)(?:<[^>]*>)?\(/) or next
    j = i + 1
    j += 1 while j < lines.length && !lines[j].match?(/^(?:PUB |PRIVATE )?FN /)
    # Trim back to the function's own END.
    k = j - 1
    k -= 1 while k > i && lines[k].strip.empty?
    spans[m[1]] = [i, k]
  end
  spans
end

source = target = nil
fns = []
apply = false
OptionParser.new do |p|
  p.on('--source PATH') { |v| source = v }
  p.on('--target PATH') { |v| target = v }
  p.on('--fns LIST') { |v| fns = v.split(',') }
  p.on('--apply') { apply = true }
end.parse!(ARGV)
abort 'usage: --source RB --target CLEAR --fns a,b [--apply]' unless source && target && !fns.empty?

generated = `ruby #{File.join(ROOT, 'gems/ruby-to-clear/exe/ruby-to-clear')} #{source}`
abort 'ruby-to-clear failed' unless $?.success?

fresh = function_spans(generated)
fresh_lines = generated.lines
current_text = File.read(target)
current = function_spans(current_text)
current_lines = current_text.lines

replaced = []
missing = []
# Splice from the bottom so earlier spans keep their indices.
fns.sort_by { |n| -(current[n]&.first || -1) }.each do |name|
  unless fresh.key?(name) && current.key?(name)
    missing << name
    next
  end
  a, b = current[name]
  c, d = fresh[name]
  current_lines[a..b] = fresh_lines[c..d]
  replaced << name
end

File.write(target, current_lines.join) if apply
warn "spliced #{replaced.length}, missing #{missing.length}#{apply ? '' : ' (dry run)'}"
warn "missing: #{missing.first(8).join(', ')}" unless missing.empty?
