#! /usr/bin/env ruby
# Branch-gap TRIAGE + MODALITY BUCKETING.
#
# You do not triage N branches. You triage the ~M methods that contain
# them, and for each dark arm you decide WHICH testing modality can
# reach it. A never-taken arm is exactly one of four things:
#
#   fuzz-axis        reachable by a VALID program of an unseen shape
#                    (case-on-AST dispatch, &&/|| clause gap, a live
#                    if/while body). One fuzz template axis covers a
#                    whole arm family combinatorially. + a mutant.
#   negative-spec    the arm raises / diagnoses -> reachable only by an
#                    INVALID program. Fuzz emits valid self-checking
#                    programs by construction and can NEVER reach it.
#                    One deterministic negative unit spec per cluster.
#   ffi-integration  the arm is in the extern/require/module boundary
#                    -> needs a real external artifact a fuzzer cannot
#                    synthesize. A handful of targeted .cht. (Whole-
#                    program .cht is otherwise the WRONG lever: 92 real
#                    programs moved this set 50/1005 arms.)
#   accept-defensive an effect-free else / impossible guard -> annotate
#                    and remove from the denominator. No test. (Human
#                    confirms; this bucket is proposed, not decided.)
#
# Classification is AST-STRUCTURAL, never a regex over the arm's source
# line (that is the fake-value grep): the SimpleCov parent tuple gives
# the decision kind, and the arm's (line,col)-(line,col) span is
# matched to an AST node whose subtree is then inspected for raise /
# FFI. The two PER-PROJECT LEXICON constants below are the only
# project-specific knobs (generalizable: swap them per codebase).
#
# Usage: ruby tools/branch_gap_triage.rb [src/file.rb ...]

require 'json'

ROOT = File.expand_path('..', __dir__)
RESULTSET = File.join(ROOT, 'coverage', '.resultset.json')
DEFAULT_FILES = %w[
  src/mir/escape_analysis.rb
  src/mir/control_flow.rb
  src/mir/mir_lowering.rb
].freeze

# --- PER-PROJECT LEXICON (the only project-specific config) ---
# Methods that ARE the FFI / package boundary: a dark arm here needs a
# real external module + oracle no fuzzer can synthesize.
FFI_BOUNDARY = %w[
  build_extern_trampoline_call build_extern_trampoline_method
  build_extern_trampoline_common lower_extern_direct_call
  lower_require lower_module
].freeze
# Message names that mean "this arm is an error/diagnostic path"
# (reachable only by an invalid program).
DIAGNOSTIC_MIDS = %i[raise fail abort].freeze

abort "no #{RESULTSET}" unless File.exist?(RESULTSET)

merged = Hash.new
JSON.parse(File.read(RESULTSET)).each_value do |entry|
  (entry['coverage'] || {}).each do |path, cov|
    next unless cov.is_a?(Hash) && cov['branches']
    dst = (merged[path] ||= {})
    cov['branches'].each do |parent, arms|
      d = (dst[parent] ||= Hash.new(0))
      arms.each { |arm, n| d[arm] = d[arm] + (n || 0) }
    end
  end
end

# line -> enclosing def name (nearest preceding `def` at lower indent),
# plus that def's start line, by a single top-down scan of the source.
def method_index(lines)
  idx = {}
  stack = [] # [indent, name, start_line]
  lines.each_with_index do |raw, i|
    ln = i + 1
    if (m = raw.match(/^(\s*)def\s+(self\.)?([A-Za-z0-9_?!]+)/))
      ind = m[1].length
      stack.pop while stack.any? && stack.last[0] >= ind
      stack.push([ind, m[3], ln])
    elsif (e = raw.match(/^(\s*)end\b/))
      ind = e[1].length
      stack.pop if stack.any? && stack.last[0] == ind
    end
    idx[ln] = stack.last ? [stack.last[1], stack.last[2]] : ['(top-level)', 0]
  end
  idx
end

# All AST nodes of a file, for span -> node resolution.
def ast_nodes(abspath)
  root = RubyVM::AbstractSyntaxTree.parse(File.read(abspath),
                                          keep_script_lines: true)
  acc = []
  walk = lambda do |n|
    return unless n.is_a?(RubyVM::AbstractSyntaxTree::Node)

    acc << n
    n.children.each { |c| walk.call(c) }
  end
  walk.call(root)
  acc
rescue SyntaxError, StandardError
  []
end

# Smallest AST node whose span covers the arm span (sl,sc)-(el,ec);
# prefers an exact match. nil if none (then we fall back to the
# decision kind alone, flagged low-confidence).
def node_for(nodes, sl, sc, el, ec)
  span = ->(n) { [n.first_lineno, n.first_column, n.last_lineno, n.last_column] }
  exact = nodes.find { |n| span.call(n) == [sl, sc, el, ec] }
  return exact if exact

  covering = nodes.select do |n|
    a = span.call(n)
    (a[0] < sl || (a[0] == sl && a[1] <= sc)) &&
      (a[2] > el || (a[2] == el && a[3] >= ec))
  end
  covering.min_by { |n| (n.last_lineno - n.first_lineno) * 1000 + n.children.size }
end

def subtree_calls(node)
  mids = []
  stack = [node]
  until stack.empty?
    n = stack.pop
    next unless n.is_a?(RubyVM::AbstractSyntaxTree::Node)

    case n.type
    when :FCALL, :VCALL then mids << n.children[0]
    when :CALL, :OPCALL, :QCALL then mids << n.children[1]
    end
    n.children.each { |c| stack << c }
  end
  mids
