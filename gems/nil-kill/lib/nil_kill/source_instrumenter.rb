# typed: false
# frozen_string_literal: true

module NilKill
  class SourceInstrumenter
    def initialize
      @line_offsets = []
      @method_plans_by_file_line = Hash.new { |h, k| h[k] = {} }
      @tracepoint_methods = {}
      @trace_plan = File.exist?(TRACE_PLAN_PATH) ? JSON.parse(File.read(TRACE_PLAN_PATH)) : { "methods" => {} }
      @trace_plan.fetch("methods", {}).each do |raw_key, plan|
        owner, method_id, kind, path, line = raw_key.split("\0", 5)
        next if plan && plan["sample"] == false
        @method_plans_by_file_line[File.expand_path(path, ROOT)][line.to_i] = {
          "class" => owner,
          "method" => method_id,
          "kind" => kind,
          "line" => line.to_i,
          "plan" => plan || {},
          "raw_key" => raw_key,
        }
      end
    rescue JSON::ParserError
      @trace_plan = { "methods" => {} }
      @method_plans_by_file_line ||= Hash.new { |h, k| h[k] = {} }
      @tracepoint_methods ||= {}
    end

    # Computed at call time, not load time: the spec suite resets
    # NilKill::RUNTIME_DIR per example (remove_const/const_set), so a
    # load-time constant would point at a stale tmp dir under isolation.
    def line_map_path
      File.join(NilKill::RUNTIME_DIR, ".nk-linemap.json")
    end

    # In-place instrumentation. Snapshot every pristine target file
    # into snapshot_dir, then OVERWRITE the real file with its
    # instrumented form. There is exactly ONE copy of each file -- at
    # its real path -- and it is always wrapped, so EVERY load
    # mechanism (require, require_relative, Kernel#load, autoload,
    # absolute require, a bare `ruby file.rb` entrypoint, a re-exec, an
    # RUBYOPT-armed spawn) loads the wrapped code. "ran" (Ruby
    # Coverage) and "recorded" (the injected recorder) become the same
    # event in the same file: the collect_ran_untraced reachability gap
    # is closed by construction, not patched per load path.
    #
    # The instrumented->src line map is still required (the wrapper
    # injects lines, shifting every later one) and is keyed by the REAL
    # ROOT-relative path. Returns the manifest of restored-by rel paths.
    def run_in_place(snapshot_dir)
      FileUtils.mkdir_p(snapshot_dir)
      @line_map = {}
      manifest = []
      NilKill.target_files.each do |path|
        rel = NilKill.rel(path)
        snap = File.join(snapshot_dir, rel)
        FileUtils.mkdir_p(File.dirname(snap))
        FileUtils.cp(path, snap)
        instrumented, line_map = instrument_file_with_map(path)
        File.write(path, instrumented)
        @line_map[rel] = line_map if line_map
        manifest << rel
      end
      FileUtils.mkdir_p(File.dirname(line_map_path))
      File.write(line_map_path, JSON.generate(@line_map))
      write_tracepoint_fallback_plan
      manifest
    end

    # Exact instrumented_line -> src_line, derived from the byte-offset
    # edits (not line equality, which drifts past modified lines).
    # Every src line start maps to an instrumented byte = src byte +
    # net bytes inserted by edits before it; injected lines inherit
    # the preceding src line (their tracing belongs to that code).
    def instrument_file_with_map(path)
      source = File.read(path)
      @line_offsets = line_offsets(source)
      parsed = Prism.parse(source)
      return [source, nil] unless parsed.success?
      edits = []
      collect_ivar_assignment_edits(parsed.value, edits)
      collect_method_edits(parsed.value, File.expand_path(path, ROOT), edits)
      collect_source_ref_edits(parsed.value, edits, File.expand_path(path, ROOT))
      write_tracepoint_fallback_plan
      return [source, nil] if edits.empty?
      kept = non_overlapping_edits(edits).sort_by { |s, _e, _r| s }
      instrumented = apply_edits(source, edits)
      src_line_count = source.lines.length
      total_instr_lines = instrumented.count("\n") + 1
      # src line -> instrumented line of that line's first byte
      instr_line_of_src = []
      delta = 0 # net bytes inserted before the current scan offset
      ei = 0
      (1..@line_offsets.length).each do |s|
        src_byte = @line_offsets[s - 1]
        while ei < kept.length && kept[ei][0] <= src_byte
          so, eo, rep = kept[ei]
          delta += rep.b.bytesize - (eo - so)
          ei += 1
        end
        instr_byte = src_byte + delta
        instr_line_of_src[s] = instrumented.byteslice(0, instr_byte).to_s.count("\n") + 1
      end
      map = []
      s = 1
      (1..total_instr_lines).each do |i|
        s += 1 while s + 1 <= @line_offsets.length && instr_line_of_src[s + 1] && instr_line_of_src[s + 1] <= i
        map[i] = s > src_line_count ? src_line_count : s
      end
      [instrumented, map]
    end

    def instrument_file(path)
      source = File.read(path)
      @line_offsets = line_offsets(source)
      parsed = Prism.parse(source)
      return source unless parsed.success?
      edits = []
      collect_ivar_assignment_edits(parsed.value, edits)
      collect_method_edits(parsed.value, File.expand_path(path, ROOT), edits)
      collect_source_ref_edits(parsed.value, edits, File.expand_path(path, ROOT))
      write_tracepoint_fallback_plan
      return source if edits.empty?
      apply_edits(source, edits)
    end

    def line_offsets(source)
      offsets = [0]
      source.each_line.with_index do |line, idx|
        offsets[idx + 1] = offsets[idx] + line.bytesize
      end
      offsets
    end

    def collect_method_edits(node, path, edits)
      case node
      when Prism::DefNode
        plan = @method_plans_by_file_line[path][node.location.start_line]
        return unless plan
        # Endless defs (`def f = expr`) have no `end` keyword to anchor
        # the suffix; fall back to TracePoint. One-line classic defs
        # (`def f; ...; end`) DO have an `end` and are wrappable -- the
        # suffix anchors on end_keyword_loc, not the end line start.
        ek = node.end_keyword_loc
        # Punt ONLY shapes the inline wrapper genuinely cannot express:
        # endless defs (no `end` to anchor the suffix) and `ensure`.
        # - A `return` inside an iterator / `proc` block is a NON-LOCAL
        #   method return: rewritten to `throw __nil_kill_return_tag`,
        #   stays source-wrapped.
        # - A `return` LOCAL to a lambda returns from the lambda, not
        #   the method, so it never reaches the wrapper's catch -- the
        #   method is still safely wrapped; we only must NOT rewrite
        #   that return (collect_return_edits skips lambda scopes).
        # The TracePoint fallback is unreliable in the real
        # multi-process collect; inline wrappers are not.
        ek = nil if ek && ek.length.zero?
        if ek.nil? || contains_ensure?(node.body)
          @tracepoint_methods[plan.fetch("raw_key")] = plan.fetch("plan")
          return
        end
        insert_method_wrapper(node, plan, edits)
        collect_return_edits(node.body, plan, edits)
        return
      end
      node.child_nodes.compact.each { |child| collect_method_edits(child, path, edits) } if node.respond_to?(:child_nodes)
    end

    def insert_method_wrapper(node, plan, edits)
      start_line = node.location.start_line
      end_line = node.location.end_line
      body_indent = "  "
      header_end = method_header_end_offset(node)
      # Anchor the suffix immediately before the def's `end` keyword.
      # Works for one-line defs too (where the end-line start would
      # point at the `def`, not before `end`).
      end_anchor = node.end_keyword_loc.start_offset
      params_expr = source_params_expr(plan)
      call = "NilKillRuntimeTrace.record_source_method_call(#{plan["class"].inspect}, #{plan["method"].inspect}, #{plan["kind"].inspect}, __FILE__, #{plan["line"]}, #{params_expr})"
      raise_call = "NilKillRuntimeTrace.record_source_method_raise(#{plan["class"].inspect}, #{plan["method"].inspect}, #{plan["kind"].inspect}, __FILE__, #{plan["line"]}, __nil_kill_error)"
      ret = "NilKillRuntimeTrace.record_source_method_return(#{plan["class"].inspect}, #{plan["method"].inspect}, #{plan["kind"].inspect}, __FILE__, #{plan["line"]}, __nil_kill_result)"
      prefix = "\n#{body_indent}__nil_kill_return_tag = Object.new\n#{body_indent}#{call}\n#{body_indent}begin\n#{body_indent}  catch(__nil_kill_return_tag) do\n#{body_indent}    __nil_kill_result = begin\n"
      suffix = "#{body_indent}    end\n#{body_indent}    #{ret}\n#{body_indent}  end\n#{body_indent}rescue Exception => __nil_kill_error\n#{body_indent}  #{raise_call}\n#{body_indent}  raise\n#{body_indent}end\n"
      edits << [header_end, header_end, prefix]
      edits << [end_anchor, end_anchor, suffix]
    end

    # Under in-place instrumentation the file IS at its real src path,
    # so __FILE__ and __dir__ already resolve correctly with NO rewrite
    # (the parallel-tree problem -- and its SourceFileNode/__dir__
    # rewrites -- are gone). Only __LINE__ still needs literalising:
    # the injected wrapper shifts every later line, so a raw __LINE__
    # would yield the instrumented line, not the src line.
    def collect_source_ref_edits(node, edits, _real_file = nil)
      if node.is_a?(Prism::SourceLineNode)
        edits << [node.location.start_offset, node.location.end_offset, node.location.start_line.to_s]
      end
      node.child_nodes.compact.each { |child| collect_source_ref_edits(child, edits, _real_file) } if node.respond_to?(:child_nodes)
    end

    def method_header_end_offset(node)
      loc = node.rparen_loc || node.parameters&.location || node.name_loc || node.location
      loc.start_offset + loc.length
    end

    def contains_ensure?(node)
      return false unless node
      return false if node.is_a?(Prism::DefNode) || node.is_a?(Prism::ClassNode) || node.is_a?(Prism::ModuleNode)
      return true if node.is_a?(Prism::EnsureNode)
      node.respond_to?(:child_nodes) && node.child_nodes.compact.any? { |child| contains_ensure?(child) }
    end


    def collect_return_edits(node, plan, edits)
      return unless node
      case node
      when Prism::DefNode, Prism::ClassNode, Prism::ModuleNode, Prism::LambdaNode
        # New scope: a `return` here belongs to it, not this method.
        # We DO recurse into BlockNode now so non-local `return`s inside
        # `do..end` / `{}` iterator and `proc` blocks are rewritten to a
        # tagged throw -- equivalent to the non-local method return, and
        # the value flows to record_source_method_return. Lambda scopes
        # are excluded here and below (lambda-local return is left as-is
        # -- it does not escape the wrapper).
        return
      when Prism::ReturnNode
        args = node.arguments&.arguments || []
        expr =
          if args.empty?
            "nil"
          elsif args.size == 1
            args.first.slice
          else
            args.map(&:slice).join(", ")
          end
        replacement = "throw __nil_kill_return_tag, NilKillRuntimeTrace.record_source_method_return(#{plan["class"].inspect}, #{plan["method"].inspect}, #{plan["kind"].inspect}, __FILE__, #{plan["line"]}, (#{expr}))"
        edits << [node.location.start_offset, node.location.end_offset, replacement]
        return
      end
      # `lambda { ... }` body is lambda-scoped: do NOT rewrite its local
      # returns. Skip the whole call subtree; the caller's recursion
      # still walks siblings.
      return if node.is_a?(Prism::CallNode) && node.name == :lambda && node.block.is_a?(Prism::BlockNode)
      node.child_nodes.compact.each { |child| collect_return_edits(child, plan, edits) } if node.respond_to?(:child_nodes)
    end

    def source_params_expr(plan)
      params = plan.fetch("plan", {}).fetch("params", {})
      names = params.select { |_name, sample| sample }.keys
      return "{}" if names.empty?
      "{ #{names.map { |name| "#{name.inspect} => #{name}" }.join(", ")} }"
    end

    def start_line_offset(line)
      @line_offsets[line - 1] || 0
    end

    def end_line_offset(line)
      @line_offsets[line] ? @line_offsets[line] - 1 : @line_offsets.last.to_i
    end

    def collect_ivar_assignment_edits(node, edits)
      case node
      when Prism::InstanceVariableWriteNode, Prism::ClassVariableWriteNode, Prism::GlobalVariableWriteNode
        value = node.value
        if value&.location
          name = node.name.to_s
          rhs = value.slice
          replacement = "NilKillRuntimeTrace.record_ivar_assignment(self, #{name.inspect}, (#{rhs}), __FILE__, __LINE__)"
          edits << [value.location.start_offset, value.location.end_offset, replacement]
        end
      end
      node.child_nodes.compact.each { |child| collect_ivar_assignment_edits(child, edits) } if node.respond_to?(:child_nodes)
    end

    def apply_edits(source, edits)
      bytes = source.b
      edits = non_overlapping_edits(edits)
      edits.sort_by { |start_offset, _end_offset, _replacement| -start_offset }.each do |start_offset, end_offset, replacement|
        bytes = bytes.byteslice(0, start_offset) + replacement.b + bytes.byteslice(end_offset..).to_s
      end
      bytes
    end

    def write_tracepoint_fallback_plan
      return if @tracepoint_methods.empty?
      @trace_plan["tracepoint_methods"] = @tracepoint_methods
      FileUtils.mkdir_p(File.dirname(TRACE_PLAN_PATH))
      File.write(TRACE_PLAN_PATH, JSON.pretty_generate(@trace_plan))
    end

    def non_overlapping_edits(edits)
      kept = []
      edits.sort_by { |start_offset, end_offset, _replacement| [start_offset, -(end_offset - start_offset)] }.each do |edit|
        start_offset, end_offset, = edit
        if start_offset == end_offset
          kept << edit
          next
        end
        next if kept.any? { |kept_start, kept_end, _| start_offset >= kept_start && end_offset <= kept_end }
        kept << edit
      end
      kept
    end
  end
end
