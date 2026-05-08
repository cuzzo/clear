# typed: false
# frozen_string_literal: true
#
# Narrow generic container types in autogen sigs based on runtime
# element observations from the TracePoint tracer.
#
# Targets:
#   - `Array` / `T::Array[T.untyped]`  → `T::Array[X]`  where X is the
#     union of element classes observed
#   - `Hash` / `T::Hash[T.untyped, T.untyped]` → `T::Hash[K, V]`
#   - `Set` / `T::Set[T.untyped]` → `T::Set[X]`
#
# Walks every sig `{}` block in src/, extracts the (klass, method,
# kind) and matches against the trace observation. For each
# parameter or return slot whose declared type is a generic container,
# narrows it using the corresponding `param_elem` / `param_kv` /
# `return_elem` / `return_kv` data.
#
# Coverage threshold: only narrow when the method has at least
# MIN_OBSERVATIONS calls AND at least one element observation. This
# avoids narrowing rarely-observed methods where "X is the only
# element class" is weak evidence.
#
# Run AFTER `bundle exec ruby tools/gen_sigs_from_trace.rb` and the
# safe_autocorrect / widen passes — i.e. when sigs are stable.
#
# Usage:
#   bundle exec ruby tools/narrow_generics.rb
#   DRY_RUN=1 bundle exec ruby tools/narrow_generics.rb

require "json"
require "set"
require "prism"

OBS_DIR = File.expand_path("../tmp/sig_obs", __dir__)
SRC_DIR = File.expand_path("../src", __dir__)
DRY_RUN = ENV["DRY_RUN"] == "1"
MIN_OBSERVATIONS = ENV.fetch("MIN_OBSERVATIONS", "20").to_i
WIDE_THRESHOLD = 4  # Same threshold as the main generator.

# Aggregate observations.
records = {}
Dir.glob(File.join(OBS_DIR, "*.jsonl")).each do |file|
  File.foreach(file) do |line|
    obs = JSON.parse(line)
    key = [obs["klass"], obs["method"], obs["kind"].to_sym]
    rec = records[key] ||= {
      calls: 0,
      param_elem: {}, # name => Set
      param_kv:   {}, # name => [Set, Set]
      return_elem: Set.new,
      return_kv:   [Set.new, Set.new],
    }
    rec[:calls] += obs["calls"]
    (obs["param_elem"] || {}).each do |name, classes|
      rec[:param_elem][name] ||= Set.new
      classes.each { |c| rec[:param_elem][name] << c }
    end
    (obs["param_kv"] || {}).each do |name, kv|
      rec[:param_kv][name] ||= [Set.new, Set.new]
      kv[0].each { |c| rec[:param_kv][name][0] << c }
      kv[1].each { |c| rec[:param_kv][name][1] << c }
    end
    (obs["return_elem"] || []).each { |c| rec[:return_elem] << c }
    if obs["return_kv"]
      obs["return_kv"][0].each { |c| rec[:return_kv][0] << c }
      obs["return_kv"][1].each { |c| rec[:return_kv][1] << c }
    end
  end
end
puts "Loaded #{records.size} records from #{OBS_DIR}"

# Class-name set → Sorbet type expression for a CONTAINER ELEMENT
# slot. Conservative: only emit a tight type when observation is
# unambiguous (single class, no nil) AND the class isn't part of a
# polymorphic hierarchy (AST::*/MIR::*) where the corpus might have
# missed sibling shapes. Otherwise emit T.untyped — which leaves the
# container as `T::Array[T.untyped]` (no narrowing). This avoids the
# cascade where narrowing one element type triggers caller-side
# 7002/7003 errors at every site that passes a sibling shape.
def fmt_set(set)
  set = set.to_a.reject { |c| c.nil? || c.empty? }
  return "T.untyped" if set.empty?
  has_nil = set.include?("NilClass")
  others = set.reject { |c| c == "NilClass" }
  return "T.untyped" if others.empty?  # only nil → no narrowing signal
  others = others.reject { |c| c.include?("#") || c.start_with?("Sorbet::Private::") }
  return "T.untyped" if others.empty?

  # Bail on multi-class observation — too high a false-positive rate
  # for narrowing element types.
  return "T.untyped" if others.size > 1

  cls = others.first
  # Polymorphic hierarchies: a single observation is almost certainly
  # too narrow.
  return "T.untyped" if cls.start_with?("AST::") || cls.start_with?("MIR::")

  base = cls
  has_nil ? "T.nilable(#{base})" : base