end

# accept-defensive is the NARROW residue: an arm that produces no
# observable outcome -- the synthetic implicit `else` SimpleCov still
# counts, an empty body, a bare `nil`. Anything that calls, assigns,
# returns/breaks, or yields a value IS a reachable valid-program
# decision outcome and defaults to fuzz_axis (human triage may later
# demote a genuinely-impossible one; we never auto-accept a reachable
# arm).
def trivial?(node)
  return true if node.nil?
  return true if node.type == :NIL
  return true if node.type == :BEGIN && node.children.compact.empty?
  return false if subtree_calls(node).any?
  return false if has_type?(node, %i[LASGN IASGN OP_ASGN ATTRASGN MASGN
                                     GASGN CVASGN RETURN NEXT BREAK YIELD])

  # a bare value (literal / lvar / ivar) IS the branch's outcome ->
  # reachable, not inert.
  !has_type?(node, %i[LIT STR SYM INTEGER FLOAT LVAR IVAR DVAR CONST
                      ARRAY HASH TRUE FALSE])
end

def has_type?(node, types)
  stack = [node]
  until stack.empty?
    n = stack.pop
    next unless n.is_a?(RubyVM::AbstractSyntaxTree::Node)
    return true if types.include?(n.type)

    n.children.each { |c| stack << c }
  end
  false
end

DISPATCH_KINDS = %i[case when].freeze
CONJ_KINDS = %i[& |].freeze
COND_KINDS = %i[if unless ternary while until for].freeze

# decision_kind: Symbol from the SimpleCov parent tuple ([:if,...] etc).
# Returns [bucket, confidence].
def classify(method_name, decision_kind, arm_node)
  return [:ffi_integration, :high] if FFI_BOUNDARY.include?(method_name)

  if arm_node && (subtree_calls(arm_node) & DIAGNOSTIC_MIDS).any?
    return [:negative_spec, :high]
  end

  if DISPATCH_KINDS.include?(decision_kind) || CONJ_KINDS.include?(decision_kind)
    return [:fuzz_axis, arm_node ? :high : :low]
  end

  if COND_KINDS.include?(decision_kind)
    return [:accept_defensive, :med] if trivial?(arm_node)

    return [:fuzz_axis, arm_node ? :high : :low]
  end

  [:accept_defensive, :low]
end

ACTION = {
  fuzz_axis: 'fuzz template axis (+ mutant)',
  negative_spec: 'negative unit spec (fuzz cannot reach)',
  ffi_integration: 'targeted FFI/package .cht',
  accept_defensive: 'annotate + accept (human-confirm)'
}.freeze

targets = ARGV.empty? ? DEFAULT_FILES : ARGV
grand = Hash.new(0)

targets.each do |rel|
  abspath = File.join(ROOT, rel)
  branches = merged[abspath]
  next unless branches

  lines = File.readlines(abspath)
  midx = method_index(lines)
  nodes = ast_nodes(abspath)

  by_method = Hash.new { |h, k| h[k] = [] }
  total_by_method = Hash.new(0)
  bucket_by_method = Hash.new { |h, k| h[k] = Hash.new(0) }
  file_bucket = Hash.new(0)

  branches.each do |parent, arms|
    pkind = parent.gsub(/[\[\]:\s]/, '').split(',').first.to_s.to_sym
    arms.each do |arm, count|
      a = arm.gsub(/[\[\]:]/, '').split(',').map(&:strip)
      line = a[2].to_i
      meth, mstart = midx[line] || ['(top-level)', 0]
      key = [meth, mstart]
      total_by_method[key] += 1
      next unless count.to_i.zero?

      sl = a[2].to_i
      sc = a[3].to_i
      el = a[4].to_i
      ec = a[5].to_i
      anode = node_for(nodes, sl, sc, el, ec)
      bucket, conf = classify(meth, pkind, anode)
      by_method[key] << [line, a[0], bucket, conf]
      bucket_by_method[key][bucket] += 1
      file_bucket[bucket] += 1
      grand[bucket] += 1
    end
  end

  ranked = by_method.reject { |_, v| v.empty? }
                     .sort_by { |(_, _), v| -v.size }
  puts "\n##### #{rel} — #{ranked.size} methods carry dark arms " \
       "(#{by_method.values.sum(&:size)} arms)"
  puts '  buckets: ' + file_bucket.sort_by { |_, n| -n }
                                   .map { |b, n| "#{b}=#{n}" }.join('  ')
  puts format('  %-40s %4s %4s  %-16s %s',
              'method', 'dark', 'tot', 'dominant', 'bucket mix')
  ranked.each do |(meth, mstart), arms|
    tot = total_by_method[[meth, mstart]]
    mix = bucket_by_method[[meth, mstart]]
    dom = mix.max_by { |_, n| n }.first
    mixs = mix.sort_by { |_, n| -n }.map { |b, n| "#{b}:#{n}" }.join(' ')
    puts format('  %-40s %4d %4d  %-16s %s',
                "#{meth}@#{mstart}", arms.size, tot, dom, mixs)
  end
end

puts "\n##### MODALITY WORK PLAN (all targets)"
grand.sort_by { |_, n| -n }.each do |bucket, n|
  puts format('  %-18s %5d arms  ->  %s', bucket, n, ACTION[bucket])
end
puts "\n  Triage order: fuzz_axis (combinatorial, memory-safety) first," \
     " then negative_spec, then ffi_integration; accept_defensive is" \
     " human-confirmed and leaves the denominator."
