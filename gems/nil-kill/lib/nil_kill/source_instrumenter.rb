# typed: false
# frozen_string_literal: true

module NilKill
  class SourceInstrumenter
    def initialize
      @line_offsets = []
      @method_plans_by_file_line = Hash.new { |h, k| h[k] = {} }
      @tracepoint_methods = {}
      @trace_plan = File.exist?(TRACE_PLAN_PATH) ? JSON.parse(File.read(TRACE_PLAN_PATH)) : { "methods" => {} }
      @loop_sites = @trace_plan.fetch("loop_sites", {})
      @state_write_sites = @trace_plan.fetch("state_write_sites", {})
      @plan_dirty = false
      @defer_plan_write = false
      @trace_plan.fetch("methods", {}).each do |raw_key, plan|
        owner, method_id, kind, path, line = raw_key.split("\0", 5)
        next if plan && plan["sample"] == false && plan["frame"] == false
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
      @loop_sites ||= {}
      @state_write_sites ||= {}
      @plan_dirty = false
      @defer_plan_write = false
    end

    # Computed at call time, not load time: the spec suite resets
    # NilKill::RUNTIME_DIR per example (remove_const/const_set), so a
    # load-time constant would point at a stale tmp dir under isolation.
    def line_map_path
      File.join(NilKill::RUNTIME_DIR, ".nk-linemap.json")
    end

    # In-place instrumentation. Snapshot each target whose bytes actually
    # change into snapshot_dir, then overwrite that real file with its
    # instrumented form. Untouched files need neither a snapshot nor a write.
    # There is exactly ONE active copy of each instrumented file -- at
    # its real path -- so EVERY load
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
      @defer_plan_write = true
      begin
        NilKill.target_files.each do |path|
          rel = NilKill.rel(path)
          source = File.read(path)
          instrumented, line_map = instrument_file_with_map(path, source: source)
          next if instrumented.b == source.b

          snap = File.join(snapshot_dir, rel)
          FileUtils.mkdir_p(File.dirname(snap))
          File.binwrite(snap, source.b)
          File.binwrite(path, instrumented.b)
          @line_map[rel] = line_map if line_map
          manifest << rel
        end
      ensure
        @defer_plan_write = false
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
    def instrument_file_with_map(path, source: nil)
      source ||= File.read(path)
      abs_path = File.expand_path(path, ROOT)
      return [source, nil] unless instrumentable_source?(source, abs_path)
      state_writes = state_write_candidate?(source)
      @line_offsets = line_offsets(source)
      parsed = Syntax.parse(source)
      return [source, nil] unless parsed.success?
      edits = []
      collect_raw_file_edits(
        parsed,
        parsed.root,
        abs_path,
        edits,
        ivars: state_writes,
        loops: source.include?("while") || source.include?("until"),
        source_refs: source.include?("__LINE__")
      )
      write_tracepoint_fallback_plan
      return [source, nil] if edits.empty?
      kept = non_overlapping_edits(edits).sort_by { |s, _e, _r| s }
      instrumented = apply_normalized_edits(source, kept)
      src_line_count = source.lines.length
      instrumented_offsets = line_offsets(instrumented)
      total_instr_lines = instrumented_offsets.length
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
        instr_line_of_src[s] = line_number_for_byte(instrumented_offsets, instr_byte)
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
      abs_path = File.expand_path(path, ROOT)
      return source unless instrumentable_source?(source, abs_path)
      state_writes = state_write_candidate?(source)
      @line_offsets = line_offsets(source)
      parsed = Syntax.parse(source)
      return source unless parsed.success?
      edits = []
      collect_raw_file_edits(
        parsed,
        parsed.root,
        abs_path,
        edits,
        ivars: state_writes,
        loops: source.include?("while") || source.include?("until"),
        source_refs: source.include?("__LINE__")
      )
      write_tracepoint_fallback_plan
      return source if edits.empty?
      apply_edits(source, edits)
    end

    def instrumentable_source?(source, abs_path)
      @method_plans_by_file_line[abs_path].any? ||
        state_write_candidate?(source) || source.include?("while") ||
        source.include?("until") || source.include?("__LINE__")
    end

    # Conservative lexical gate only: false positives merely parse a file,
    # while every legal ordinary instance/class/global variable spelling is
    # admitted to the exact grammar traversal below. The old `include?("@")`
    # gate parsed documentation mentions and accidentally excluded global
    # writes in files with no ivars.
    def state_write_candidate?(source)
      source.match?(/@@?[A-Za-z_]/) || source.include?("$")
    end

    def line_offsets(source)
      offsets = [0]
      source.each_line.with_index do |line, idx|
        offsets[idx + 1] = offsets[idx] + line.bytesize
      end
      offsets
    end

    def line_number_for_byte(offsets, byte)
      low = 0
      high = offsets.length
      while low < high
        mid = (low + high) / 2
        if offsets[mid] <= byte
          low = mid + 1
        else
          high = mid
        end
      end
      [low, 1].max
    end

    # Collect every source transformation in one traversal. The previous
    # implementation independently walked the complete adapter tree for
    # methods, returns, state writes, loops, and __LINE__. On large targets
    # those repeated Ruby walks cost more than parsing and produced identical
    # information.
    def collect_raw_file_edits(context, raw, path, edits, ivars:, loops:, source_refs:, return_plan: nil)
      type = raw.type

      if ivars && (type == "assignment" || type == "operator_assignment")
        lhs = raw.child_by_field_name("left") || raw.named_children.first
        if lhs && %w[instance_variable class_variable global_variable].include?(lhs.type)
          value = raw.child_by_field_name("value") || raw.named_children.last
          if value
            name = context.source.byteslice(lhs.start_byte...lhs.end_byte)
            normalized_name = name.sub(/\A@/, "")
            site_key = [path, raw.start_point.row + 1, normalized_name].join("\0")
            unless @state_write_sites[site_key] == false
              rhs = context.source.byteslice(value.start_byte...value.end_byte)
              replacement = "NilKillRuntimeTrace.record_ivar_assignment(self, #{name.inspect}, (#{rhs}), __FILE__, __LINE__)"
              edits << [value.start_byte, value.end_byte, replacement]
            end
          end
        end
      end

      if loops && (type == "while" || type == "until")
        key = [path, raw.start_point.row + 1].join("\0")
        unless @loop_sites[key]
          @loop_sites[key] = true
          @plan_dirty = true
        end
      end

      if source_refs && type == "identifier" && context.source.byteslice(raw.start_byte...raw.end_byte) == "__LINE__"
        edits << [raw.start_byte, raw.end_byte, (raw.start_point.row + 1).to_s]
      end

      case type
      when "method", "singleton_method"
        node = context.wrap(raw)
        plan = @method_plans_by_file_line[path][raw.start_point.row + 1]
        active_plan = nil
        if plan
          # Endless defs have no `end` anchor and retain the TracePoint
          # fallback. Classic one-line defs still have an anchor.
          ek = node.end_keyword_loc
          ek = nil if ek && ek.length.zero?
          if ek.nil?
            @tracepoint_methods[plan.fetch("raw_key")] = plan.fetch("plan")
            @plan_dirty = true
          else
            insert_method_wrapper(node, plan, edits)
            active_plan = plan
          end
        end

        # A return is owned only by this method's body, never by its
        # parameters/defaults or an enclosing method. Visit the body first so
        # the shared visited set does not encounter it through child_nodes
        # with the wrong return scope.
        body = raw.child_by_field_name("body") || context.children(raw).find { |child| child.type == "body_statement" }
        collect_raw_file_edits(
          context,
          body,
          path,
          edits,
          ivars: ivars,
          loops: loops,
          source_refs: source_refs,
          return_plan: active_plan
        ) if body
        context.children(raw).each do |child|
          next if body && same_raw_node?(child, body)
          collect_raw_file_edits(
            context,
            child,
            path,
            edits,
            ivars: ivars,
            loops: loops,
            source_refs: source_refs,
            return_plan: nil
          )
        end
        return
      when "class", "module", "lambda"
        return_plan = nil
      when "return"
        if return_plan
          node = context.wrap(raw)
          add_return_edit(node, return_plan, edits)
          return
        end
      end

      # `lambda { ... }` owns its returns even though the adapter represents
      # it as a call with a block rather than a LambdaNode.
      if %w[call command command_call].include?(type) && raw_lambda_call?(context, raw)
        return_plan = nil
      end

      context.children(raw).each do |child|
        collect_raw_file_edits(
          context,
          child,
          path,
          edits,
          ivars: ivars,
          loops: loops,
          source_refs: source_refs,
          return_plan: return_plan
        )
      end
    end

    def same_raw_node?(left, right)
      left.type == right.type && left.start_byte == right.start_byte && left.end_byte == right.end_byte
    end

    def raw_lambda_call?(context, raw)
      method = raw.child_by_field_name("method")
      block = raw.child_by_field_name("block")
      method && block && context.source.byteslice(method.start_byte...method.end_byte) == "lambda"
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
      prefix = "\n#{body_indent}#{call}\n#{body_indent}begin\n#{body_indent}  __nil_kill_result = begin\n"
      suffix = "#{body_indent}  end\n#{body_indent}  #{ret}\n#{body_indent}rescue Exception => __nil_kill_error\n#{body_indent}  #{raise_call}\n#{body_indent}  raise\n#{body_indent}end\n"
      edits << [header_end, header_end, prefix]
      edits << [end_anchor, end_anchor, suffix]
    end

    def method_header_end_offset(node)
      loc = node.rparen_loc || node.parameters&.location || node.name_loc || node.location
      loc.start_offset + loc.length
    end

    def add_return_edit(node, plan, edits)
      args = node.arguments&.arguments || []
      expr =
        if args.empty?
          "nil"
        elsif args.size == 1
          args.first.slice
        else
          args.map(&:slice).join(", ")
        end
      replacement = "return NilKillRuntimeTrace.record_source_method_return(#{plan["class"].inspect}, #{plan["method"].inspect}, #{plan["kind"].inspect}, __FILE__, #{plan["line"]}, (#{expr}))"
      edits << [node.location.start_offset, node.location.end_offset, replacement]
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

    def apply_edits(source, edits)
      apply_normalized_edits(source, non_overlapping_edits(edits))
    end

    def apply_normalized_edits(source, edits)
      bytes = source.b
      parts = []
      cursor = 0
      edits.sort_by { |start_offset, end_offset, _replacement| [start_offset, end_offset] }.each do |start_offset, end_offset, replacement|
        parts << bytes.byteslice(cursor, start_offset - cursor).to_s if start_offset > cursor
        parts << replacement.b
        cursor = end_offset
      end
      parts << bytes.byteslice(cursor..).to_s
      parts.join
    end

    def write_tracepoint_fallback_plan
      return if @defer_plan_write || !@plan_dirty
      @trace_plan["tracepoint_methods"] = @tracepoint_methods
      @trace_plan["loop_sites"] = @loop_sites
      FileUtils.mkdir_p(File.dirname(TRACE_PLAN_PATH))
      File.write(TRACE_PLAN_PATH, JSON.pretty_generate(@trace_plan))
      @plan_dirty = false
    end

    def non_overlapping_edits(edits)
      kept = []
      covered_until = -1
      edits.sort_by { |start_offset, end_offset, _replacement| [start_offset, -(end_offset - start_offset)] }.each do |edit|
        start_offset, end_offset, = edit
        if start_offset == end_offset
          kept << edit
          next
        end
        next if end_offset <= covered_until
        kept << edit
        covered_until = end_offset if end_offset > covered_until
      end
      kept
    end
  end
end
