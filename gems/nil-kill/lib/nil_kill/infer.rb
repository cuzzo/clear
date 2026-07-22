# typed: false
# frozen_string_literal: true

module NilKill
  class Infer
    attr_reader :store

    def initialize(argv)
      @run_sorbet = !argv.include?("--no-sorbet")
      @store = Store.new
    end

    def run
      load_runtime
      index_sources
      load_sorbet if @run_sorbet
      build_flow_graph
      build_fallibility_pressure

      input_data = @store.to_h
      input_data["unused_return_methods_by_location"] = unused_return_methods_by_location.to_h { |k, v| [k.to_json, v] }
      input_data["facts"]["effective_struct_field_types"] = SlotCoverage.new([])
        .resolved_struct_field_types(input_data)
        .map { |(owner, field), type| { "owner" => owner, "field" => field, "type" => type } }
      delegate_to_rust(input_data)

      evidence = @store.to_h
      @store.write(evidence)
      Report.new([], evidence: evidence).run
    end

    def build_flow_graph
      @store.facts["flow_graph"] = FlowGraph.from_evidence(@store.to_h).to_h
    end

    def build_fallibility_pressure
      files = NilKill.target_files.select { |path| File.extname(path) == ".rb" }
      @store.facts["fallibility_pressure"] = FallibilityPressure.scan(
        files,
        runtime_methods: @store.methods.values,
        runtime_edges: @store.facts["runtime_call_edges"]
      )
    end

    def delegate_to_rust(input_data)
      require "tempfile"
      require "open3"
      temp_in = Tempfile.new(["infer_in", ".json"])
      temp_out = Tempfile.new(["infer_out", ".json"])
      begin
        temp_in.write(JSON.generate(input_data))
        temp_in.flush
        bin_path = rust_binary_path
        out, err, status = Open3.capture3(bin_path, temp_in.path, temp_out.path)
        abort "Rust inference failed:\n#{err}" unless status.success?
        output_data = JSON.parse(File.read(temp_out.path))
        @store.actions.concat(output_data["actions"] || [])
        if output_data["diagnostics"]
          output_data["diagnostics"].each { |k, v| @store.diagnostics[k] = v }
        end
      ensure
        temp_in.close
        temp_in.unlink
        temp_out.close
        temp_out.unlink
      end
    end

    def rust_binary_path
      env_path = ENV["NIL_KILL_INFER_RUST_BINARY"]
      return env_path unless env_path.nil? || env_path.empty?

      [
        File.join(ROOT, "gems/nil-kill/target/release/nil-kill-infer-rust"),
        File.join(ROOT, "gems/nil-kill/target/debug/nil-kill-infer-rust"),
        "nil-kill-infer-rust"
      ].find { |path| path == "nil-kill-infer-rust" || File.exist?(path) }
    end

    def load_runtime
      Runtime::Normalizer.new(root: ROOT).load_legacy_ruby!(@store, runtime_dir: RUNTIME_DIR)
    end

    def index_sources
      if ENV.fetch("NIL_KILL_SOURCE_INDEX_ENGINE", "static_analysis") == "static_analysis"
        StaticAnalysis.index_store(store: @store, targets: NilKill.target_dirs, root: ROOT)
        return
      end

      SourceIndex.reset_global_shape_indexes
      files = NilKill.target_files
      warm_only = ENV["NIL_KILL_IDX_WARM_ONLY"] != "0"
      files.each { |path| SourceIndex.new(path, warm_only: warm_only) }
      files.each { |path| SourceIndex.new(path, warm_only: true) } if warm_only
      reuse = ENV["NIL_KILL_IDX_REUSE"] != "0"
      cached = nil
      5.times do
        before = SourceIndex.noreturn_methods.size
        pass = reuse ? {} : nil
        files.each { |path| idx = SourceIndex.new(path); pass[path] = idx if reuse }
        if SourceIndex.noreturn_methods.size == before
          cached = pass
          break
        end
      end
      files.each do |path|
        idx = (cached && cached[path]) || SourceIndex.new(path)
        append_source_index_facts(idx, target: true)
        idx.methods.each do |method|
          rec = @store.method_record([method["class"], method["method"], method["kind"], File.expand_path(method["path"], ROOT), method["line"]])
          rec["source"] = method
          rec["has_sig"] = method["has_sig"]
        end
      end
      (NilKill.usage_scan_files - files).each do |path|
        append_source_index_facts(SourceIndex.new(path, usage_only: true), target: false)
      end
    end

    def append_source_index_facts(idx, target:)
      @store.facts["files"][idx.rel] = idx.summary if target
      @store.facts["unsigned_methods"].concat(idx.methods.reject { |m| m["has_sig"] }) if target
      @store.facts["existing_sigs"].concat(idx.methods.select { |m| m["has_sig"] }) if target
      @store.facts["tlet_sites"].concat(idx.tlet_sites) if target
      @store.facts["dead_nil_checks"].concat(idx.dead_nil_checks) if target
      @store.facts["deterministic_guards"].concat(idx.deterministic_guards) if target
      @store.facts["struct_declarations"].concat(idx.struct_declarations) if target
      @store.facts["struct_field_static"].concat(idx.struct_field_static) if target
      @store.facts["tuple_arrays"].concat(idx.tuple_arrays) if target
      @store.facts["hash_shapes"].concat(idx.hash_shapes) if target
      @store.facts["collection_index_lookups"].concat(idx.collection_index_lookups) if target
      @store.facts["hash_record_blockers"].concat(idx.hash_record_blockers) if target
      @store.facts["hash_record_member_calls"].concat(idx.hash_record_member_calls) if target
      @store.facts["type_normalizers"].concat(idx.type_normalizers) if target
      @store.facts["dispatcher_inferences"].concat(idx.dispatcher_inferences) if target
      @store.facts["return_origins"].concat(idx.return_origins) if target
      @store.facts["param_origins"].concat(idx.param_origins) if target
      (@store.facts["hash_record_escape_sites"] ||= []).concat(idx.hash_record_escape_sites) if target
      (@store.facts["hidden_enum_observations"] ||= []).concat(idx.hidden_enum_observations) if target
      (@store.facts["return_usage_sites"] ||= []).concat(idx.return_usage_sites)
      (@store.facts["return_direct_usage_sites"] ||= []).concat(idx.return_direct_usage_sites)
      (@store.facts["rescue_handlers"] ||= []).concat(idx.rescue_handlers)
      return unless target

      @store.facts["ivar_protocols"] ||= {}
      idx.ivar_protocols.each do |(klass, ivar), methods|
        key = "#{klass}\0#{ivar}"
        @store.facts["ivar_protocols"][key] ||= []
        @store.facts["ivar_protocols"][key] = (@store.facts["ivar_protocols"][key] + methods.to_a).uniq
      end
      @store.facts["ivar_param_origins"] ||= {}
      idx.ivar_param_origins.each do |(klass, ivar), sources|
        key = "#{klass}\0#{ivar}"
        @store.facts["ivar_param_origins"][key] ||= []
        @store.facts["ivar_param_origins"][key] = (@store.facts["ivar_param_origins"][key] + sources.to_a).uniq
      end
    end

    def load_sorbet
      _out, err, _status = Open3.capture3({ "SRB_YES" => "1", "NO_COLOR" => "1" }, "bundle", "exec", "srb", "tc")
      @store.diagnostics["sorbet_errors"] = parse_sorbet_errors(err)
      @store.diagnostics["nil_origins"] = parse_nil_origins(err)
      @store.diagnostics["sorbet_feedback"] = parse_sorbet_feedback(err)
    rescue Errno::ENOENT
      @store.diagnostics["sorbet_errors"] = []
      @store.diagnostics["sorbet_feedback"] = []
    end

    def parse_sorbet_errors(output)
      strip_ansi(output).lines.filter_map do |line|
        match = line.match(/\A([^:\n]+):(\d+):\s*(.*?)\s*(?:https:\/\/srb\.help\/(\d+))?\s*\z/)
        next unless match

        {
          "path" => match[1],
          "line" => match[2].to_i,
          "message" => match[3].strip,
          "code" => match[4].to_s,
        }
      end
    end

    def parse_nil_origins(output)
      counts = Hash.new(0)
      lines = strip_ansi(output).lines
      lines.each_with_index do |line, idx|
        next unless line.include?("NilClass")

        origin = lines[(idx + 1)..]&.find { |candidate| candidate.match?(/\A\s+[^:\s][^:]*:\d+:/) }
        next unless origin

        location = origin.strip.sub(/:\s*\z/, "")
        counts[location] += 1 unless location.empty?
      end
      counts.map { |origin, count| { "origin" => origin, "count" => count } }
    end

    def parse_sorbet_feedback(output)
      lines = strip_ansi(output).lines
      feedback = []
      lines.each_with_index do |line, idx|
        match = line.match(/\A([^:\n]+):(\d+):\s*(.*?)\s*https:\/\/srb\.help\/(\d+)\s*\z/)
        next unless match

        case match[4]
        when "7002"
          item = parse_argument_widening_feedback(lines, idx, match)
          feedback << item if item
        when "7005"
          item = parse_return_widening_feedback(lines, idx, match)
          feedback << item if item
        when "7034"
          item = parse_safe_navigation_feedback(lines, idx, match)
          feedback << item if item
        end
      end
      feedback
    end

    def parse_argument_widening_feedback(lines, idx, match)
      message = match[3].strip
      type_match = message.match(/Expected `(.+?)` but found `(.+?)` for argument `(.+?)`/)
      return nil unless type_match

      loc = following_sorbet_location(lines, idx)
      return nil unless loc

      {
        "code" => "7002",
        "path" => loc["path"],
        "line" => loc["line"],
        "site_path" => match[1],
        "site_line" => match[2].to_i,
        "arg" => type_match[3],
        "expected" => type_match[1],
        "found" => type_match[2],
        "message" => "widening argument #{type_match[3]} from #{type_match[1]} to #{type_match[2]}",
      }
    end

    def parse_return_widening_feedback(lines, idx, match)
      message = match[3].strip
      type_match = message.match(/Expected `(.+?)` but found `(.+?)` for method result type/)
      return nil unless type_match

      loc = following_sorbet_location(lines, idx)
      return nil unless loc

      {
        "code" => "7005",
        "path" => loc["path"],
        "line" => loc["line"],
        "site_path" => match[1],
        "site_line" => match[2].to_i,
        "expected" => type_match[1],
        "found" => type_match[2],
        "message" => "widening return from #{type_match[1]} to #{type_match[2]}",
      }
    end

    def parse_safe_navigation_feedback(lines, idx, match)
      loc = following_sorbet_location(lines, idx)
      return nil unless loc

      {
        "code" => "7034",
        "path" => loc["path"],
        "line" => loc["line"],
        "site_path" => match[1],
        "site_line" => match[2].to_i,
        "message" => "safe navigation receiver is non-nil",
      }
    end

    def following_sorbet_location(lines, idx)
      lines[(idx + 1)..]&.each do |line|
        next unless (match = line.match(/\A\s+([^:\s][^:]*\.rb):(\d+):\s*\z/))

        return { "path" => match[1], "line" => match[2].to_i }
      end
      nil
    end

    def strip_ansi(output)
      output.to_s.gsub(/\e\[[0-9;]*m/, "")
    end

    def method_location_key(method)
      [method["path"], method["line"].to_i, method["class"].to_s, method["method"].to_s, method["kind"].to_s]
    end

    def unused_return_methods_by_location
      unused_return_methods(@store.to_h).each_with_object({}) do |method, lookup|
        lookup[method_location_key(method)] = method
      end
    end

    def unused_return_methods(evidence)
      untyped_candidates = evidence["facts"]["existing_sigs"].select do |method|
        method["sig"].to_s.include?(".returns(T.untyped)") || method["sig"].to_s.include?(" returns(T.untyped)")
      end
      untyped_candidates_by_name = untyped_candidates.group_by { |method| method["method"].to_sym }
      all_candidates_by_name = Array(evidence.dig("facts", "existing_sigs")).select do |method|
        sig = method["sig"].to_s
        sig.match?(/\bvoid\b/) || NilKill.extract_return_type(sig)
      end.group_by { |method| method["method"].to_sym }
      candidate_names = all_candidates_by_name.select { |_name, methods| methods.size == 1 }.keys.to_set
      untyped_candidate_names = untyped_candidates_by_name.select { |name, methods| methods.size == 1 && candidate_names.include?(name) }.keys.to_set
      return [] if untyped_candidate_names.empty?

      used = Set.new
      return_edges = Hash.new { |hash, key| hash[key] = Set.new }

      # Fast path: use indexed return-usage facts when available
      if evidence.dig("facts", "return_usage_sites")&.any?
        method_return_types = unambiguous_method_return_types(evidence)
        evidence["facts"]["return_usage_sites"].each do |site|
          name = site["name"].to_s.to_sym
          next unless candidate_names.include?(name)
          context = site["context"].to_s
          current_method_name = site["current_method"].to_s
          current_method = current_method_name.empty? ? nil : current_method_name.to_sym
          if context == "return" && current_method && candidate_names.include?(current_method)
            ret_type = method_return_types[current_method]
            if ret_type && ret_type != "void" && ret_type != "T.untyped"
              used << name
            else
              return_edges[current_method] << name
            end
          elsif context == "return" && method_return_types[current_method] != "void"
            used << name
          elsif context == "value"
            used << name
          end
        end
        propagate_return_usage!(used, return_edges)
      else
        method_return_types = unambiguous_method_return_types(evidence)
        NilKill.usage_scan_files.each do |path|
          parsed = NilKill.cached_parse_file(path)
          next unless parsed.success?
          mark_return_usage_graph(parsed.value, :statement, nil, candidate_names, method_return_types, used, return_edges)
        end
        propagate_return_usage!(used, return_edges)
      end
      (untyped_candidate_names - used).filter_map { |name| untyped_candidates_by_name.fetch(name).first }
    end

    def unambiguous_method_return_types(evidence)
      by_name = Array(evidence.dig("facts", "existing_sigs")).group_by { |method| method["method"].to_sym }
      by_name.each_with_object({}) do |(name, methods), types|
        next unless methods.size == 1
        sig = methods.first["sig"].to_s
        types[name] = sig.include?("void") ? "void" : NilKill.extract_return_type(sig)
      end
    end

    def propagate_return_usage!(used, return_edges)
      changed = true
      while changed
        changed = false
        return_edges.each do |caller, callees|
          next unless used.include?(caller)
          callees.each do |callee|
            next if used.include?(callee)
            used << callee
            changed = true
          end
        end
      end
    end

    def mark_return_usage_graph(node, context, current_method, candidate_names, method_return_types, used, return_edges)
      return unless node
      case node
      when Syntax::DefNode
        mark_return_usage_graph(node.body, :return, node.name, candidate_names, method_return_types, used, return_edges)
      when Syntax::BodyStatementNode, Syntax::BeginNode
        mark_return_usage_graph(node.statements, context, current_method, candidate_names, method_return_types, used, return_edges)
      when Syntax::StatementsNode
        body = node.body || []
        body.each_with_index do |child, idx|
          child_context = idx == body.length - 1 ? context : :statement
          mark_return_usage_graph(child, child_context, current_method, candidate_names, method_return_types, used, return_edges)
        end
      when Syntax::ReturnNode
        node.child_nodes.compact.each { |child| mark_return_usage_graph(child, :return, current_method, candidate_names, method_return_types, used, return_edges) }
      when Syntax::ArgumentsNode
        node.child_nodes.compact.each { |child| mark_return_usage_graph(child, context, current_method, candidate_names, method_return_types, used, return_edges) }
      when Syntax::IfNode
        mark_return_usage_graph(node.predicate, :value, current_method, candidate_names, method_return_types, used, return_edges) if node.respond_to?(:predicate)
        mark_return_usage_graph(node.statements, context, current_method, candidate_names, method_return_types, used, return_edges)
        mark_return_usage_graph(node.subsequent, context, current_method, candidate_names, method_return_types, used, return_edges)
      when Syntax::ElseNode
        mark_return_usage_graph(node.statements, context, current_method, candidate_names, method_return_types, used, return_edges)
      when Syntax::CallNode
        if candidate_names.include?(node.name)
          if context == :return && current_method && candidate_names.include?(current_method)
            if typed_value_return?(method_return_types[current_method])
              used << node.name
            else
              return_edges[current_method] << node.name
            end
          elsif context == :return && method_return_types[current_method] != "void"
            used << node.name
          elsif context == :value
            used << node.name
          end
        end
        node.child_nodes.compact.each { |child| mark_return_usage_graph(child, :value, current_method, candidate_names, method_return_types, used, return_edges) }
      else
        node.child_nodes.compact.each { |child| mark_return_usage_graph(child, :value, current_method, candidate_names, method_return_types, used, return_edges) } if node.respond_to?(:child_nodes)
      end
    end

    def typed_value_return?(return_type)
      return_type && return_type != "void" && return_type != "T.untyped"
    end

end
end