end

# For each sig in src/, narrow Array/Hash/Set slots using observation.
total_narrowed = 0
files_changed = 0

Dir.glob(File.join(SRC_DIR, "**", "*.rb")).each do |path|
  parsed = Prism.parse_file(path)
  next unless parsed.success?
  lines = File.readlines(path)

  changes = []  # [line_idx, new_line]

  walker = lambda do |node, scope|
    case node
    when Prism::ClassNode, Prism::ModuleNode
      name = node.constant_path.respond_to?(:name) ? node.constant_path.name.to_s : ""
      sub = (scope + [name]).join("::")
      body = node.body
      if body.respond_to?(:body) && body.body.respond_to?(:each)
        body.body.each { |c| walker.call(c, scope + [name]) }
      end
    when Prism::DefNode
      cls = scope.join("::")
      kind = node.receiver.is_a?(Prism::SelfNode) ? :class : :instance
      key = [cls, node.name.to_s, kind]
      rec = records[key]
      return unless rec
      return if rec[:calls] < MIN_OBSERVATIONS

      def_line = node.location.start_line
      sig_idx = nil
      (def_line - 2).downto([def_line - 5, 0].max) do |i|
        if lines[i] && lines[i] =~ /\bsig\s*\{/
          sig_idx = i
          break
        end
      end
      return unless sig_idx

      new_line = lines[sig_idx].dup
      orig_line = new_line.dup

      # Narrow each param slot.
      params = node.parameters
      if params
        all_p = []
        params.requireds.each { |p| all_p << p }
        params.optionals.each { |p| all_p << p }
        params.keywords.each { |p| all_p << p }
        all_p.each do |p|
          name = p.name.to_s
          new_line = narrow_slot(new_line, name, :param, rec)
        end
      end

      # Narrow return slot.
      new_line = narrow_slot(new_line, nil, :return, rec)

      if new_line != orig_line
        changes << [sig_idx, new_line]
      end
    when Prism::SingletonClassNode
      body = node.body
      if body && body.respond_to?(:body) && body.body.respond_to?(:each)
        body.body.each { |c| walker.call(c, scope) }
      end
    else
      node.respond_to?(:child_nodes) && node.child_nodes.compact.each do |c|
        walker.call(c, scope)
      end
    end
  end
  walker.call(parsed.value, [])

  next if changes.empty?

  changes.each { |idx, line| lines[idx] = line }
  if DRY_RUN
    puts "DRY: #{path} -> #{changes.size} narrowings"
  else
    File.write(path, lines.join)
  end
  total_narrowed += changes.size
  files_changed += 1
end

# Replace `Array` (or `T::Array[T.untyped]`) at slot `name` (or
# return) with the narrower type from observation.
BEGIN {
  def narrow_slot(sig_line, name, kind, rec)
    new_line = sig_line.dup
    if kind == :param
      elem_set = rec[:param_elem][name]
      kv = rec[:param_kv][name]
      new_line = narrow_array_slot(new_line, name, elem_set) if elem_set && !elem_set.empty?
      new_line = narrow_set_slot(new_line, name, elem_set) if elem_set && !elem_set.empty?
      new_line = narrow_hash_slot(new_line, name, kv) if kv && !(kv[0].empty? && kv[1].empty?)
    else
      new_line = narrow_array_slot(new_line, nil, rec[:return_elem]) unless rec[:return_elem].empty?
      new_line = narrow_set_slot(new_line, nil, rec[:return_elem]) unless rec[:return_elem].empty?
      kv = rec[:return_kv]
      new_line = narrow_hash_slot(new_line, nil, kv) if kv && !(kv[0].empty? && kv[1].empty?)
    end
    new_line
  end

  # Match `name: Array` or `name: T::Array[T.untyped]` (or returns
  # variant) and replace with `name: T::Array[X]`. Skip if the
  # narrowed element type is T.untyped (no signal) — leaves the slot
  # as the original generic.
  def narrow_array_slot(line, name, elem_set)
    elem_type = fmt_set(elem_set)
    return line if elem_type == "T.untyped"
    new_inner = "T::Array[#{elem_type}]"

    if name
      # Match `name: Array` (exact, end of word) and `name: T::Array[T.untyped]`
      line = line.sub(/\b#{Regexp.escape(name)}:\s*Array(?=[,)\s])/, "#{name}: #{new_inner}")
      line = line.sub(/\b#{Regexp.escape(name)}:\s*T::Array\[T\.untyped\]/, "#{name}: #{new_inner}")
      # Also handle T.nilable(Array) / T.nilable(T::Array[T.untyped])
      line = line.sub(/\b#{Regexp.escape(name)}:\s*T\.nilable\(Array\)/, "#{name}: T.nilable(#{new_inner})")
      line = line.sub(/\b#{Regexp.escape(name)}:\s*T\.nilable\(T::Array\[T\.untyped\]\)/, "#{name}: T.nilable(#{new_inner})")
    else
      line = line.sub(/\.returns\(Array\)/, ".returns(#{new_inner})")
      line = line.sub(/\.returns\(T::Array\[T\.untyped\]\)/, ".returns(#{new_inner})")
      line = line.sub(/\.returns\(T\.nilable\(Array\)\)/, ".returns(T.nilable(#{new_inner}))")
      line = line.sub(/\.returns\(T\.nilable\(T::Array\[T\.untyped\]\)\)/, ".returns(T.nilable(#{new_inner}))")
    end
    line
  end

  def narrow_set_slot(line, name, elem_set)
    elem_type = fmt_set(elem_set)
    return line if elem_type == "T.untyped"
    new_inner = "T::Set[#{elem_type}]"
    if name
      line = line.sub(/\b#{Regexp.escape(name)}:\s*Set(?=[,)\s])/, "#{name}: #{new_inner}")
      line = line.sub(/\b#{Regexp.escape(name)}:\s*T::Set\[T\.untyped\]/, "#{name}: #{new_inner}")
      line = line.sub(/\b#{Regexp.escape(name)}:\s*T\.nilable\(Set\)/, "#{name}: T.nilable(#{new_inner})")
    else
      line = line.sub(/\.returns\(Set\)/, ".returns(#{new_inner})")
      line = line.sub(/\.returns\(T::Set\[T\.untyped\]\)/, ".returns(#{new_inner})")
    end
    line
  end

  def narrow_hash_slot(line, name, kv)
    k_type = fmt_set(kv[0])
    v_type = fmt_set(kv[1])
    # Skip if BOTH key and value are T.untyped (no signal).
    return line if k_type == "T.untyped" && v_type == "T.untyped"
    new_inner = "T::Hash[#{k_type}, #{v_type}]"
    if name
      line = line.sub(/\b#{Regexp.escape(name)}:\s*Hash(?=[,)\s])/, "#{name}: #{new_inner}")
      line = line.sub(/\b#{Regexp.escape(name)}:\s*T::Hash\[T\.untyped,\s*T\.untyped\]/, "#{name}: #{new_inner}")
      line = line.sub(/\b#{Regexp.escape(name)}:\s*T\.nilable\(Hash\)/, "#{name}: T.nilable(#{new_inner})")
    else
      line = line.sub(/\.returns\(Hash\)/, ".returns(#{new_inner})")
      line = line.sub(/\.returns\(T::Hash\[T\.untyped,\s*T\.untyped\]\)/, ".returns(#{new_inner})")
    end
    line
  end
}

puts
puts "==== Stats ===="
puts "  Slots narrowed:    #{total_narrowed}"
puts "  Files changed:     #{files_changed}"
puts "  Min observations:  #{MIN_OBSERVATIONS}"
puts DRY_RUN ? "  (DRY_RUN — no files modified)" : "  Applied to disk."
