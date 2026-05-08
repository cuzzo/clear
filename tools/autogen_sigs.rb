#!/usr/bin/env ruby
# typed: false
#
# Auto-generate Sorbet `sig` blocks for visitor/dispatcher patterns.
#
# Many methods in src/ follow a uniform shape:
#   def emit(node)
#     case node
#     when MIR::Lit  then emit_lit(node)
#     when MIR::Call then emit_call(node)
#     ...
#     end
#   end
#
#   def emit_lit(node)
#     ...
#   end
#
# Each helper's param type is determined by the dispatch arm. This
# tool walks dispatcher methods (named `emit`, `visit`, `lower` by
# default), builds a `helper_name => arg_class` map from the case/when
# table, and emits a `sig { params(node: <Class>).returns(<Return>) }`
# block above each helper that doesn't already have one.
#
# Return-type policy (per dispatcher):
#   emit_*  -> String   (MIREmitter is a Zig-text template engine)
#   visit_* -> .void    (SemanticAnnotator's visitors are side-effecting)
#   lower_* -> T.untyped (MIRLowering returns various MIR shapes; no
#                         single union type yet)
#
# Usage:
#   bundle exec ruby tools/autogen_sigs.rb src/mir/mir_emitter.rb
#   bundle exec ruby tools/autogen_sigs.rb src/annotator.rb
#   bundle exec ruby tools/autogen_sigs.rb src/mir/mir_lowering.rb

require "prism"

# Map from dispatcher method name to (helper-name-prefix, return type).
# Return types are conservative T.untyped where the prefix is reused
# across different host classes with different return contracts (e.g.
# `visit_X` returns void in SemanticAnnotator but String in PipelineHost).
# Tighten to specific types in a manual pass when we sig the public API.
DISPATCHERS = {
  "emit"     => { prefix: "emit_",     returns: "String" },
  "visit"    => { prefix: "visit_",    returns: "T.untyped" },
  "lower"    => { prefix: "lower_",    returns: "T.untyped" },
  "transpile" => { prefix: "transpile_", returns: "String" },
}.freeze

# When true, every helper's param is `T.untyped` instead of the
# class extracted from the dispatch arm. Safer for bulk autogen
# because per-arm class typing surfaces sites where the helper
# was written assuming a wider node shape (e.g. respond_to? for
# attrs that exist on a sibling class). Tightening param types
# is a manual follow-up. Set false for high-precision runs.
LOOSE_PARAM_TYPES = ENV.fetch("AUTOGEN_LOOSE", "1") == "1"

# Extract the case/when dispatch arms from a Prism CaseNode. Returns
# an array of [helper_method_name, class_path_string] pairs. Skips
# arms that don't have a clean `helper(node)` body — those need
# manual sigging.
def extract_dispatch_arms(case_node)
  arms = []
  case_node.conditions.each do |when_node|
    next unless when_node.is_a?(Prism::WhenNode)
    statements = when_node.statements&.body || []
    # Body must be a single CallNode of the form `helper_name(arg)`
    next unless statements.length == 1
    call = statements.first
    next unless call.is_a?(Prism::CallNode)
    next if call.receiver  # `node.foo` — not a helper dispatch
    helper_name = call.name.to_s
    # Each `when` may match multiple class names (e.g., `when MIR::A, MIR::B`).
    # If multiple, the helper accepts a union — record that.
    classes = when_node.conditions.filter_map do |c|
      stringify_const(c)
    end
    next if classes.empty?
    # Single-class arm: helper expects that class.
    # Multi-class arm: helper expects T.any(...) — but for autogen we
    # union into the helper's existing class set.
    arms << [helper_name, classes]
  end
  arms
end

def stringify_const(node)
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

# Walk a method body to find a top-level case/when. Returns the
# dispatch arms or nil.
#
# The case may be the body's only statement, or wrapped — e.g.
# `case node ... end.tap { |mir| ... }` (mir_lowering.rb#lower) parses
# as CallNode whose receiver is the CaseNode. We do a shallow recursive
# search through receivers / blocks to find the first CaseNode.
def find_dispatch_arms(def_node)
  body = def_node.body
  return nil unless body.is_a?(Prism::StatementsNode)
  body.body.each do |stmt|
    case_node = find_case_node(stmt)
    return extract_dispatch_arms(case_node) if case_node
  end
  nil
end

def find_case_node(node)
  return node if node.is_a?(Prism::CaseNode)
  case node
  when Prism::CallNode
    found = node.receiver && find_case_node(node.receiver)
    return found if found
    return find_case_node(node.block) if node.block
  when Prism::BlockNode
    body = node.body
    if body.is_a?(Prism::StatementsNode)
      body.body.each do |s|
        f = find_case_node(s)
        return f if f
      end
    end
  end
  nil
end

# Build helper_name => Set<class_path> map from a single dispatcher def.
def build_helper_map(def_node)
  arms = find_dispatch_arms(def_node)
  return {} unless arms
  map = Hash.new { |h, k| h[k] = [] }
  arms.each do |helper, classes|
    map[helper].concat(classes)
  end
  map.transform_values(&:uniq)
end

