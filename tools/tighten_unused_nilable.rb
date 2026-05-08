# typed: false
# frozen_string_literal: true
#
# Reverse direction: find `T.nilable(X)` slots in autogen sigs whose
# runtime observations *never* saw nil, and narrow them to `X`.
#
# Two kinds of slots are inspected:
#   - Param types     (rec[:params_by_name][name])
#   - Return types    (rec[:returns])
#
# A slot qualifies if:
#   1. The sig's existing type is `T.nilable(X)` (or `T.nilable(T.any(...))`)
#   2. The aggregated observation set across all JSONL files for that
#      method has at least MIN_OBSERVATIONS calls (default 50) — we don't
#      narrow rarely-observed methods, since "never saw nil" is weak
#      evidence with few observations.
#   3. NilClass is NOT in the observation set for that slot.
#
# Caveat: tightening makes Sorbet enforce non-nil at the call site /
# body's return-path level. If the body has `return nil` on a corpus-
# uncovered path, Sorbet will fire 7005 (body returns nilable, sig
# says non-nil) at the next `srb tc`. The driver runs `safe_autocorrect`
# afterward — those errors typically resolve via re-widening or the
# user can run `tools/widen_sigs_from_sorbet.rb --loop` to bounce back.
#
# Usage:
#   bundle exec ruby tools/tighten_unused_nilable.rb         # apply
#   DRY_RUN=1 bundle exec ruby tools/tighten_unused_nilable.rb
#
# Run AFTER `bundle exec ruby tools/gen_sigs_from_trace.rb` and any
# initial `srb tc -a` / widening passes.

require "json"
require "set"
require "prism"

OBS_DIR = File.expand_path("../tmp/sig_obs", __dir__)
SRC_DIR = File.expand_path("../src", __dir__)
DRY_RUN = ENV["DRY_RUN"] == "1"
MIN_OBSERVATIONS = ENV.fetch("MIN_OBSERVATIONS", "50").to_i

# Aggregate observations: { [klass, method, kind] => merged record }
records = {}
Dir.glob(File.join(OBS_DIR, "*.jsonl")).each do |file|
  File.foreach(file) do |line|
    obs = JSON.parse(line)
    key = [obs["klass"], obs["method"], obs["kind"].to_sym]
    rec = records[key] ||= { calls: 0, params_by_name: {}, returns: Set.new }
    rec[:calls] += obs["calls"]
    (obs["params_by_name"] || {}).each do |name, classes|
      rec[:params_by_name][name] ||= Set.new
      classes.each { |c| rec[:params_by_name][name] << c }
    end
    obs["returns"].each { |c| rec[:returns] << c }
  end
end
puts "Loaded #{records.size} (klass, method, kind) records"