def has_sig?(def_node, src_lines)
  # Look at the line immediately above the def. If it contains
  # `sig {` (possibly followed by attr modifiers), skip.
  line_idx = def_node.location.start_line - 2
  return false if line_idx < 0
  src_lines[line_idx]&.match?(/\s*sig\s*\{/)
end

ARGV.each do |file|
  parsed = Prism.parse_file(file)
  abort "parse failed: #{file}" unless parsed.success?
  src_lines = File.readlines(file)

  # Pass 1: find dispatcher methods, build maps for each helper-name-prefix.
  helper_maps = {}  # prefix => { helper_name => [class_paths...] }
  return_types = {} # prefix => String
  walk1 = nil
  walk1 = lambda do |node|
    if node.is_a?(Prism::DefNode) && DISPATCHERS.key?(node.name.to_s)
      cfg = DISPATCHERS[node.name.to_s]
      m = build_helper_map(node)
      helper_maps[cfg[:prefix]] = m
      return_types[cfg[:prefix]] = cfg[:returns]
    end
    node.respond_to?(:child_nodes) && node.child_nodes.compact.each { |c| walk1.(c) }
  end
  walk1.(parsed.value)

  # If a dispatcher exists but had no case/when (e.g. `def visit(node);
  # send("visit_#{class}", node); end`), still autogen helpers based on
  # the naming convention. Helper map stays empty (no per-arm class
  # info), but with LOOSE_PARAM_TYPES we use T.untyped anyway, so we
  # just need the prefix + return-type to be recognised.
  walk1b = nil
  walk1b = lambda do |node|
    if node.is_a?(Prism::DefNode) && DISPATCHERS.key?(node.name.to_s)
      cfg = DISPATCHERS[node.name.to_s]
      helper_maps[cfg[:prefix]] ||= {}  # empty map, but prefix is recognised
      return_types[cfg[:prefix]] = cfg[:returns]
    end
    node.respond_to?(:child_nodes) && node.child_nodes.compact.each { |c| walk1b.(c) }
  end
  walk1b.(parsed.value)

  if helper_maps.empty?
    warn "#{file}: no dispatcher methods found"
    next
  end

  # Pass 2: walk methods, find ones whose name matches a prefix +
  # helper map, insert sig if missing.
  inserts = []  # [insert_line_1based, sig_text]

  walk2 = nil
  walk2 = lambda do |node|
    if node.is_a?(Prism::DefNode)
      name = node.name.to_s
      helper_maps.each do |prefix, map|
        next unless name.start_with?(prefix)
        # Allow sigging even if the helper isn't in the dispatch map —
        # convention-based naming (`visit_X` → AST::X) covers send-style
        # dispatchers. With LOOSE_PARAM_TYPES the param type is T.untyped
        # regardless, so the missing class info is harmless.
        next unless map.key?(name) || LOOSE_PARAM_TYPES
        next if has_sig?(node, src_lines)
        # Build sig params for ALL method params (required, optional,
        # keyword, rest, kwrest, block). Param types default to T.untyped
        # for all but the first required param when LOOSE_PARAM_TYPES is
        # off, where the dispatch arm tells us the class.
        params = node.parameters
        next unless params

        first_required = params.requireds.first
        next unless first_required  # need at least one positional

        sig_params = []
        classes = map[name] || []
        first_done = false
        params.requireds.each do |p|
          pname = p.name.to_s
          ptype = if !first_done && !LOOSE_PARAM_TYPES
            classes.length == 1 ? classes.first : "T.any(#{classes.join(', ')})"
          else
            "T.untyped"
          end
          first_done = true
          sig_params << "#{pname}: #{ptype}"
        end
        params.optionals.each { |p| sig_params << "#{p.name}: T.untyped" }
        params.keywords.each do |kw|
          sig_params << "#{kw.name}: T.untyped"
        end
        if params.rest
          rest_name = params.rest.name&.to_s || "args"
          sig_params << "#{rest_name}: T.untyped"
        end
        if params.keyword_rest
          krest_name = params.keyword_rest.name&.to_s || "kwargs"
          sig_params << "#{krest_name}: T.untyped"
        end
        if params.block
          bname = params.block.name&.to_s || "blk"
          sig_params << "#{bname}: T.untyped"
        end

        ret_type = return_types[prefix]
        ret_clause = ret_type == ".void" ? "void" : "returns(#{ret_type})"
        sig_line = sig_params.empty? ?
          "sig { #{ret_clause} }" :
          "sig { params(#{sig_params.join(', ')}).#{ret_clause} }"
        # Indent matches the def line.
        def_line_idx = node.location.start_line - 1
        indent = src_lines[def_line_idx][/^\s*/]
        inserts << [node.location.start_line, "#{indent}#{sig_line}\n"]
      end
    end
    node.respond_to?(:child_nodes) && node.child_nodes.compact.each { |c| walk2.(c) }
  end
  walk2.(parsed.value)

  if inserts.empty?
    puts "#{file}: 0 sigs to add"
    next
  end

  inserts.sort_by { |line, _| -line }.each do |line, sig|
    src_lines.insert(line - 1, sig)
  end
  File.write(file, src_lines.join)
  puts "#{file}: +#{inserts.size} sigs"
end