# Walk every src/ file with Prism. For each method that has a `sig {}`
# block on the line above, find each T.nilable(...) slot in the sig
# and check observation.
class FileWalker
  attr_reader :tightenings

  def initialize(file)
    @file = file
    @lines = File.readlines(file)
    @tightenings = []  # array of [line_idx, new_line]
  end

  def walk(records)
    parsed = Prism.parse_file(@file)
    return unless parsed.success?
    walk_node(parsed.value, [], records)
  end

  def walk_node(node, scope, records)
    case node
    when Prism::ClassNode, Prism::ModuleNode
      name = const_path_name(node.constant_path)
      sub = node.body
      sub_walk(sub, scope + [name], records) if sub
    when Prism::DefNode
      cls = scope.join("::")
      kind = node.receiver.is_a?(Prism::SelfNode) ? :class : :instance
      key = [cls, node.name.to_s, kind]
      rec = records[key]
      return unless rec
      return if rec[:calls] < MIN_OBSERVATIONS

      # Find sig line just above the def. Could be 1-3 lines above.
      def_line = node.location.start_line  # 1-based
      sig_idx = nil
      (def_line - 2).downto([def_line - 5, 0].max) do |i|
        if @lines[i] && @lines[i] =~ /\bsig\s*\{/
          sig_idx = i
          break
        end
      end
      return unless sig_idx

      tighten_slots_in_sig(sig_idx, node, rec)
    when Prism::SingletonClassNode
      sub_walk(node.body, scope, records) if node.body
    else
      node.respond_to?(:child_nodes) && node.child_nodes.compact.each do |c|
        walk_node(c, scope, records)
      end
    end
  end

  def sub_walk(body, scope, records)
    if body.respond_to?(:body) && body.body.respond_to?(:each)
      body.body.each { |c| walk_node(c, scope, records) }
    elsif body.respond_to?(:child_nodes)
      body.child_nodes.compact.each { |c| walk_node(c, scope, records) }
    end
  end

  # Inspect the sig text at @lines[sig_idx] and tighten any
  # T.nilable(X) slot whose observation lacks NilClass.
  def tighten_slots_in_sig(sig_idx, def_node, rec)
    sig_line = @lines[sig_idx]
    new_line = sig_line.dup

    params = def_node.parameters
    if params
      param_obs = rec[:params_by_name]
      # Process in source order so column shifts compose correctly.
      all_params = []
      params.requireds.each { |p| all_params << p }
      params.optionals.each { |p| all_params << p }
      params.keywords.each { |p| all_params << p }

      all_params.each do |p|
        name = p.name.to_s
        slot = param_obs[name] || Set.new
        next if slot.empty?
        next if slot.include?("NilClass")
        # Skip params with nil defaults: even if the corpus never
        # observed nil, the def's contract permits omitting the arg
        # (binding it to nil at method entry). Sorbet (7007) rejects
        # `param: X` when the def is `param: nil` regardless of what
        # callers actually pass.
        next if p.respond_to?(:value) && p.value.is_a?(Prism::NilNode)
        new_line = narrow_in_sig(new_line, name, :param)
      end
    end

    # Returns intentionally NOT tightened. Even if observation never
    # saw nil, the body's static flow (per Sorbet) often shows nilable
    # paths the corpus didn't exercise. Tightening returns triggers
    # 7005 errors that the widener immediately reverts — net zero.
    # Params are determined by callers (which observation captures
    # well); returns by body flow (which Sorbet analyzes statically).

    return if new_line == sig_line
    @tightenings << [sig_idx, new_line]
  end

  # Narrow a `T.nilable(X)` slot in the sig string. For params, find
  # `name: T.nilable(...)` and replace with `name: ...`. For returns,
  # find `.returns(T.nilable(...))` and replace with `.returns(...)`.
  def narrow_in_sig(sig_line, name, slot_kind)
    if slot_kind == :param
      # `name: T.nilable(TYPE)` → `name: TYPE`
      pattern = /\b#{Regexp.escape(name)}:\s*T\.nilable\(/
      m = sig_line.match(pattern)
      return sig_line unless m
      start_inner = m.end(0)
      type_str, type_end = scan_balanced(sig_line, start_inner)
      return sig_line unless type_str
      # type_end points at `)`. Replace `T.nilable(TYPE)` with `TYPE`.
      replacement_start = m.begin(0) + name.length + ":".length
      # Step over leading whitespace (the regex consumed `: `).
      pre = sig_line[0...m.begin(0) + name.length + 1]
      ws = sig_line[(m.begin(0) + name.length + 1)..start_inner - "T.nilable(".length - 1]
      post = sig_line[type_end + 1..]  # skip the closing `)`
      pre + ws + type_str + post
    else
      # `.returns(T.nilable(TYPE))` → `.returns(TYPE)`
      m = sig_line.match(/\.returns\(\s*T\.nilable\(/)
      return sig_line unless m
      start_inner = m.end(0)
      type_str, type_end = scan_balanced(sig_line, start_inner)
      return sig_line unless type_str
      pre = sig_line[0...m.begin(0)]
      ws = ""  # within parens
      post = sig_line[type_end + 1..]  # past T.nilable's `)`
      # post still starts with the outer `)` of returns(...) since we
      # only consumed T.nilable's closing paren. So re-emit
      # `.returns(TYPE)` and append post.
      "#{pre}.returns(#{type_str})#{post.sub(/\A\)/, '')}"
    end
  end

  # Scan a balanced expression starting at pos, returning [str, end_idx]
  # where end_idx is the position of the matching close paren.
  def scan_balanced(str, pos)
    depth = 0
    i = pos
    while i < str.length
      case str[i]
      when "(", "[", "{" then depth += 1
      when ")", "]", "}"
        return [str[pos...i], i] if depth == 0
        depth -= 1
      end
      i += 1
    end
    [nil, nil]
  end

  def const_path_name(node)
    case node
    when Prism::ConstantReadNode
      node.name.to_s
    when Prism::ConstantPathNode
      parts = []
      n = node
      while n.is_a?(Prism::ConstantPathNode)
        parts.unshift(n.name.to_s)
        n = n.parent
      end
      parts.unshift(n.name.to_s) if n.is_a?(Prism::ConstantReadNode)
      parts.join("::")
    end
  end
end

total_tightenings = 0
files_changed = 0
Dir.glob(File.join(SRC_DIR, "**", "*.rb")).each do |file|
  walker = FileWalker.new(file)
  walker.walk(records)
  next if walker.tightenings.empty?

  lines = File.readlines(file)
  walker.tightenings.each do |idx, new_line|
    lines[idx] = new_line
  end

  if DRY_RUN
    puts "DRY: #{file} -> #{walker.tightenings.size} tightenings"
  else
    File.write(file, lines.join)
  end
  total_tightenings += walker.tightenings.size
  files_changed += 1
end

puts
puts "==== Stats ===="
puts "  Files changed:        #{files_changed}"
puts "  Slots tightened:      #{total_tightenings}"
puts "  Min observations:     #{MIN_OBSERVATIONS}"
puts DRY_RUN ? "  (DRY_RUN — no files modified)" : "  Applied to disk."
