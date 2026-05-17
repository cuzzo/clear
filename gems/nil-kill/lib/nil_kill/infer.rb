# typed: false
# frozen_string_literal: true

module NilKill
  class Infer
    def initialize(argv)
      @run_sorbet = !argv.include?("--no-sorbet")
      @store = Store.new
    end

    def run
      load_runtime
      index_sources
      load_sorbet if @run_sorbet
      build_actions
      sorbet_validate_high_actions! if @run_sorbet
      build_flow_graph
      @store.write
      Report.new.run
    end

    def load_runtime
      Dir.glob(File.join(RUNTIME_DIR, "methods-*.jsonl")).each do |file|
        File.foreach(file) do |line|
          obs = JSON.parse(line)
          next unless NilKill.target_path?(obs["path"])
          key = [obs["class"], obs["method"], obs["kind"], obs["path"], obs["line"]]
          rec = @store.method_record(key)
          rec["calls"] += obs["calls"].to_i
          rec["ok_calls"] += obs["ok_calls"].to_i
          rec["raised_calls"] += obs["raised_calls"].to_i
          %w[returns return_elem raised].each { |k| rec[k] = (rec[k] + Array(obs[k])).uniq.sort }
          merge_hash_sets(rec["params_by_name"], obs["params_by_name"])
          merge_hash_sets(rec["params_ok"], obs["params_ok"])
          merge_hash_sets(rec["params_raised"], obs["params_raised"])
          merge_hash_counts(rec["param_sites"], obs["param_sites"])
          merge_hash_counts(rec["param_sites_ok"], obs["param_sites_ok"])
          merge_hash_counts(rec["param_sites_raised"], obs["param_sites_raised"])
          merge_hash_counts(rec["param_traces"], obs["param_traces"])
          merge_hash_counts(rec["param_traces_ok"], obs["param_traces_ok"])
          merge_hash_counts(rec["param_traces_raised"], obs["param_traces_raised"])
          merge_hash_sets(rec["param_elem"], obs["param_elem"])
          merge_hash_kv(rec["param_kv"], obs["param_kv"])
          merge_hash_shapes(rec["param_elem_shapes"], obs["param_elem_shapes"])
          merge_hash_kv_shapes(rec["param_kv_shapes"], obs["param_kv_shapes"])
          merge_kv(rec["return_kv"], obs["return_kv"])
          merge_shapes(rec["return_elem_shapes"], obs["return_elem_shapes"])
          merge_kv_shapes(rec["return_kv_shapes"], obs["return_kv_shapes"])
        end
      end
      Dir.glob(File.join(RUNTIME_DIR, "tlets-*.jsonl")).each do |file|
        File.foreach(file) do |line|
          obs = JSON.parse(line)
          next unless NilKill.target_path?(obs["path"])
          key = "#{obs["path"]}:#{obs["line"]}"
          rec = (@store.tlets[key] ||= { "path" => obs["path"], "line" => obs["line"], "calls" => 0, "classes" => [] })
          rec["calls"] += obs["calls"].to_i
          rec["classes"] = (rec["classes"] + Array(obs["classes"])).uniq.sort
        end
      end
      Dir.glob(File.join(RUNTIME_DIR, "structs-*.jsonl")).each do |file|
        File.foreach(file) do |line|
          obs = JSON.parse(line)
          next unless NilKill.target_path?(obs["path"])
          @store.facts["struct_field_runtime"] ||= []
          @store.facts["struct_field_runtime"] << obs
        end
      end
      Dir.glob(File.join(RUNTIME_DIR, "ivars-*.jsonl")).each do |file|
        File.foreach(file) do |line|
          obs = JSON.parse(line)
          @store.facts["ivar_runtime"] ||= []
          @store.facts["ivar_runtime"] << obs
        end
      end
      cov = Hash.new { |h, k| h[k] = [] }
      Dir.glob(File.join(RUNTIME_DIR, "coverage-*.jsonl")).each do |file|
        File.foreach(file) do |line|
          obs = JSON.parse(line)
          next unless NilKill.target_path?(obs["path"])
          cov[NilKill.rel(obs["path"])].concat(Array(obs["lines"]))
        end
      end
      @store.facts["collect_coverage"] = cov.transform_values { |ls| ls.uniq.sort } unless cov.empty?
      Dir.glob(File.join(RUNTIME_DIR, "tuples-*.jsonl")).each do |file|
        File.foreach(file) do |line|
          obs = JSON.parse(line)
          next unless NilKill.target_path?(obs["path"])
          @store.facts["tuple_runtime"] ||= []
          @store.facts["tuple_runtime"] << obs
        end
      end
      Dir.glob(File.join(RUNTIME_DIR, "collections-*.jsonl")).each do |file|
        File.foreach(file) do |line|
          obs = JSON.parse(line)
          next unless NilKill.target_path?(obs["path"])
          @store.facts["collection_runtime"] ||= []
          @store.facts["collection_runtime"] << obs
        end
      end
    end

    def index_sources
      SourceIndex.reset_global_shape_indexes
      files = NilKill.target_files
      files.each { |path| SourceIndex.new(path) }
      # Propagate cross-file T.noreturn until the global set stabilises.
      # Each pass picks up methods whose body resolves to noreturn via
      # calls to methods registered by an earlier pass. Bounded at 5
      # iterations -- typical chain depth is 1-2.
      5.times do
        before = SourceIndex.noreturn_methods.size
        files.each { |path| SourceIndex.new(path) }
        break if SourceIndex.noreturn_methods.size == before
      end
      files.each do |path|
        idx = SourceIndex.new(path)
        @store.facts["files"][NilKill.rel(path)] = idx.summary
        @store.facts["unsigned_methods"].concat(idx.methods.reject { |m| m["has_sig"] })
        @store.facts["existing_sigs"].concat(idx.methods.select { |m| m["has_sig"] })
        @store.facts["tlet_sites"].concat(idx.tlet_sites)
        @store.facts["dead_nil_checks"].concat(idx.dead_nil_checks)
        @store.facts["struct_declarations"].concat(idx.struct_declarations)
        @store.facts["struct_field_static"].concat(idx.struct_field_static)
        @store.facts["tuple_arrays"].concat(idx.tuple_arrays)
        @store.facts["hash_shapes"].concat(idx.hash_shapes)
        @store.facts["collection_index_lookups"].concat(idx.collection_index_lookups)
        @store.facts["hash_record_blockers"].concat(idx.hash_record_blockers)
        @store.facts["hash_record_member_calls"].concat(idx.hash_record_member_calls)
        @store.facts["type_normalizers"].concat(idx.type_normalizers)
        @store.facts["dispatcher_inferences"].concat(idx.dispatcher_inferences)
        @store.facts["return_origins"].concat(idx.return_origins)
        @store.facts["param_origins"].concat(idx.param_origins)
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
        idx.methods.each do |method|
          rec = @store.method_record([method["class"], method["method"], method["kind"], File.expand_path(method["path"], ROOT), method["line"]])
          rec["source"] = method
          rec["has_sig"] = method["has_sig"]
        end
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

    def build_actions
      unused_return_methods = unused_return_methods_by_location
      enrich_return_origins_with_receiver_inference!
      enrich_return_origins_with_callee_propagation!
      @store.methods.each_value do |rec|
        src = rec["source"]
        next unless src
        report_bad_input_candidates(rec, src)
        report_nil_param_candidates(rec, src)
        report_union_candidates(rec, src)
        rec["has_sig"] ? validate_sig(rec, src, unused_return_methods) : propose_sig(rec, src)
      end
      propose_dispatcher_inference_actions
      propose_static_param_backflow_actions
      propose_forwarded_return_chain_actions
      propose_hash_record_struct_actions
      propose_hash_record_cluster_actions
      propose_struct_field_sig_actions
      @store.facts["tlet_sites"].each { |site| propose_tlet_action(site) }
      @store.facts["dead_nil_checks"].each do |finding|
        if finding["kind"] == "nil_check"
          @store.actions << base_action("replace_dead_nil_check", REVIEW, finding["path"], finding["line"], finding["reason"],
            { "code" => finding["code"] })
        else
          @store.actions << base_action("remove_dead_safe_nav", REVIEW, finding["path"], finding["line"], finding["reason"],
            { "code" => finding["code"] })
        end
      end
      @store.diagnostics["sorbet_errors"].each do |diag|
        kind = %w[7002 7003 7005 7007].include?(diag["code"]) ? "annotation_conflict" : "sorbet_warning"
        conf = kind == "annotation_conflict" ? REVIEW : GAP
        @store.actions << base_action(kind, conf, diag["path"], diag["line"],
          "Sorbet #{diag["code"]}: #{diag["message"]}", { "code" => diag["code"] })
      end
      @store.diagnostics["sorbet_feedback"].each do |feedback|
        @store.actions << base_action("sorbet_feedback_widening", REVIEW, feedback["path"], feedback["line"],
          feedback["message"], feedback)
      end
    end

    STRUCT_FIELD_RBI_PATH = "sorbet/rbi/ast-struct-fields.rbi"

    # One `add_struct_field_sig` action per typeable struct field, fed
    # through the SAME verified loop (apply_verified) that bisects every
    # other action. This replaces struct-rbi's all-or-nothing
    # error-parse-blocklist convergence: the loop applies the maximal
    # srb-tc-clean subset and skips (surfaces) only the few fields whose
    # typing breaks srb tc -- no full revert, and blocked slots become
    # first-class REVIEW actions the report already counts/prioritises.
    def propose_struct_field_sig_actions
      candidates = Report.new.struct_field_candidates(
        Array(@store.facts["struct_field_runtime"]), Array(@store.facts["struct_field_static"])
      )
      already = SourceIndex.rbi_field_types
      candidates.each do |c|
        type = c["type"].to_s
        next if type.empty? || type == "T.untyped"
        klass = c["class"].to_s
        field = c["field"].to_s
        next if klass.empty? || field.empty?
        existing = already[[klass, field]].to_s
        next if NilKill.useful_type?(existing) # already typed in an RBI
        @store.actions << base_action("add_struct_field_sig", REVIEW, STRUCT_FIELD_RBI_PATH, 1,
          "type #{klass}##{field} as #{type} (struct field RBI)",
          { "class" => klass, "field" => field, "type" => type })
      end
    end

    def propose_hash_record_struct_actions
      shapes_by_site = Array(@store.facts["hash_shapes"]).each_with_object({}) do |shape, index|
        index[[shape["path"], shape["line"].to_i, shape["code"].to_s]] = shape
      end
      lookups = Array(@store.facts["collection_index_lookups"]).select do |lookup|
        origin = lookup["origin"] || {}
        origin["kind"] == "hash literal" &&
          lookup["path"] == origin["path"] &&
          literal_hash_read_code?(lookup["code"], lookup["receiver"], lookup["index"]) &&
          NilKill.useful_type?(lookup["lookup_type"])
      end
      lookups.group_by { |lookup| [lookup.dig("origin", "path"), lookup.dig("origin", "line").to_i, lookup.dig("origin", "name"), lookup.dig("origin", "code").to_s] }.each do |(path, line, name, code), group|
        next if path.to_s.empty? || line <= 0 || name.to_s.empty? || code.to_s.empty?
        shape = shapes_by_site[[path, line, code]]
        next unless shape
        fields = hash_record_struct_fields(shape)
        next if fields.size < 2
        struct_name = hash_record_struct_name(name)
        read_rewrites = group.filter_map { |lookup| hash_record_read_rewrite(lookup) }.uniq { |rw| [rw["line"], rw["code"]] }
        signatures = hash_record_local_param_signatures(path, name, shape, struct_name)
        read_rewrites.concat(hash_record_param_read_rewrites(path, signatures, shape))
        read_rewrites.uniq! { |rw| [rw["line"], rw["code"]] }
        next if read_rewrites.empty?
        blockers = hash_record_field_blockers(fields) + hash_record_param_signature_blockers(signatures)
        @store.actions << base_action("promote_hash_record_to_struct", REVIEW, path, line,
          "promote local hash record #{name} to #{struct_name}; rewrite #{read_rewrites.size} literal field read(s)",
          { "name" => name, "struct_name" => struct_name, "scope" => group.first["enclosing_scope"].to_s.split("::").reject(&:empty?),
            "literal" => { "line" => line, "code" => code },
            "fields" => fields, "read_rewrites" => read_rewrites, "signatures" => signatures,
            "nested_structs" => hash_record_nested_structs(fields),
            "blockers" => blockers })
      end
      propose_return_hash_record_struct_actions
    end

    def hash_record_local_param_signatures(path, local_name, shape, struct_name)
      existing = Array(@store.facts["existing_sigs"])
      methods_by_name = existing.group_by { |method| method["method"].to_s }
      Array(@store.facts["param_origins"]).filter_map do |origin|
        next unless origin["path"].to_s == path.to_s
        next unless origin["origin_kind"] == "local"
        next unless hash_record_shape_matches_shape?(origin["hash_shape"], shape)
        matches = hash_record_signature_candidate_methods(origin, methods_by_name)
        next unless matches.size == 1
        method = matches.first
        param = hash_record_origin_param(origin, method)
        next unless param
        from = NilKill.extract_param_entries(method["sig"].to_s).to_h[param["name"].to_s] || param["type"].to_s
        to = hash_record_signature_target(from, struct_name)
        next unless to
        { "path" => method["path"], "line" => method["line"], "kind" => "param",
          "name" => param["name"], "from" => from, "type" => to, "method" => method["method"] }
      end.uniq { |sig| [sig["path"], sig["line"], sig["kind"], sig["name"], sig["from"], sig["type"]] }
    end

    def hash_record_param_read_rewrites(path, signatures, shape)
      params = Array(signatures).select { |sig| sig["kind"] == "param" && sig["path"].to_s == path.to_s }
      return [] if params.empty?
      Array(@store.facts["collection_index_lookups"]).filter_map do |lookup|
        origin = lookup["origin"] || {}
        next unless lookup["path"].to_s == path.to_s
        next unless origin["kind"] == "method parameter"
        next unless params.any? { |sig| sig["line"].to_i == origin["line"].to_i && sig["name"].to_s == origin["name"].to_s }
        next unless hash_record_shape_matches_shape?(origin["shape"], shape)
        hash_record_read_rewrite(lookup)
      end
    end

    def propose_return_hash_record_struct_actions
      methods_by_location = Array(@store.facts["existing_sigs"]).each_with_object({}) do |method, index|
        index[[method["path"], method["line"].to_i]] = method
      end
      returns_by_method = Array(@store.facts["return_origins"]).each_with_object(Hash.new { |h, k| h[k] = [] }) do |origin, index|
        next unless origin["hash_shape"] && !origin.dig("hash_shape", "poisoned")
        index[[origin["path"], origin["class"], origin["method"]]] << origin
      end
      lookups = Array(@store.facts["collection_index_lookups"]).select do |lookup|
        origin = lookup["origin"] || {}
        origin["kind"] == "forwarded return" &&
          lookup["path"] == origin["path"] &&
          literal_hash_read_code?(lookup["code"], lookup["receiver"], lookup["index"]) &&
          NilKill.useful_type?(lookup["lookup_type"])
      end
      lookups.group_by { |lookup| [lookup["path"], lookup["enclosing_scope"], lookup.dig("origin", "callee"), lookup.dig("origin", "name")] }.each do |(path, scope, callee, name), group|
        next if path.to_s.empty? || callee.to_s.empty? || name.to_s.empty?
        returns = returns_by_method[[path, scope.to_s, callee.to_s]]
        next unless returns&.one?
        ret = returns.first
        source = Array(ret["sources"]).find { |src| src["code"].to_s.start_with?("{") && src["code"].to_s.end_with?("}") }
        next unless source
        fields = hash_record_struct_fields_from_shape(ret["hash_shape"])
        next if fields.size < 2
        struct_name = hash_record_struct_name(name)
        read_rewrites = group.filter_map { |lookup| hash_record_read_rewrite(lookup) }.uniq { |rw| [rw["line"], rw["code"]] }
        next if read_rewrites.empty?
        signatures = []
        if (method = methods_by_location[[ret["path"], ret["line"].to_i]])
          from = NilKill.extract_return_type(method["sig"].to_s)
          to = hash_record_signature_target(from, struct_name)
          if to
            signatures << { "path" => method["path"], "line" => method["line"], "kind" => "return",
              "from" => from, "type" => to, "method" => method["method"] }
          end
        end
        blockers = hash_record_field_blockers(fields)
        @store.actions << base_action("promote_hash_record_to_struct", REVIEW, path, source["line"],
          "promote hash record returned by #{callee} to #{struct_name}; rewrite #{read_rewrites.size} forwarded field read(s)",
          { "name" => name, "struct_name" => struct_name, "scope" => scope.to_s.split("::").reject(&:empty?),
            "literal" => { "line" => source["line"], "code" => source["code"] },
            "fields" => fields, "read_rewrites" => read_rewrites, "signatures" => signatures,
            "nested_structs" => hash_record_nested_structs(fields),
            "blockers" => blockers,
            "producer" => { "method" => callee, "line" => ret["line"] } })
      end
    end

    def literal_hash_read_code?(code, receiver, index)
      recv = Regexp.escape(receiver.to_s)
      idx = Regexp.escape(index.to_s)
      code.to_s.match?(/\A#{recv}\s*\[\s*#{idx}\s*\]\z/) ||
        code.to_s.match?(/\A#{recv}\.fetch\(\s*#{idx}\s*\)\z/)
    end

    def hash_record_struct_fields(shape)
      nested = hash_record_nested_field_shapes(shape)
      Array(shape["keys"]).zip(Array(shape["value_types"])).filter_map do |key, type|
        name = key.to_s
        next unless name.match?(/\A[a-z_]\w*\z/)
        if (nested_field = hash_record_nested_field(name, nested[name]))
          next nested_field
        end
        next unless NilKill.useful_type?(type)
        { "name" => name, "type" => type.to_s }
      end
    end

    def hash_record_struct_fields_from_shape(shape)
      nested = hash_record_nested_field_shapes(shape)
      Hash(shape["keys"]).sort.filter_map do |key, types|
        name = key.to_s
        next unless name.match?(/\A[a-z_]\w*\z/)
        if (nested_field = hash_record_nested_field(name, nested[name]))
          next nested_field
        end
        type = NilKill.static_sorbet_type(types)
        { "name" => name, "type" => type.to_s }
      end
    end

    def hash_record_nested_field_shapes(shape)
      direct = Hash(shape["value_hash_shapes"])
      arrays = Hash(shape["value_array_element_shapes"])
      (direct.keys | arrays.keys).each_with_object({}) do |key, index|
        index[key.to_s] =
          if arrays[key]
            { "kind" => "array", "shape" => arrays[key] }
          elsif direct[key]
            { "kind" => "hash", "shape" => direct[key] }
          end
      end
    end

    def hash_record_nested_field(name, nested)
      return nil unless nested && nested["shape"] && !nested["shape"]["poisoned"]
      fields = hash_record_struct_fields_from_shape(nested["shape"])
      return nil if fields.empty?
      struct_name = hash_record_struct_name(name)
      type = nested["kind"] == "array" ? "T::Array[#{struct_name}]" : struct_name
      { "name" => name, "type" => type, "nested" => nested.merge("struct_name" => struct_name, "type_name" => struct_name, "fields" => fields) }
    end

    def hash_record_nested_structs(fields)
      Array(fields).flat_map do |field|
        nested = field["nested"]
        next [] unless nested
        hash_record_nested_structs(nested["fields"]) + [nested]
      end.uniq { |nested| nested["type_name"] || nested["struct_name"] }
    end

    def hash_record_field_blockers(fields)
      Array(fields).filter_map do |field|
        type = field["type"].to_s
        if type.empty? || !NilKill.useful_type?(type)
          "field #{field["name"]} needs type evidence; currently unknown"
        elsif type == "NilClass" || type == "T.nilable(NilClass)"
          "field #{field["name"]} needs non-nil value evidence; currently #{type}"
        elsif NilKill.weak_type?(type)
          "field #{field["name"]} needs stronger element/value evidence; currently #{type}"
        end
      end
    end

    def hash_record_param_signature_blockers(signatures)
      params = Array(signatures).select { |sig| sig["kind"] == "param" }
      return [] if params.empty?
      Array(@store.facts["hash_record_blockers"]).filter_map do |blocker|
        origin = blocker["origin"] || {}
        next unless origin["kind"] == "method parameter"
        next unless params.any? do |sig|
          sig["path"].to_s == blocker["path"].to_s &&
            sig["line"].to_i == origin["line"].to_i &&
            sig["name"].to_s == origin["name"].to_s
        end
        site = [blocker["path"], blocker["line"]].compact.join(":")
        [blocker["message"].to_s, site].reject(&:empty?).join(" at ")
      end.uniq
    end

    def hash_record_struct_name(name)
      base = name.to_s.gsub(/[^A-Za-z0-9_]/, "_").split("_").reject(&:empty?).map(&:capitalize).join
      base = "Record" if base.empty?
      "#{base}Record"
    end

    def hash_record_read_rewrite(lookup)
      key = hash_record_lookup_key(lookup)
      return nil unless key && key.match?(/\A[a-z_]\w*\z/)
      { "line" => lookup["line"], "code" => lookup["code"], "replacement" => "#{lookup["receiver"]}.#{key}" }
    end

    def hash_record_lookup_key(lookup)
      case lookup["index"].to_s
      when /\A:([A-Za-z_]\w*[!?=]?)\z/
        Regexp.last_match(1)
      when /\A["']([^"']+)["']\z/
        Regexp.last_match(1)
      end
    end

    def build_flow_graph
      @store.facts["flow_graph"] = FlowGraph.from_evidence(@store.to_h).to_h
    end

    def propose_hash_record_cluster_actions
      evidence = @store.to_h
      report = Report.allocate
      report.instance_variable_set(:@evidence, evidence)
      report.hash_record_struct_candidates(evidence).first(30).each do |row|
        row = hash_record_expand_row_from_return_origins(row, evidence)
        next unless row["total_pressure"].to_i.positive?
        producers = Array(row["producers"])
        consumers = Array(row["consumers"])
        blockers = hash_record_cluster_blockers(row)
        signatures = hash_record_cluster_signatures(row, evidence)
        next if producers.empty? && consumers.empty?
        struct_path = row["struct_path"].to_s
        first = if !struct_path.empty?
          { "path" => struct_path, "line" => 1 }
        else
          (producers + consumers).min_by { |site| [site["path"].to_s, site["line"].to_i] }
        end
        @store.actions << base_action("promote_hash_record_cluster_to_struct", REVIEW, first["path"], first["line"],
          "plan #{row["type_name"] || row["struct_name"]} from #{row["shape_count"]} hash literal shape(s), #{row["total_pressure"]} pressure slot(s)",
          { "struct_name" => row["struct_name"], "type_name" => row["type_name"], "scope" => row["scope"], "struct_path" => row["struct_path"], "fields" => row["fields"],
            "nested_structs" => row["nested_structs"],
            "common_keys" => row["common_keys"], "optional_keys" => row["optional_keys"],
            "producers" => producers, "consumers" => consumers, "signatures" => signatures,
            "blockers" => blockers, "pressure" => {
              "total" => row["total_pressure"], "return" => row["return_slots"],
              "param" => row["param_slots"], "ivar" => row["ivar_slots"],
              "collection" => row["collection_slots"],
            } })
      end
    end

    def hash_record_expand_row_from_return_origins(row, evidence)
      row = row.transform_values { |value| value.is_a?(Array) ? value.map { |entry| entry.is_a?(Hash) ? entry.dup : entry } : value }
      producers = Array(row["producers"]).map(&:dup)
      producer_sites = producers.map { |producer| [producer["path"], producer["line"].to_i, producer["code"].to_s] }.to_set
      shape_by_site = Array(evidence.dig("facts", "hash_shapes")).each_with_object({}) do |shape, index|
        index[[shape["path"], shape["line"].to_i, shape["code"].to_s]] = shape
      end
      common = Array(row["common_keys"]).map(&:to_s).sort
      union = (common + Array(row["optional_keys"]).map(&:to_s)).uniq.sort
      field_types = Array(row["fields"]).each_with_object(Hash.new { |h, k| h[k] = [] }) do |field, index|
        type = field["type"].to_s
        base = type.start_with?("T.nilable(") ? type[10..-2] : type
        index[field["name"].to_s] |= [base] unless base.empty?
      end

      Array(evidence.dig("facts", "return_origins")).each do |origin|
        sources = Array(origin["sources"])
        next unless sources.any? { |source| producer_sites.include?([origin["path"], source["line"].to_i, source["code"].to_s]) } ||
          hash_record_origin_shape_matches_row?(origin, row)
        sources.each do |source|
          next unless source["code"].to_s.start_with?("{") && source["code"].to_s.end_with?("}")
          shape = shape_by_site[[origin["path"], source["line"].to_i, source["code"].to_s]]
          next unless shape
          keys = Array(shape["keys"]).map(&:to_s).sort
          next if keys.empty? || (common - keys).any?
          next unless similar_hash_keysets_for_action?(union, keys)
          site = [origin["path"], source["line"].to_i, source["code"].to_s]
          unless producer_sites.include?(site)
            producers << { "path" => origin["path"], "line" => source["line"], "code" => source["code"], "keys" => keys }
            producer_sites.add(site)
          end
          union = (union | keys).sort
          Array(shape["keys"]).zip(Array(shape["value_types"])).each do |key, type|
            field_types[key.to_s] |= [type.to_s] if NilKill.useful_type?(type)
          end
        end
      end

      optional = union - common
      fields = union.map do |field|
        existing = Array(row["fields"]).find { |entry| entry["name"].to_s == field }
        type = NilKill.static_sorbet_type(field_types[field])
        type = existing["type"].to_s if existing && (type.empty? || type == "T.untyped")
        type = "T.untyped" unless NilKill.useful_type?(type)
        type = "T.nilable(#{type})" if optional.include?(field) && type != "T.untyped" && type != "NilClass" && !type.start_with?("T.nilable(")
        data = { "name" => field, "type" => type, "optional" => optional.include?(field) }
        data["required_members"] = existing["required_members"] if existing&.key?("required_members")
        data
      end
      row.merge("producers" => producers, "common_keys" => common, "optional_keys" => optional, "fields" => fields)
    end

    def similar_hash_keysets_for_action?(left, right)
      left = Array(left).to_set
      right = Array(right).to_set
      return false if left.empty? || right.empty?
      intersection = (left & right).size
      smaller = [left.size, right.size].min
      union = (left | right).size
      intersection == smaller || (intersection.to_f / union) >= 0.5
    end

    def hash_record_cluster_signatures(row, evidence)
      type_name = (row["type_name"] || row["struct_name"]).to_s
      return [] if type_name.empty?
      existing = Array(evidence.dig("facts", "existing_sigs"))
      methods_by_location = existing.each_with_object({}) { |method, index| index[[method["path"], method["line"].to_i]] = method }
      signatures = []

      producer_sites = Array(row["producers"]).map { |producer| [producer["path"], producer["line"].to_i, producer["code"].to_s] }.to_set
      Array(evidence.dig("facts", "return_origins")).each do |origin|
        next unless Array(origin["sources"]).any? { |source| producer_sites.include?([origin["path"], source["line"].to_i, source["code"].to_s]) } ||
          hash_record_origin_shape_matches_row?(origin, row)
        method = methods_by_location[[origin["path"], origin["line"].to_i]]
        next unless method
        from = NilKill.extract_return_type(method["sig"].to_s)
        to = hash_record_signature_target(from, type_name)
        next unless to
        signatures << { "path" => method["path"], "line" => method["line"], "kind" => "return",
          "from" => from, "type" => to, "method" => method["method"] }
      end

      Array(row["consumers"]).each do |consumer|
        origin = consumer["origin"] || {}
        next unless origin["kind"] == "method parameter"
        method = methods_by_location[[origin["path"], origin["line"].to_i]]
        next unless method
        name = origin["name"].to_s
        from = NilKill.extract_param_entries(method["sig"].to_s).to_h[name] || origin["type"].to_s
        to = hash_record_signature_target(from, type_name)
        next unless to
        signatures << { "path" => method["path"], "line" => method["line"], "kind" => "param",
          "name" => name, "from" => from, "type" => to, "method" => method["method"] }
      end

      methods_by_name = existing.group_by { |method| method["method"].to_s }
      Array(evidence.dig("facts", "param_origins")).each do |origin|
        next unless producer_sites.include?([origin["path"], origin["line"].to_i, origin["code"].to_s]) ||
          hash_record_origin_shape_matches_row?(origin, row)
        matches = hash_record_signature_candidate_methods(origin, methods_by_name)
        next unless matches.size == 1
        method = matches.first
        param =
          if origin["arg_kind"] == "positional"
            Array(method["params"])[origin["slot"].to_i]
          elsif origin["arg_kind"] == "keyword"
            Array(method["params"]).find { |entry| entry["name"].to_s == origin["slot"].to_s }
          end
        next unless param
        from = NilKill.extract_param_entries(method["sig"].to_s).to_h[param["name"].to_s] || param["type"].to_s
        to = hash_record_signature_target(from, type_name)
        next unless to
        signatures << { "path" => method["path"], "line" => method["line"], "kind" => "param",
          "name" => param["name"], "from" => from, "type" => to, "method" => method["method"] }
      end

      signatures.uniq { |sig| [sig["path"], sig["line"], sig["kind"], sig["name"], sig["from"], sig["type"]] }
    end

    def hash_record_origin_shape_matches_row?(origin, row)
      row_keys = (Array(row["common_keys"]) + Array(row["optional_keys"])).map(&:to_s).sort
      return false if row_keys.empty?
      [origin["hash_shape"], origin["array_element_shape"]].compact.any? do |shape|
        keys = Hash(shape["keys"]).keys.map(&:to_s).sort
        keys.any? && (keys - row_keys).empty? && (Array(row["common_keys"]).map(&:to_s) - keys).empty?
      end
    end

    def hash_record_shape_matches_shape?(left, right)
      left_keys = hash_record_shape_keys(left)
      right_keys = hash_record_shape_keys(right)
      return false if left_keys.empty? || right_keys.empty?
      left_keys == right_keys
    end

    def hash_record_shape_keys(shape)
      keys = shape&.fetch("keys", nil)
      keys.is_a?(Hash) ? keys.keys.map(&:to_s).sort : Array(keys).map(&:to_s).sort
    end

    def hash_record_origin_param(origin, method)
      if origin["arg_kind"] == "positional"
        Array(method["params"])[origin["slot"].to_i]
      elsif origin["arg_kind"] == "keyword"
        Array(method["params"]).find { |entry| entry["name"].to_s == origin["slot"].to_s }
      end
    end

    def hash_record_signature_candidate_methods(origin, methods_by_name)
      callee = origin["callee"].to_s
      if callee == "new" && origin["receiver"].to_s != ""
        receiver = origin["receiver"].to_s
        return Array(methods_by_name["initialize"]).select do |method|
          klass = method["class"].to_s
          klass == receiver || klass.end_with?("::#{receiver}") || klass.split("::").last == receiver.split("::").last
        end
      end
      Array(methods_by_name[callee])
    end

    def hash_record_signature_target(type, struct_name)
      raw = type.to_s.strip
      return nil if raw.empty?
      if raw.match?(/\AT\.nilable\(\s*T::Hash\[/)
        "T.nilable(#{struct_name})"
      elsif raw.match?(/\AT::Hash\[/) || raw == "Hash"
        struct_name
      elsif raw.match?(/\AT\.nilable\(\s*T::Array\[T::Hash\[/)
        "T.nilable(T::Array[#{struct_name}])"
      elsif raw.match?(/\AT::Array\[T::Hash\[/)
        "T::Array[#{struct_name}]"
      end
    end

    def hash_record_cluster_blockers(row)
      blockers = hash_record_field_blockers(Array(row["fields"]))
      # A hash that flows into a collection is the NORMAL case: the
      # collection has a hidden element type == the hash shape. The
      # correct end state is to promote the hash to a Struct AND type
      # the collection `T::Array[Struct]`, then convert iteration
      # readers (`coll.each { |f| f[:k] }` -> `f.k`). The genuine
      # exception is a heterogeneous dumping-ground (AST/MIR node lists)
      # where many divergent shapes / T.any value-types share a
      # collection and no single struct describes them.
      #
      # Classify which case this cluster is, from data already computed:
      #   - common/optional key ratio (divergent shapes merge as many
      #     optional keys)
      #   - fraction of fields whose value type is T.any / T.untyped
      #     (same key, many value-type families == heterogeneous)
      #
      # Two distinct outcomes (NOT lumped together):
      #   * heterogeneous  -> hard block, "not a struct candidate"
      #   * coherent + escaping -> the record IS a real struct and the
      #     collection has a hidden shape, but auto-applying requires
      #     the element-typed-collection rewrite (type the container +
      #     convert every iteration reader). That rewrite is the
      #     twice-reverted hard part and is NOT implemented, so block
      #     with a DISTINCT message that flags it as a real
      #     opportunity, not a dead end.
      escaping = hash_record_producers_escaping_into_collection(Array(row["producers"]))
      unless escaping.empty?
        if hash_record_collection_shape_coherent?(row)
          first = escaping.first
          blockers << "coherent record escapes into a collection at #{first["path"]}:#{first["line"]}; " \
            "this collection has a hidden element type (#{row["type_name"] || row["struct_name"]}) -- " \
            "promoting requires the element-typed-collection rewrite (type the container + convert " \
            "iteration readers), which is not yet implemented"
        else
          common = Array(row["common_keys"]).size
          optional = Array(row["optional_keys"]).size
          anyf = Array(row["fields"]).count { |f| f["type"].to_s.match?(/T\.any|T\.untyped/) }
          blockers << "heterogeneous collection: #{common} common / #{optional} optional key(s), " \
            "#{anyf}/#{Array(row["fields"]).size} fields are T.any/T.untyped -- no single struct " \
            "describes these shapes; not a struct candidate"
        end
      end
      existing_paths = hash_record_existing_struct_paths(row["struct_name"].to_s)
      unless existing_paths.empty?
        blockers << "struct name #{row["struct_name"]} already exists at #{existing_paths.first}"
      end
      Array(row["blockers"]).each do |blocker|
        message = blocker["message"].to_s
        site = [blocker["path"], blocker["line"]].compact.join(":")
        blockers << [message, site].reject(&:empty?).join(" at ")
      end
      blockers
    end

    # A cluster describes ONE coherent struct (the collection it flows
    # into has a real hidden element type) when:
    #   - there are at least 2 common keys present in every shape
    #     (a single stable skeleton, not a grab-bag), and
    #   - optional keys don't dominate -- many optional keys means many
    #     divergent shapes were merged (the heterogeneous case), and
    #   - value types are mostly concrete -- a high fraction of
    #     T.any/T.untyped fields means the same key carries unrelated
    #     value-type families across sites (also heterogeneous).
    # Thresholds are intentionally permissive: the user's stated model
    # is that homogeneous-shape-into-collection is the NORM and the
    # heterogeneous node-list is the exception, so only clearly
    # divergent clusters fall through to "not a struct candidate".
    def hash_record_collection_shape_coherent?(row)
      common = Array(row["common_keys"]).size
      optional = Array(row["optional_keys"]).size
      fields = Array(row["fields"])
      return false if common < 2
      total_keys = common + optional
      return false if total_keys.zero?
      optional_ratio = optional.to_f / total_keys
      any_ratio = fields.empty? ? 1.0 :
        fields.count { |f| f["type"].to_s.match?(/T\.any|T\.untyped/) }.to_f / fields.size
      optional_ratio <= 0.5 && any_ratio <= 0.5
    end

    COLLECTION_APPEND_METHODS = %w[<< push unshift append prepend concat].freeze

    # Returns the producer entries whose record value escapes into an
    # untyped container -- so downstream readers iterate it via block
    # params / generic walkers the proposer cannot enumerate. Three
    # escape vectors, all statically decidable:
    #   1. the hash literal is an element of an ArrayNode literal
    #      (`Foo.new(x, [ { ... } ])`)
    #   2. the hash literal (or a local bound to it) is the argument of a
    #      collection-append call (`fields << { ... }`, `arr.push(x)`)
    #   3. the hash literal (or its bound local) is the value of an
    #      index-write that stores it into a container
    #      (`@functions[key] = f` where `f = { ... }`)
    # One-hop local aliasing is followed (`f = { ... }` then `f` used);
    # deeper alias chains are conservatively treated as escaping when
    # the local is passed as a bare call argument anywhere.
    def hash_record_producers_escaping_into_collection(producers)
      by_path = Array(producers).group_by { |p| p["path"].to_s }
      by_path.flat_map do |rel_path, entries|
        next [] if rel_path.empty?
        abs = File.expand_path(rel_path, ROOT)
        next [] unless File.file?(abs)
        parsed = Prism.parse(File.read(abs))
        next [] unless parsed.success?
        entries.select do |producer|
          line = producer["line"].to_i
          code = producer["code"].to_s.strip
          hash_node = find_hash_literal_node(parsed.value, line, code)
          next false unless hash_node
          hash_record_value_escapes?(parsed.value, hash_node)
        end
      end
    end

    def hash_record_value_escapes?(root, hash_node)
      return true if hash_literal_in_array_literal?(root, hash_node)
      return true if value_in_collection_append_or_index_write?(root, hash_node)
      # One-hop alias: `local = { ... }` then escape uses of `local`.
      writer = enclosing_local_write_for(root, hash_node)
      return false unless writer
      name = writer.name.to_s
      escape_uses_of_local?(root, name, hash_node)
    end

    # The hash node is the direct value argument of `coll << x` /
    # `coll.push(x)` / ... or the RHS value of an index write
    # `recv[k] = x`.
    def value_in_collection_append_or_index_write?(root, target)
      each_node(root) do |node|
        if node.is_a?(Prism::CallNode) && COLLECTION_APPEND_METHODS.include?(node.name.to_s)
          args = node.arguments&.arguments || []
          return true if args.any? { |a| a.equal?(target) }
        end
        if node.is_a?(Prism::IndexOperatorWriteNode) || node.is_a?(Prism::IndexAndWriteNode) ||
            node.is_a?(Prism::IndexOrWriteNode)
          return true if node.respond_to?(:value) && node.value.equal?(target)
        end
        if node.is_a?(Prism::CallNode) && node.name.to_s == "[]=" && node.arguments
          last = node.arguments.arguments.last
          return true if last && last.equal?(target)
        end
      end
      false
    end

    def enclosing_local_write_for(root, target)
      found = nil
      each_node(root) do |node|
        if node.is_a?(Prism::LocalVariableWriteNode) && node.value.equal?(target)
          found = node
        end
      end
      found
    end

    # Conservatively: a local that holds the record escapes if it is
    # ever read as an element of an array literal, an append-call arg,
    # an index-write value, or any bare call argument (could be retained
    # by the callee).
    def escape_uses_of_local?(root, name, origin_hash)
      each_node(root) do |node|
        next unless node.is_a?(Prism::CallNode)
        args = node.arguments&.arguments || []
        reads = args.select { |a| a.is_a?(Prism::LocalVariableReadNode) && a.name.to_s == name }
        next if reads.empty?
        # `local[:k]` / `local.fetch(:k)` style reads have the local as
        # the RECEIVER, not an argument -- those are safe accessors and
        # never land here. Any local-as-argument is a potential escape.
        return true
      end
      # element of an array literal: `arr = [local]` / `[ local ]`
      each_node(root) do |node|
        next unless node.is_a?(Prism::ArrayNode)
        return true if node.elements.any? { |e| e.is_a?(Prism::LocalVariableReadNode) && e.name.to_s == name }
      end
      false
    end

    def each_node(root)
      stack = [root]
      until stack.empty?
        node = stack.pop
        next unless node
        yield node
        stack.concat(node.child_nodes.compact) if node.respond_to?(:child_nodes)
      end
    end

    def find_hash_literal_node(root, line, code)
      stack = [root]
      until stack.empty?
        node = stack.pop
        next unless node
        if node.is_a?(Prism::HashNode) &&
            node.location.start_line == line &&
            node.slice.strip == code
          return node
        end
        stack.concat(node.child_nodes.compact) if node.respond_to?(:child_nodes)
      end
      nil
    end

    # True if `target` (a HashNode) sits in an array-element position:
    # its nearest enclosing container before the statement is an
    # ArrayNode. Parent links aren't available in Prism, so search from
    # the root for an ArrayNode that (transitively) contains the target.
    def hash_literal_in_array_literal?(root, target)
      stack = [root]
      until stack.empty?
        node = stack.pop
        next unless node
        if node.is_a?(Prism::ArrayNode) && node_contains?(node, target)
          return true
        end
        stack.concat(node.child_nodes.compact) if node.respond_to?(:child_nodes)
      end
      false
    end

    def node_contains?(node, target)
      return false unless node
      return true if node.equal?(target)
      return false unless node.respond_to?(:child_nodes)
      node.child_nodes.compact.any? { |child| node_contains?(child, target) }
    end

    def hash_record_existing_struct_paths(struct_name)
      return [] if struct_name.empty?
      @hash_record_existing_struct_paths ||= {}
      @hash_record_existing_struct_paths[struct_name] ||= begin
        pattern = /\bclass\s+#{Regexp.escape(struct_name)}\b/
        candidates = Dir.glob("src/**/*.rb") + Dir.glob("gems/*/lib/**/*.rb")
        candidates.filter_map do |path|
          next unless File.file?(path)
          path if File.read(path).match?(pattern)
        rescue StandardError
          nil
        end
      end
    end

    def propose_sig(rec, src)
      sig = sig_for(rec, src)
      conf = sig.include?("T.untyped") || rec["calls"].to_i.zero? ? REVIEW : NilKill.confidence(rec["calls"])
      if src["uses_yield"] && conf == HIGH
        conf = REVIEW
      end
      message = src["uses_yield"] ? "add missing sig; method uses implicit yield, block typing needs review" : "add missing sig"
      @store.actions << base_action("add_sig", conf, src["path"], src["line"], message, { "sig" => sig, "scope" => src["scope"], "method" => src["method"] })
    end

    def validate_sig(rec, src, unused_return_methods = {})
      sig = src["sig"].to_s
      params_for_typing(rec).each do |name, classes|
        observed = NilKill.sorbet_type(classes)
        next unless NilKill.useful_type?(observed)
        next unless sig.match?(/\b#{Regexp.escape(name)}:\s*T\.untyped\b/)
        @store.actions << base_action("fix_sig_param", REVIEW, src["path"], src["line"],
          "existing sig param #{name} is T.untyped; observed #{observed}", { "name" => name, "type" => observed })
      end
      observed_return = runtime_return_type_candidate(rec)
      if NilKill.useful_type?(observed_return) && sig.include?("returns(T.untyped)")
        @store.actions << base_action("fix_sig_return", REVIEW, src["path"], src["line"],
          "existing sig return is T.untyped; observed #{observed_return}", { "type" => observed_return })
      end
      propose_void_return_action(src, sig, unused_return_methods, rec)
      propose_noreturn_action(src, sig, rec)
      propose_static_return_action(src, sig, rec)
      propose_generic_narrowing_actions(rec, src, sig)
    end

    def propose_void_return_action(src, sig, unused_return_methods, rec = nil)
      return unless sig.include?("returns(T.untyped)")
      return if src["noreturn_candidate"]
      return if runtime_contradicts?(rec, :return, nil, "void")
      if unused_return_methods[method_location_key(src)]
        @store.actions << base_action("fix_sig_return", HIGH, src["path"], src["line"],
          "existing sig return is T.untyped; return value is never used, prefer .void",
          { "type" => "void", "source" => "unused_return" })
      elsif rec && rec["calls"].to_i.positive? &&
            Array(rec["returns"]).reject { |c| c == "NilClass" }.empty?
        # Runtime-void: the method ran but never produced a usable
        # return value (only nil / nothing), and the STATIC usage scan
        # couldn't prove it unused (name collision / ambiguous dispatch
        # / return read on an unexercised path). Weaker than the static
        # proof -> REVIEW, gated by the verified loop.
        @store.actions << base_action("fix_sig_return", REVIEW, src["path"], src["line"],
          "existing sig return is T.untyped; ran #{rec["calls"]}x, return value never a usable type at runtime -- likely .void",
          { "type" => "void", "source" => "runtime_void" })
      end
    end

    def propose_noreturn_action(src, sig, rec = nil)
      return unless sig.include?("returns(T.untyped)")
      return unless src["noreturn_candidate"]
      return if runtime_contradicts?(rec, :return, nil, "T.noreturn")
      @store.actions << base_action("fix_sig_return", HIGH, src["path"], src["line"],
        "existing sig return is T.untyped; method body cannot return normally",
        { "type" => "T.noreturn", "source" => "noreturn_body" })
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
      method_return_types = unambiguous_method_return_types(evidence)

      used = Set.new
      return_edges = Hash.new { |hash, key| hash[key] = Set.new }
      # Scan a broader file set than just target_files: a method only used by
      # specs / transpile-tests / tools is still "used", and narrowing it to
      # `void` would replace its return value with a Void marker and break
      # those callers at runtime. `usage_scan_files` respects NIL_KILL_TARGETS
      # for test isolation.
      NilKill.usage_scan_files.each do |path|
        parsed = Prism.parse_file(path)
        next unless parsed.success?
        mark_return_usage_graph(parsed.value, :statement, nil, candidate_names, method_return_types, used, return_edges)
      end
      propagate_return_usage!(used, return_edges)
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
      when Prism::DefNode
        mark_return_usage_graph(node.body, :return, node.name, candidate_names, method_return_types, used, return_edges)
      when Prism::StatementsNode
        body = node.body || []
        body.each_with_index do |child, idx|
          child_context = idx == body.length - 1 ? context : :statement
          mark_return_usage_graph(child, child_context, current_method, candidate_names, method_return_types, used, return_edges)
        end
      when Prism::ReturnNode
        node.child_nodes.compact.each { |child| mark_return_usage_graph(child, :return, current_method, candidate_names, method_return_types, used, return_edges) }
      when Prism::ArgumentsNode
        node.child_nodes.compact.each { |child| mark_return_usage_graph(child, context, current_method, candidate_names, method_return_types, used, return_edges) }
      when Prism::IfNode
        mark_return_usage_graph(node.predicate, :value, current_method, candidate_names, method_return_types, used, return_edges) if node.respond_to?(:predicate)
        mark_return_usage_graph(node.statements, context, current_method, candidate_names, method_return_types, used, return_edges)
        mark_return_usage_graph(node.subsequent, context, current_method, candidate_names, method_return_types, used, return_edges)
      when Prism::ElseNode
        mark_return_usage_graph(node.statements, context, current_method, candidate_names, method_return_types, used, return_edges)
      when Prism::CallNode
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

    def propose_static_return_action(src, sig, rec)
      return unless sig.include?("returns(T.untyped)")
      origin = src["return_origin"] || return_origin_for(src)
      return unless origin
      type = origin["candidate_type"]
      return unless NilKill.useful_type?(type)
      return if runtime_contradicts?(rec, :return, nil, type)
      confidence = high_confidence_static_return_origin?(origin, rec) ? HIGH : REVIEW
      @store.actions << base_action("fix_sig_return", confidence, src["path"], src["line"],
        "existing sig return is T.untyped; static return origins suggest #{type}",
        { "type" => type, "source" => "static_return_origin", "origin_confidence" => origin["confidence"],
          "blockers" => Array(origin["blockers"]).first(8) })
    end

    # HIGH must mean "statically guaranteed to typecheck" -- a high
    # action that fails `srb tc` is a calibration bug. Three gates:
    #   1. origin confidence must be strong;
    #   2. NO blockers -- a blocker is the static analysis itself
    #      reporting it could not cleanly determine the return, so the
    #      candidate is a guess, never HIGH;
    #   3. every useful source is static/RBI AND, for a BARE static
    #      source (a heuristic guess, not RBI/stdlib-backed), the method
    #      must be runtime-corroborated. runtime_contradicts? has
    #      already rejected incompatible observed returns, so any
    #      observed return here agrees; if there is NO runtime return at
    #      all, a bare-static guess is unverifiable -> REVIEW (the loop
    #      filters it; a review rejection is by-design, not miscalib).
    # RBI/stdlib-backed sources are statically provable and stay HIGH
    # without runtime backing.
    def high_confidence_static_return_origin?(origin, rec = nil)
      return false unless origin["confidence"] == "strong"
      return false if Array(origin["blockers"]).any?
      sources = Array(origin["sources"])
      useful = sources.reject { |source| source["kind"].to_s == "nil" }
      return false if useful.empty?
      return false unless useful.all? { |source| static_or_rbi_return_source?(source) }
      return true unless useful.any? { |source| bare_static_return_source?(source) }
      Array(rec && rec["returns"]).any?
    end

    # A bare static source: kind "static", not RBI/stdlib-backed, and
    # whose return expression is NOT self-evidently typed. A literal /
    # constructor (`"x"`, `[...]`, `{...}`, `:sym`, `123`, `Foo.new`,
    # true/false/nil) is statically provable -> not bare -> stays HIGH.
    # A heuristic guess like `@samples << {...}` (operator call whose
    # type is not self-evident) is bare -> needs corroboration.
    def bare_static_return_source?(source)
      return false unless source["kind"].to_s == "static"
      return false if source["stdlib"]
      return false if source["callee"] && NilKill.rbi_return_type(source["callee"].to_s)
      !self_evident_return_code?(source["code"].to_s)
    end

    SELF_EVIDENT_RETURN_RE = /\A(?:"|'|:|\[|\{|%[wi]\[|-?\d|true\b|false\b|nil\b|[A-Z][\w:]*\.new\b)/.freeze

    def self_evident_return_code?(code)
      code = code.to_s.strip
      return false if code.empty?
      SELF_EVIDENT_RETURN_RE.match?(code)
    end

    def static_or_rbi_return_source?(source)
      return true if source["kind"].to_s == "static"
      return false unless %w[typed_call safe_call].include?(source["kind"].to_s)
      return true if source["stdlib"]
      callee = source["callee"].to_s
      !callee.empty? && NilKill.rbi_return_type(callee)
    end

    def return_origin_for(src)
      @return_origin_by_location ||= @store.facts["return_origins"].each_with_object({}) do |origin, lookup|
        lookup[[origin["path"], origin["line"]]] = origin
      end
      @return_origin_by_location[[src["path"], src["line"]]]
    end

    # Feature A: receiver-type inference. After SourceIndex collects all
    # `param_origins` and `return_origins`, walk each `call_untyped` return
    # source of the form `recv.method` where `recv` is a param of the
    # enclosing method. Look up classes callers pass for that param slot
    # via `param_origins`; for each, look up `.method`'s return type in
    # `RbiReturnIndex`. If consistent (single class with a strong sig),
    # replace the source's `call_untyped` kind with `typed_call_inferred`
    # and recompute the origin's candidate_type/confidence so downstream
    # proposers (propose_static_return_action, propose_forwarded_return_chain)
    # pick up the new info.
    #
    # Guards:
    # - Only matches simple `recv.method` calls (regex-bounded).
    # - Only emits when ALL caller classes agree on the return type.
    # - Drops T.nilable and weak-collection narrowings (same cascade rules
    #   as elsewhere).
    # - Cross-check against runtime via `runtime_contradicts?` -- if runtime
    #   observed returns that the inferred type doesn't accept, skip.
    # Fixed-point iteration: each pass turns some `call_untyped` sources into
    # `typed_call_inferred`, which feeds into the next iteration's project-
    # method-return index via `build_project_method_return_index` (C2 pulls
    # strong return_origins into the index). A method whose return becomes
    # strong in iteration N can be the receiver-typed narrowing source for
    # another method in iteration N+1.
    #
    # Bounded at 5 iterations as a safety stop. In practice convergence is
    # 1-3 iterations; cycles can't make progress beyond the first hit
    # because the second visit is a no-op (kind already changed from
    # call_untyped to typed_call_inferred). When a pass enriches zero
    # sources we stop early.
    MAX_RECEIVER_ENRICHMENT_ITERS = 5

    def enrich_return_origins_with_receiver_inference!
      origins_by_callee = Array(@store.facts["param_origins"]).group_by { |o| o["callee"].to_s }
      methods_by_location = Array(@store.facts["existing_sigs"]).each_with_object({}) do |m, h|
        h[[m["path"], m["line"].to_i]] = m
      end
      rbi = NilKill.rbi_return_index
      MAX_RECEIVER_ENRICHMENT_ITERS.times do
        project_method_returns = build_project_method_return_index
        any_enriched = false
        Array(@store.facts["return_origins"]).each do |origin|
          enriched = false
          Array(origin["sources"]).each_with_index do |source, idx|
            next unless source["kind"].to_s == "call_untyped"
            narrowed = receiver_inferred_call_return(origin, source, origins_by_callee, methods_by_location, project_method_returns, rbi)
            next unless narrowed
            origin["sources"][idx] = source.merge("kind" => "typed_call_inferred", "type" => narrowed)
            enriched = true
            any_enriched = true
          end
          recompute_origin_candidate_and_confidence!(origin) if enriched
        end
        break unless any_enriched
      end
    end

    MAX_CALLEE_PROPAGATION_ITERS = 8

    # Whole-program return-type propagation.
    #
    # A `call_untyped` return source means the enclosing method returns
    # `callee(...)` whose return type wasn't known *in the callee's own
    # file*. But the callee's return IS often resolvable program-wide --
    # from its Sorbet sig, an RBI, or a strong return_origin computed for
    # the callee elsewhere. nil-kill already stores the whole-program
    # call graph (param_origins) and per-method return facts; this pass
    # is the missing transitive closure over them.
    #
    # Fixpoint: a leaf method that resolves in iteration N feeds
    # `build_project_method_return_index` (which folds in strong
    # return_origins), so its callers resolve in iteration N+1. Bounded
    # at MAX_CALLEE_PROPAGATION_ITERS.
    #
    # Resolution order per call_untyped source (conservative, matching
    # the existing forwarded-return ambiguity stance):
    #   1. `[enclosing_class, callee]` exact (self / inherited call)
    #   2. unique program-wide return for the callee NAME (skip if the
    #      name resolves to >1 distinct type across classes -- a
    #      collision we can't disambiguate without receiver typing,
    #      which is Feature A's job)
    #
    # Guards mirror receiver inference: useful, non-weak, non-nilable,
    # and a runtime cross-check. On resolution the stale
    # "untyped callee <callee>" blocker is pruned so the origin can
    # actually reach `strong` in recompute.
    def enrich_return_origins_with_callee_propagation!
      MAX_CALLEE_PROPAGATION_ITERS.times do
        index = build_project_method_return_index
        name_returns = Hash.new { |h, k| h[k] = [] }
        index.each { |(_cls, m), t| name_returns[m] << t }
        name_unique = {}
        name_returns.each do |m, types|
          uniq = types.uniq
          name_unique[m] = uniq.first if uniq.size == 1
        end
        any = false
        Array(@store.facts["return_origins"]).each do |origin|
          enriched = false
          enclosing_class = origin["class"].to_s
          Array(origin["sources"]).each_with_index do |source, idx|
            next unless source["kind"].to_s == "call_untyped"
            callee = source["callee"].to_s
            next if callee.empty?
            # Noreturn helpers (error!, fixable!, raise-wrappers) are the
            # single most common residual blocker. Their noreturn-ness
            # lives in SourceIndex.noreturn_methods (populated by the
            # cross-file noreturn fixpoint), NOT as a strong return type
            # in the index, because their body raises. Resolve them to
            # T.noreturn directly; static_sorbet_type treats it as
            # bottom so a `return x if c; error!(...)` origin unifies to
            # x's type instead of staying blocked.
            resolved =
              if SourceIndex.noreturn_methods.include?(callee)
                "T.noreturn"
              else
                index[[enclosing_class, callee]] || name_unique[callee]
              end
            next unless NilKill.useful_type?(resolved)
            next if NilKill.weak_type?(resolved)
            # NOTE: no T.nilable refusal here. That guard is correct for
            # PARAM narrowing (cascade-prone -- copied from Feature A's
            # receiver path) but wrong for RETURN propagation: a callee
            # whose resolved return is `T.nilable(Foo)` genuinely
            # returns that, and propagating it is the correct, sound
            # answer. Refusing it stranded ~21 otherwise-resolvable
            # return origins as false NoEvidence/blocked.
            # The runtime cross-check compares `resolved` against the
            # ENCLOSING method's observed return. That is correct for a
            # concrete-type substitution, but incoherent for T.noreturn:
            # the callee (`error!`) genuinely never returns at THAT call
            # site; it makes no claim about the enclosing method, which
            # legitimately returns via other paths. static_sorbet_type
            # drops T.noreturn as bottom in recompute anyway. Applying
            # the guard here wrongly skips every noreturn-helper caller.
            unless resolved == "T.noreturn"
              rec = method_record_for_origin(origin)
              next if rec && runtime_contradicts?(rec, :return, nil, resolved)
            end
            origin["sources"][idx] = source.merge("kind" => "typed_call_inferred", "type" => resolved)
            prune_resolved_callee_blocker!(origin, callee)
            enriched = true
            any = true
          end
          recompute_origin_candidate_and_confidence!(origin) if enriched
        end
        break unless any
      end
    end

    # Remove the static "untyped callee <callee>" blocker once that
    # callee's return has been resolved by propagation. Without this the
    # origin keeps a stale blocker and recompute can never reach strong.
    def prune_resolved_callee_blocker!(origin, callee)
      blockers = Array(origin["blockers"])
      return if blockers.empty?
      escaped = Regexp.escape(callee)
      # The blocker string is "untyped callee <callee> at <path>:<line>".
      # A trailing \b is WRONG for predicate/bang callees (`error!`,
      # `auto?`): `!`/`?` are non-word chars so there is no word
      # boundary after them and the blocker never gets pruned, leaving
      # the origin stuck non-strong even though the source resolved.
      # Anchor on the literal " at " separator (or end) instead.
      origin["blockers"] = blockers.reject { |b| b.to_s.match?(/(?:\A|\s)untyped callee #{escaped}(?=\s|\z)/) }
    end

    # Project-class method-return index keyed by [class, method]. Reads from
    # `existing_sigs` (which captures every Sorbet-typed method definition in
    # src/) and extracts the return type per (class, method) pair. The
    # RbiReturnIndex's owner-keyed lookup only succeeds when the class has
    # an RBI file entry; this index closes the gap for the bulk of project
    # methods that have inline `sig {}` declarations.
    def build_project_method_return_index
      index = {}
      Array(@store.facts["existing_sigs"]).each do |method|
        klass = method["class"].to_s
        name = method["method"].to_s
        next if klass.empty? || name.empty?
        ret = NilKill.extract_return_type(method["sig"].to_s).to_s
        next if ret.empty? || ret == "T.untyped"
        # Multiple definitions of the same name across classes are fine
        # because the key is [class, method] -- but if a single class has
        # two `def name` blocks with different sigs, we lose all but the
        # first. Acceptable for first cut.
        index[[klass, name]] ||= ret
      end
      # RBI-declared struct-field accessors: the regenerated
      # sorbet/rbi/ast-struct-fields.rbi (and any other RBIs) carry typed
      # returns for accessors that lack inline `sig {}` and therefore never
      # made it into existing_sigs. Merge them keyed by [class, field].
      SourceIndex.rbi_field_types.each do |(klass, name), ret|
        next if klass.to_s.empty? || name.to_s.empty?
        next if ret.to_s.empty? || ret == "T.untyped"
        index[[klass, name]] ||= ret
      end
      # Static-inferred returns: when an existing_sigs entry's return is
      # T.untyped but return_origins produced a strong candidate, promote
      # the inferred type into the lookup. This is the bridge that lets
      # newly-inferred returns participate in subsequent receiver-type
      # narrowing without first re-running the signature autofix.
      Array(@store.facts["return_origins"]).each do |origin|
        next unless origin["confidence"].to_s == "strong"
        klass = origin["class"].to_s
        name = origin["method"].to_s
        next if klass.empty? || name.empty?
        type = origin["candidate_type"].to_s
        next unless NilKill.useful_type?(type)
        next if NilKill.weak_type?(type)
        index[[klass, name]] ||= type
      end
      index
    end

    def receiver_inferred_call_return(origin, source, origins_by_callee, methods_by_location, project_method_returns, rbi)
      code = source["code"].to_s
      # `recv.method` optionally followed by args, block, or end of expression.
      # Caller-supplied evidence drives the receiver type; subsequent chains
      # (`recv.method.foo`) are out of scope here.
      m = code.match(/\A([a-z_][a-z_0-9]*)\.([a-z_][a-z_0-9]*[?!]?)(?:[\s({]|\z)/)
      return nil unless m
      recv_name, called_method = m[1], m[2]
      enclosing_method = origin["method"].to_s
      return nil if enclosing_method.empty?
      method_record = methods_by_location[[origin["path"], origin["line"].to_i]]
      return nil unless method_record
      param_index = enclosing_method_param_index(method_record, recv_name)
      return nil unless param_index
      callers = Array(origins_by_callee[enclosing_method])
      return nil if callers.empty?
      param_callers = callers.select do |o|
        slot = o["slot"].to_s
        slot == recv_name || slot == param_index.to_s
      end
      return nil if param_callers.empty?
      # Accept any caller whose `type` field is a useful type, regardless of
      # origin_kind. Real-world `param_origins` use `kind` of "local",
      # "typed_return", "static", etc. The relevant filter is whether the
      # type was inferable, not how it was inferred. Exclude "unknown"
      # explicitly so we don't fall back to global RBI semantics.
      classes = param_callers.filter_map do |o|
        next nil if o["origin_kind"].to_s == "unknown"
        type = o["type"].to_s
        NilKill.useful_type?(type) ? type : nil
      end
      classes = classes.uniq
      # NilClass is not a distinct dispatch target -- a nil receiver
      # means the slot is nilable, not that callers diverge. Don't
      # count it toward divergence; resolve on the non-nil class.
      classes.delete("NilClass")
      return nil if classes.empty?
      return nil if classes.size > 1  # >=2 NON-NIL = real divergence
      cls = classes.first
      # Strip container parameterisation so a class-keyed lookup matches the
      # bare class name. T::Array[X] -> Array. Used for both the project-side
      # method-return index (which keys on raw class names) and as a hint
      # for the stdlib RBI lookup (whose internal owner_name_for also
      # strips, so this is belt-and-suspenders).
      stdlib_owner = NilKill.strip_to_stdlib_owner(cls)
      narrowed = project_method_returns[[cls, called_method]] ||
        (stdlib_owner && project_method_returns[[stdlib_owner, called_method]]) ||
        (stdlib_owner && rbi.return_type(called_method, stdlib_owner)) ||
        rbi.return_type(called_method, cls)
      return nil unless NilKill.useful_type?(narrowed)
      return nil if NilKill.weak_type?(narrowed)
      return nil if narrowed.include?("T.nilable")
      # Runtime cross-check: build a synthetic action shape so we reuse the
      # existing guard. rec is the enclosing method's runtime record.
      rec = method_record_for_origin(origin)
      return nil if rec && runtime_contradicts?(rec, :return, nil, narrowed)
      narrowed
    end

    def enclosing_method_param_index(method_record, recv_name)
      entries = NilKill.extract_param_entries(method_record["sig"].to_s)
      idx = entries.find_index { |name, _type| name.to_s == recv_name }
      idx
    end

    def method_record_for_origin(origin)
      key = [origin["class"].to_s, origin["method"].to_s, origin["kind"].to_s,
             File.expand_path(origin["path"].to_s, ROOT), origin["line"].to_i]
      @store.methods["#{key.join("\0")}"]
    end

    def recompute_origin_candidate_and_confidence!(origin)
      sources = Array(origin["sources"])
      type_sources = sources.filter_map { |s| s["type"] }
      candidate = NilKill.static_sorbet_type(type_sources)
      has_call_untyped = sources.any? { |s| s["kind"].to_s == "call_untyped" || s["kind"].to_s == "unknown" }
      candidate = "T.untyped" if candidate == "NilClass" && has_call_untyped
      useful = NilKill.useful_type?(candidate)
      blockers = Array(origin["blockers"])
      confidence =
        if useful && !NilKill.weak_type?(candidate) && blockers.empty? && !has_call_untyped
          "strong"
        elsif useful
          "weak"
        else
          "blocked"
        end
      origin["candidate_type"] = useful ? candidate : "T.untyped"
      origin["confidence"] = confidence
    end

    # Sorbet-validates every HIGH-confidence action before they leave infer.
    # Catches over-narrow signatures where the proposer trusted incomplete
    # static or runtime evidence (e.g. method body returns a broader type than
    # observed at runtime; nilable receivers wrapped in T.must that Sorbet now
    # flags as redundant).
    #
    # Strategy: snapshot the affected files, apply the HIGH batch, run srb tc.
    # On srb tc success: restore files and keep the actions at HIGH.
    # On srb tc failure: bisect to isolate the failing actions and downgrade
    # them to REVIEW so the user-facing verified loop can re-attempt them
    # under a stronger gate. Always restores files before returning.
    def sorbet_validate_high_actions!
      high = @store.actions.select { |a| a["confidence"] == HIGH }
      return if high.empty?
      paths = high.map { |a| a["path"].to_s }.uniq.reject(&:empty?)
      snapshot = paths.each_with_object({}) do |rel, h|
        abs = File.expand_path(rel, ROOT)
        h[abs] = File.read(abs) if File.file?(abs)
      end
      begin
        failing = sorbet_validate_batch(high, snapshot)
      ensure
        snapshot.each { |path, content| File.write(path, content) }
      end
      return if failing.empty?
      failing_fps = failing.map { |a| sorbet_validate_fingerprint(a) }.to_set
      @store.actions.each do |action|
        next unless action["confidence"] == HIGH
        next unless failing_fps.include?(sorbet_validate_fingerprint(action))
        action["confidence"] = REVIEW
        action["message"] = "[downgraded from high by sorbet pre-validate] #{action["message"]}"
      end
      warn "nil-kill: sorbet pre-validate downgraded #{failing.size} HIGH action(s) to REVIEW"
    end

    def sorbet_validate_batch(actions, snapshot)
      return [] if actions.empty?
      snapshot.each { |path, content| File.write(path, content) }
      Apply.new([]).apply_actions(actions)
      return [] if sorbet_clean?
      return actions if actions.size == 1
      mid = actions.size / 2
      sorbet_validate_batch(actions.first(mid), snapshot) +
        sorbet_validate_batch(actions.drop(mid), snapshot)
    end

    def sorbet_clean?
      _, _, status = Open3.capture3({ "SRB_YES" => "1", "NO_COLOR" => "1" }, "bundle", "exec", "srb", "tc")
      status.success?
    end

    def sorbet_validate_fingerprint(action)
      JSON.generate([action["kind"], action["path"], action["line"], action["message"], action["data"]])
    end

    # Returns true when runtime observations for the given slot contain a class
    # that is not accepted by `proposed_type`. Used to prevent Sorbet-clean-but-
    # runtime-broken narrowings: e.g. caller passes `Symbol :Any` via `node.x || :Any`
    # fallthrough, all statically visible callers pass `Type`, proposer narrows
    # the param to `Type` -- runtime then violates the contract.
    #
    # Returns false when no runtime observation exists for the slot (proposers
    # fall back to their existing static behavior).
    def runtime_contradicts?(rec, slot_kind, slot_name, proposed_type)
      return false unless rec
      observed_classes =
        case slot_kind
        when :return then Array(rec["returns"])
        when :param then Array(rec.dig("params_by_name", slot_name.to_s))
        end
      observed_classes = observed_classes.compact.reject { |c| c.to_s.empty? }
      return false if observed_classes.empty?
      observed_classes.any? { |observed| !proposed_type_accepts?(proposed_type, observed.to_s) }
    end

    def proposed_type_accepts?(proposed_type, observed_class)
      type = proposed_type.to_s.strip
      return false if type.empty?
      return true if type == "T.untyped"
      return false if observed_class.empty?
      # Ignore non-informative observations the proposers themselves filter out.
      return true if observed_class.include?("#") || observed_class.start_with?("Sorbet::Private::")
      # void / T.noreturn: the slot must not return anything; treat any concrete
      # observation as a contradiction. NilClass is also a contradiction for
      # T.noreturn since the method must not return normally at all.
      return observed_class == "NilClass" if type == "void"
      return false if type == "T.noreturn"
      if type.start_with?("T.nilable(") && type.end_with?(")")
        inner = NilKill.strip_nilable_type(type)
        return true if observed_class == "NilClass"
        return proposed_type_accepts?(inner, observed_class)
      end
      if type.start_with?("T.any(") && type.end_with?(")")
        inner = NilKill.extract_call_args(type, "T.any") || ""
        return NilKill.split_top_level(inner).any? { |alt| proposed_type_accepts?(alt.strip, observed_class) }
      end
      return %w[TrueClass FalseClass T::Boolean].include?(observed_class) if type == "T::Boolean"
      # Parameterised collection types: the container shape must match. Runtime
      # observing `Hash` against a proposed `T::Array[T.untyped]` is a hard
      # contradiction -- sorbet-runtime would raise TypeError on that path.
      # Previously this returned `true` unconditionally, which was the root cause
      # of nine of the twelve prspec-only rejections in Move 2: narrowings to
      # `T.nilable(T::Array[T.untyped])` whose runtime trace included other
      # container classes (Hash, custom classes) that the proposer's static
      # analysis missed. Catching them here means the verified loop never
      # attempts them.
      return observed_class == "Array" if type.start_with?("T::Array[")
      return observed_class == "Hash" if type.start_with?("T::Hash[")
      return observed_class == "Set" if type.start_with?("T::Set[")
      return %w[Array Hash Set].include?(observed_class) if type.start_with?("T::Enumerable[")
      type == observed_class
    end

    def runtime_return_type_candidate(rec)
      observed = NilKill.sorbet_type(rec["returns"])
      case observed
      when "Array"
        generic_candidate_type("T::Array[T.untyped]", rec["return_elem"], rec["return_kv"], rec["return_elem_shapes"], rec["return_kv_shapes"]) || observed
      when "Hash"
        generic_candidate_type("T::Hash[T.untyped, T.untyped]", rec["return_elem"], rec["return_kv"], rec["return_elem_shapes"], rec["return_kv_shapes"]) || observed
      when "Set"
        generic_candidate_type("T::Set[T.untyped]", rec["return_elem"], rec["return_kv"], rec["return_elem_shapes"], rec["return_kv_shapes"]) || observed
      else
        observed
      end
    end

    def propose_generic_narrowing_actions(rec, src, sig)
      NilKill.extract_param_entries(sig).each do |name, current_type|
        next unless generic_type?(current_type)
        inner_type = NilKill.strip_nilable_type(current_type)
        candidate = generic_candidate_type(inner_type, rec["param_elem"][name], rec["param_kv"][name],
          rec.dig("param_elem_shapes", name), rec.dig("param_kv_shapes", name))
        candidate = preserve_nilable_wrapper(current_type, candidate)
        next unless candidate && candidate != current_type
        confidence = collection_narrowing_confidence(rec, candidate)
        @store.actions << base_action("narrow_generic_param", confidence, src["path"], src["line"],
          "narrow generic param #{name} from #{current_type} to #{candidate}",
          { "name" => name, "from" => current_type, "type" => candidate, "source" => "collection_runtime" })
      end
      current_return = NilKill.extract_return_type(sig)
      return unless generic_type?(current_return)
      inner_return = NilKill.strip_nilable_type(current_return)
      candidate = generic_candidate_type(inner_return, rec["return_elem"], rec["return_kv"], rec["return_elem_shapes"], rec["return_kv_shapes"])
      candidate = preserve_nilable_wrapper(current_return, candidate)
      return unless candidate && candidate != current_return
      confidence = collection_narrowing_confidence(rec, candidate)
      @store.actions << base_action("narrow_generic_return", confidence, src["path"], src["line"],
        "narrow generic return from #{current_return} to #{candidate}",
        { "from" => current_return, "type" => candidate, "source" => "collection_runtime" })
    end

    def generic_type?(type)
      raw = NilKill.strip_nilable_type(type)
      raw.match?(/\A(?:Array|Hash|Set|T::Array|T::Hash|T::Set)\b/) && raw.include?("T.untyped")
    end

    def preserve_nilable_wrapper(current_type, candidate)
      return nil unless candidate
      current_type.to_s.start_with?("T.nilable(") ? "T.nilable(#{candidate})" : candidate
    end

    def collection_narrowing_confidence(rec, candidate)
      return REVIEW unless NilKill.acceptable_shape_candidate?(candidate)
      return REVIEW unless simple_autofix_collection_candidate?(candidate)
      NilKill.confidence(rec["calls"])
    end

    def simple_autofix_collection_candidate?(candidate)
      raw = NilKill.strip_nilable_type(candidate)
      scalar = /(?:String|Symbol|Integer|Float|T::Boolean)/
      raw.match?(/\AT::Array\[#{scalar}\]\z/) ||
        raw.match?(/\AT::Set\[#{scalar}\]\z/) ||
        raw.match?(/\AT::Hash\[(?:String|Symbol|Integer), #{scalar}\]\z/)
    end

    def generic_candidate_type(current_type, elem_classes, kv_classes, elem_shapes = nil, kv_shapes = nil)
      case current_type.to_s
      when /\A(?:Array|T::Array)\b/
        elem = NilKill.shape_union_type(elem_shapes)
        elem ||= NilKill.conservative_element_type(elem_classes)
        candidate = elem ? "T::Array[#{elem}]" : nil
        candidate if candidate && NilKill.acceptable_shape_candidate?(candidate)
      when /\A(?:Set|T::Set)\b/
        elem = NilKill.shape_union_type(elem_shapes)
        elem ||= NilKill.conservative_element_type(elem_classes)
        candidate = elem ? "T::Set[#{elem}]" : nil
        candidate if candidate && NilKill.acceptable_shape_candidate?(candidate)
      when /\A(?:Hash|T::Hash)\b/
        kv_shape = Array(kv_shapes)
        key = NilKill.shape_union_type(kv_shape[0])
        value = NilKill.shape_union_type(kv_shape[1])
        kv = Array(kv_classes)
        key ||= NilKill.conservative_element_type(kv[0])
        value ||= NilKill.conservative_element_type(kv[1])
        candidate = key && value ? "T::Hash[#{key}, #{value}]" : nil
        candidate if candidate && NilKill.acceptable_shape_candidate?(candidate)
      end
    end

    def propose_dispatcher_inference_actions
      methods = (@store.facts["existing_sigs"] + @store.facts["unsigned_methods"]).each_with_object({}) do |method, hash|
        hash[[method["path"], method["class"], method["kind"], method["method"]]] = method
      end
      @store.facts["dispatcher_inferences"].each do |inf|
        method = methods[[inf["path"], inf["class"], inf["kind"], inf["helper"]]]
        next unless method && method["params"].size == 1
        param = method["params"].first["name"]
        type = inf["type"]
        if method["has_sig"]
          next unless method["sig"].to_s.match?(/\b#{Regexp.escape(param)}:\s*T\.untyped\b/)
          @store.actions << base_action("fix_sig_param", REVIEW, method["path"], method["line"],
            "dispatcher #{inf["dispatcher"]} proves #{method["method"]} param #{param} is #{type}",
            { "name" => param, "type" => type, "source" => "dispatcher", "dispatcher_line" => inf["line"] })
        else
          sig = "sig { params(#{param}: #{type}).returns(T.untyped) }"
          @store.actions << base_action("add_sig", REVIEW, method["path"], method["line"],
            "add dispatcher-inferred sig from #{inf["dispatcher"]}", { "sig" => sig, "scope" => method["scope"], "source" => "dispatcher", "dispatcher_line" => inf["line"] })
        end
      end
    end

    def propose_static_param_backflow_actions
      methods_by_name = Array(@store.facts["existing_sigs"]).group_by { |method| method["method"].to_s }
      origins_by_callee = Array(@store.facts["param_origins"]).group_by { |origin| origin["callee"].to_s }
      protocol_index = static_param_backflow_protocol_index
      protocol_resolver = ProtocolResolver.new(@store)
      methods_by_name.each do |name, methods|
        # Class-scoped: a shared method name no longer blocks the whole
        # group. Each method is evaluated independently; the per-method
        # runtime_contradicts? + protocol-rejection guards below, and the
        # verified loop's bisection, reject any candidate that does not
        # actually hold for a given class. (B:34 name-shared bucket.)
        methods.each do |method|
        sig = method["sig"].to_s
        NilKill.extract_param_entries(sig).each_with_index do |(param_name, current_type), idx|
          next unless current_type == "T.untyped"
          origins = origins_by_callee[name].to_a.select do |origin|
            origin["slot"].to_s == idx.to_s || origin["slot"].to_s == param_name.to_s
          end
          candidate, reason = static_param_backflow_candidate(origins)
          next unless candidate && NilKill.strong_trace_type?(candidate)
          protocol_rejection = static_param_backflow_protocol_rejection(method, param_name, candidate, protocol_index, protocol_resolver)
          next if protocol_rejection
          rec = @store.method_record([method["class"], method["method"], method["kind"], File.expand_path(method["path"], ROOT), method["line"]])
          next if runtime_contradicts?(rec, :param, param_name, candidate)
          next if existing_signature_action?(method["path"], method["line"], "fix_sig_param", param_name, candidate)
          @store.actions << base_action("fix_sig_param", REVIEW, method["path"], method["line"],
            "static callsites prove param #{param_name} is #{candidate}; #{reason}",
            { "name" => param_name, "type" => candidate, "source" => "static_param_backflow",
              "callsites" => static_param_backflow_callsites(origins), "callsite_count" => origins.size })
        end
        end
      end
    end

    def static_param_backflow_candidate(origins)
      origins = Array(origins)
      return [nil, "no static callsites"] if origins.empty?
      return [nil, "unknown/dynamic callsite expression"] if origins.any? { |origin| origin["origin_kind"].to_s == "unknown" || origin["type"].to_s.empty? }
      # A `local` origin means the caller passed the arg via a local
      # variable. SourceIndex has ALREADY resolved that local's type
      # via expression_type when it recorded `origin["type"]` -- the
      # same machinery trusted for `static`/`typed_return` origins. The
      # old blanket "any local -> bail" guard threw away every such
      # case even when the type was concretely known (e.g. a caller
      # `name = "x"; closest_name(name)` -> origin type "String").
      # Only reject locals whose type is NOT resolved; resolved-type
      # locals flow into the normal aggregation, still gated downstream
      # by weak/Object/conflicting checks, runtime_contradicts?, the
      # protocol resolver, and the verified loop.
      return [nil, "local alias with unresolved type"] if origins.any? do |origin|
        origin["origin_kind"].to_s == "local" && !NilKill.useful_type?(origin["type"].to_s)
      end
      types = origins.filter_map { |origin| origin["type"].to_s unless origin["type"].to_s.empty? }
      candidate = NilKill.static_sorbet_type(types)
      return [nil, "conflicting static callsite types"] unless NilKill.useful_type?(candidate)
      return [nil, "weak static callsite type #{candidate}"] if NilKill.weak_type?(candidate)
      return [nil, "non-informative static callsite type #{candidate}"] if NilKill.strip_nilable_type(candidate) == "Object"
      [candidate, "#{origins.size} static callsite(s) agree"]
    end

    def static_param_backflow_protocol_rejection(method, param_name, candidate, protocol_index, protocol_resolver = nil)
      gaps = Array(method.dig("protocols", param_name.to_s, "gaps")).map(&:to_s)

      if gaps.empty?
        required = Array(method.dig("protocols", param_name.to_s, "methods"))
          .map(&:to_s)
          .reject { |name| static_param_backflow_ignorable_protocol_method?(name) }
          .uniq
      else
        return "candidate #{candidate} requires recursive protocol analysis: #{gaps.first}" unless protocol_resolver
        resolved = protocol_resolver.required_methods(method["class"], method["method"], param_name)
        if resolved["blocked"]
          return "candidate #{candidate} hit unresolvable forwarding chain: #{resolved["chain"].first(3).join(' -> ')}"
        end
        required = resolved["methods"]
      end
      return nil if required.empty?

      type = NilKill.strip_nilable_type(candidate)
      return nil if type == "T::Boolean" || type == "Object"

      available = protocol_index[type]
      return "candidate #{candidate} has no known protocol for required ##{required.sort.join(", #")}" unless available

      missing = required.reject { |name| available.include?(name) }
      return nil if missing.empty?

      "candidate #{candidate} lacks required ##{missing.sort.join(", #")}"
    end

    def static_param_backflow_protocol_index
      index = Hash.new { |hash, key| hash[key] = Set.new }
      (Array(@store.facts["existing_sigs"]) + Array(@store.facts["unsigned_methods"])).each do |method|
        next unless method["kind"] == "instance" && !method["class"].to_s.empty?
        index[method["class"].to_s] << method["method"].to_s
      end
      Array(@store.facts["struct_declarations"]).each do |decl|
        Array(decl["fields"]).each { |field| index[decl["class"].to_s] << field.to_s }
      end
      index
    end

    def static_param_backflow_ignorable_protocol_method?(name)
      %w[
        nil? class is_a? kind_of? instance_of? object_id respond_to?
        instance_variable_get instance_variable_set itself tap then yield_self
      ].include?(name.to_s)
    end

    def static_param_backflow_callsites(origins)
      origins.each_with_object(Hash.new(0)) do |origin, calls|
        key = "#{origin["path"]}:#{origin["line"]}:#{origin["code"]}"
        calls[key] += 1
      end
    end

    def existing_signature_action?(path, line, kind, name, type)
      @store.actions.any? do |action|
        action["kind"] == kind &&
          action["path"].to_s == path.to_s &&
          action["line"].to_i == line.to_i &&
          action.dig("data", "name").to_s == name.to_s &&
          action.dig("data", "type").to_s == type.to_s
      end
    end

    def propose_forwarded_return_chain_actions
      untyped_methods = @store.facts["existing_sigs"].select do |method|
        NilKill.extract_return_type(method["sig"].to_s) == "T.untyped"
      end
      return if untyped_methods.empty?

      origin_by_location = @store.facts["return_origins"].each_with_object({}) do |origin, lookup|
        lookup[[origin["path"], origin["line"].to_i, origin["class"].to_s, origin["method"].to_s, origin["kind"].to_s]] = origin
      end
      resolver = ForwardedReturnResolver.new(@store)
      untyped_methods.each do |method|
        origin = method["return_origin"] || origin_by_location[[method["path"], method["line"].to_i, method["class"].to_s, method["method"].to_s, method["kind"].to_s]]
        next unless origin
        resolved = resolver.resolve(origin)
        next unless resolved && resolved["forwarded"]
        type = resolved["type"]
        next unless NilKill.useful_type?(type)
        next if NilKill.weak_type?(type)
        rec = @store.method_record([method["class"], method["method"], method["kind"], File.expand_path(method["path"], ROOT), method["line"]])
        next if runtime_contradicts?(rec, :return, nil, type)

        confidence = simple_forwarded_return_candidate?(type) ? HIGH : REVIEW
        @store.actions << base_action("fix_sig_return", confidence, method["path"], method["line"],
          "existing sig return is T.untyped; forwarded-return chain resolves to #{type}",
          { "type" => type, "source" => "forwarded_return_chain", "chain" => resolved["chain"].first(12) })
      end
    end

    def simple_forwarded_return_candidate?(type)
      %w[String Integer Float Symbol T::Boolean].include?(type.to_s)
    end

    class ForwardedReturnResolver
      def initialize(store)
        @store = store
        @origins_by_name = Array(store.facts["return_origins"]).group_by { |origin| origin["method"].to_s }
        @sig_counts_by_name = Array(store.facts["existing_sigs"]).each_with_object(Hash.new(0)) do |method, counts|
          counts[method["method"].to_s] += 1
        end
        @sig_types_by_name = Array(store.facts["existing_sigs"]).each_with_object(Hash.new { |h, k| h[k] = [] }) do |method, types|
          ret = NilKill.extract_return_type(method["sig"].to_s)
          types[method["method"].to_s] << ret if NilKill.useful_type?(ret)
        end
        @resolved = {}
      end

      def resolve(origin, stack = [])
        key = origin_key(origin)
        return @resolved[key] if @resolved.key?(key)
        return nil if stack.include?(key)

        sources = Array(origin["sources"])
        return nil if sources.empty?

        types = []
        chain = [format_origin(origin)]
        forwarded = false
        sources.each do |source|
          case source["kind"].to_s
          when "static", "assignment", "typed_call", "safe_call"
            type = source["type"]
            return nil unless NilKill.useful_type?(type)
            types << type
            forwarded ||= %w[typed_call safe_call].include?(source["kind"].to_s)
            chain << format_source(source)
          when "nil"
            types << "NilClass"
          when "call_untyped"
            callee = source["callee"].to_s
            callee_resolved = resolve_callee(callee, stack + [key])
            return nil unless callee_resolved
            types << callee_resolved["type"]
            forwarded = true
            chain << format_source(source)
            chain.concat(Array(callee_resolved["chain"]))
          else
            return nil
          end
        end

        type = NilKill.static_sorbet_type(types)
        return nil unless NilKill.useful_type?(type)

        @resolved[key] = { "type" => type, "chain" => chain.uniq, "forwarded" => forwarded }
      end

      private

      def resolve_callee(callee, stack)
        sig_types = Array(@sig_types_by_name[callee]).compact.uniq
        typed_sig_types = sig_types.reject { |type| type == "T.untyped" || type == "void" }
        if @sig_counts_by_name[callee] == 1 && typed_sig_types.size == 1 && sig_types.size == 1
          return { "type" => typed_sig_types.first, "chain" => ["typed signature #{callee}: #{typed_sig_types.first}"], "forwarded" => true }
        end

        origins = Array(@origins_by_name[callee])
        return nil unless origins.size == 1
        resolve(origins.first, stack)
      end

      def origin_key(origin)
        [origin["path"], origin["line"].to_i, origin["class"].to_s, origin["method"].to_s, origin["kind"].to_s]
      end

      def format_origin(origin)
        "#{origin["path"]}:#{origin["line"]} #{origin["class"]}##{origin["method"]}"
      end

      def format_source(source)
        callee = source["callee"] || source["code"] || source["kind"]
        "#{source["kind"]} #{callee} at line #{source["line"]}"
      end
    end

    # Resolves the transitive protocol required of a method's param by
    # walking forwarded helpers and ivar captures. Used by
    # `static_param_backflow_protocol_rejection` to decide whether a
    # narrowing candidate satisfies the chain.
    #
    # Cycle-safe via a stub cache entry written before recursion.
    # Returns { "methods" => Set, "chain" => Array, "blocked" => bool }.
    # `blocked` is true when ANY hop hits a forwarded helper not in the
    # project method index, an ivar with no observed protocol, or an
    # unrecognised gap shape. The caller falls back to the conservative
    # rejection in that case.
    class ProtocolResolver
      FORWARDED_GAP_RE = /\Aforwarded to (\S+) slot (\d+) at /.freeze
      LEGACY_FORWARDED_GAP_RE = /\Aforwarded to (\S+) at /.freeze
      CAPTURED_GAP_RE = /\Acaptured in (@\S+) at /.freeze

      IGNORABLE_METHODS = %w[
        nil? class is_a? kind_of? instance_of? object_id respond_to?
        instance_variable_get instance_variable_set itself tap then yield_self
      ].to_set.freeze

      def initialize(store)
        @store = store
        @methods_by_name = (Array(store.facts["existing_sigs"]) + Array(store.facts["unsigned_methods"]))
          .group_by { |method| method["method"].to_s }
        @ivar_protocols = (store.facts["ivar_protocols"] || {}).each_with_object({}) do |(key, methods), h|
          klass, ivar = key.split("\0", 2)
          h[[klass, ivar]] = Set.new(methods.map(&:to_s))
        end
        @cache = {}
      end

      def resolve(class_name, method_name, param_name)
        key = [class_name.to_s, method_name.to_s, param_name.to_s]
        return @cache[key] if @cache.key?(key)
        # Stub the cache before recursing so cycles see an empty entry
        # and return without infinite descent.
        @cache[key] = { "methods" => Set.new, "chain" => [], "blocked" => false }
        method = lookup_method(class_name, method_name)
        unless method
          return @cache[key] = { "methods" => Set.new, "chain" => ["unknown #{class_name}##{method_name}"], "blocked" => true }
        end

        protocol = method.dig("protocols", param_name.to_s) || {}
        methods = Set.new(Array(protocol["methods"]).map(&:to_s))
        chain = ["#{class_name}##{method_name}(#{param_name})"]
        blocked = false

        Array(protocol["gaps"]).each do |gap|
          gap = gap.to_s
          helper_name = nil
          slot = 0
          if (m = FORWARDED_GAP_RE.match(gap))
            helper_name = m[1]
            slot = m[2].to_i
          elsif (m = LEGACY_FORWARDED_GAP_RE.match(gap))
            helper_name = m[1]
          end

          if helper_name
            helper = lookup_helper(helper_name)
            if helper && helper["params"] && helper["params"][slot]
              helper_param = helper["params"][slot]["name"].to_s
              sub = resolve(helper["class"], helper["method"], helper_param)
              methods.merge(sub["methods"])
              chain.concat(sub["chain"])
              blocked ||= sub["blocked"]
            else
              chain << "unresolved forward to #{helper_name} slot #{slot}"
              blocked = true
            end
          elsif (m = CAPTURED_GAP_RE.match(gap))
            ivar = m[1]
            ivar_methods = @ivar_protocols[[class_name.to_s, ivar]]
            if ivar_methods && !ivar_methods.empty?
              methods.merge(ivar_methods)
              chain << "captured to #{ivar} (#{ivar_methods.size} method(s))"
            else
              chain << "captured to #{ivar} (no observed methods)"
              blocked = true
            end
          else
            chain << "unparseable gap: #{gap}"
            blocked = true
          end
        end

        @cache[key] = { "methods" => methods, "chain" => chain, "blocked" => blocked }
      end

      def required_methods(class_name, method_name, param_name)
        result = resolve(class_name, method_name, param_name)
        {
          "methods" => result["methods"].reject { |m| IGNORABLE_METHODS.include?(m) }.sort,
          "chain" => result["chain"],
          "blocked" => result["blocked"],
        }
      end

      private

      def lookup_method(class_name, method_name)
        Array(@methods_by_name[method_name.to_s]).find { |m| m["class"].to_s == class_name.to_s }
      end

      # A forwarded gap stores the helper as written at the call-site
      # (`helper_name(args)`), so it's a bare method name. There can be
      # multiple project methods sharing the name across classes -- if
      # ambiguous, prefer one in the same class as the caller would
      # require per-method-record class context, which we don't have
      # here. Return nil for ambiguous lookups -> chain is blocked.
      def lookup_helper(helper_name)
        candidates = Array(@methods_by_name[helper_name.to_s])
        return candidates.first if candidates.size == 1
        nil
      end
    end

    def propose_tlet_action(site)
      abs = File.expand_path(site["path"], ROOT)
      obs = @store.tlets["#{abs}:#{site["line"]}"]
      if site["tlet"] && site["type"] == "T.untyped" && obs
        type = NilKill.sorbet_type(obs["classes"])
        return unless NilKill.useful_type?(type)
        return if type == "NilClass"
        @store.actions << base_action("narrow_tlet", NilKill.confidence(obs["calls"]), site["path"], site["line"],
          "narrow existing T.let to #{type}", { "type" => type })
      elsif !site["tlet"] && site["candidate_type"]
        return unless NilKill.useful_type?(site["candidate_type"])
        return if site["candidate_type"] == "NilClass"
        @store.actions << base_action("add_tlet", HIGH, site["path"], site["line"],
          "add T.let for #{site["name"]}", { "name" => site["name"], "type" => site["candidate_type"] })
      end
    end

    def sig_for(rec, src)
      params = src["params"].map do |param|
        type = NilKill.sorbet_type(params_for_typing(rec)[param["name"]] || [])
        type = "T.untyped" unless NilKill.useful_type?(type)
        type = "T.nilable(#{type})" if param["nil_default"] && !type.start_with?("T.nilable(") && type != "T.untyped"
        "#{param["name"]}: #{type}"
      end
      ret = src["method"] == "initialize" && src["kind"] == "instance" ? nil : NilKill.sorbet_type(rec["returns"])
      if !NilKill.useful_type?(ret)
        origin_type = src.dig("return_origin", "candidate_type")
        ret = origin_type if NilKill.useful_type?(origin_type)
      end
      ret = "T.untyped" unless ret.nil? || NilKill.useful_type?(ret)
      clause = ret.nil? ? "void" : "returns(#{ret})"
      params.empty? ? "sig { #{clause} }" : "sig { params(#{params.join(", ")}).#{clause} }"
    end

    def params_for_typing(rec)
      rec["params_ok"].empty? ? rec["params_by_name"] : rec["params_ok"]
    end

    def report_bad_input_candidates(rec, src)
      return if rec["params_ok"].empty? || rec["params_raised"].empty?
      rec["params_by_name"].each do |name, all_classes|
        ok_classes = Array(rec["params_ok"][name])
        raised_classes = Array(rec["params_raised"][name])
        next if ok_classes.empty? || raised_classes.empty?
        extra = all_classes - ok_classes
        next if extra.empty?
        broad = NilKill.display_union(all_classes)
        narrow = NilKill.sorbet_type(ok_classes)
        next unless broad.include?("T.any(") && NilKill.useful_type?(narrow)
        @store.actions << base_action("bad_input_type_candidate", REVIEW, src["path"], src["line"],
          "param #{name} would become #{broad} only because raised calls saw #{extra.sort.join(", ")}; normal calls suggest #{narrow}",
          { "name" => name, "broad_type" => broad, "candidate_type" => narrow, "raised_only_classes" => extra.sort,
            "callsites" => filtered_sites(rec["param_sites_raised"][name], extra) })
      end
    end

    def report_nil_param_candidates(rec, src)
      params_for_typing(rec).each do |name, classes|
        next unless Array(classes).include?("NilClass")
        non_nil = Array(classes) - ["NilClass"]
        candidate = NilKill.sorbet_type(non_nil)
        @store.actions << base_action("nil_param_observed", REVIEW, src["path"], src["line"],
          "param #{name} observed nil; source should be traced before adding T.nilable#{NilKill.useful_type?(candidate) ? " (non-nil candidate: #{candidate})" : ""}",
          { "name" => name, "candidate_type" => candidate, "callsites" => filtered_sites(param_sites_for_typing(rec)[name], ["NilClass"]) })
        propose_nil_default_actions(rec, src, name, candidate)
      end
    end

    def propose_nil_default_actions(rec, src, name, candidate)
      default = default_for_type(candidate)
      return unless default
      filtered_sites(param_sites_for_typing(rec)[name], ["NilClass"]).each do |site, count|
        root = site.sub(/:[^:]+\z/, "")
        path, line = split_site(root)
        next unless path && line && NilKill.target_path?(path)
        rel_path = NilKill.rel(path)
        next unless callsite_default_rewrite_safe?(rel_path, line)
        @store.actions << base_action("replace_nil_with_default", REVIEW, rel_path, line,
          "replace nil with #{default} for #{src["class"]}##{src["method"]} param #{name} (#{count} observed call(s))",
          { "default" => default, "name" => name, "candidate_type" => candidate, "observed_calls" => count.to_i,
            "target_path" => src["path"], "target_line" => src["line"], "target_method" => "#{src["class"]}##{src["method"]}" })
      end
    end

    def default_for_type(type)
      case type
      when "Array", /\AT::Array\b/ then "[]"
      when "Hash", /\AT::Hash\b/ then "{}"
      when "String" then "\"\""
      else nil
      end
    end

    def split_site(site)
      match = site.match(/\A(.+):(\d+)\z/)
      match ? [match[1], match[2].to_i] : [nil, nil]
    end

    def callsite_default_rewrite_safe?(rel_path, line)
      source = File.readlines(File.join(ROOT, rel_path))[line - 1]
      return false unless source
      return false if source.match?(/^\s*def\b/)
      source.scan(/\bnil\b/).size == 1
    rescue Errno::ENOENT
      false
    end

    def report_union_candidates(rec, src)
      params_for_typing(rec).each do |name, classes|
        others = Array(classes).reject { |c| c == "NilClass" }
        next unless others.uniq.size > 1
        @store.actions << base_action("union_observed", REVIEW, src["path"], src["line"],
          "param #{name} observed #{others.uniq.sort.join(", ")}; leaving as T.untyped by default until more evidence or design intent is clear",
          { "name" => name, "classes" => others.uniq.sort, "callsites" => filtered_sites(param_sites_for_typing(rec)[name], others.uniq) })
      end
    end

    def param_sites_for_typing(rec)
      rec["param_sites_ok"].empty? ? rec["param_sites"] : rec["param_sites_ok"]
    end

    def filtered_sites(sites, classes)
      wanted = Array(classes).to_set
      (sites || {}).select { |site, _count| wanted.include?(site_class(site)) }
    end

    def site_class(site)
      site.to_s.split(":").last
    end

    def base_action(kind, conf, path, line, message, data)
      { "kind" => kind, "confidence" => conf, "path" => path, "line" => line, "message" => message, "data" => data }
    end

    def merge_hash_sets(target, source)
      (source || {}).each { |name, vals| target[name] = (Array(target[name]) + Array(vals)).uniq.sort }
    end

    def merge_hash_kv(target, source)
      (source || {}).each { |name, kv| merge_kv((target[name] ||= [[], []]), kv) }
    end

    def merge_hash_shapes(target, source)
      (source || {}).each { |name, shapes| merge_shapes((target[name] ||= []), shapes) }
    end

    def merge_hash_kv_shapes(target, source)
      (source || {}).each { |name, kv| merge_kv_shapes((target[name] ||= [[], []]), kv) }
    end

    def merge_hash_counts(target, source)
      (source || {}).each do |name, sites|
        bucket = (target[name] ||= {})
        (sites || {}).each { |site, count| bucket[site] = bucket.fetch(site, 0) + count.to_i }
      end
    end

    def merge_kv(target, source)
      return unless source
      target[0] = (Array(target[0]) + Array(source[0])).uniq.sort
      target[1] = (Array(target[1]) + Array(source[1])).uniq.sort
    end

    def merge_shapes(target, source)
      seen = target.map { |shape| JSON.generate(shape) }.to_set
      Array(source).each do |shape|
        parsed = NilKill.parse_shape(shape)
        key = JSON.generate(parsed)
        next if seen.include?(key)
        target << parsed
        seen << key
      end
      target.sort_by! { |shape| JSON.generate(shape) }
    end

    def merge_kv_shapes(target, source)
      return unless source
      merge_shapes(target[0], Array(source)[0])
      merge_shapes(target[1], Array(source)[1])
    end

    def parse_sorbet_errors(output)
      output.lines.filter_map do |line|
        next unless line =~ /^(.*?\.rb):(\d+):\s+(.*?)\s+https:\/\/srb\.help\/(\d+)/
        { "path" => $1, "line" => $2.to_i, "message" => $3, "code" => $4 }
      end
    end

    def parse_nil_origins(output)
      origins = Hash.new(0)
      current = false
      output.gsub(/\e\[[0-9;]*m/, "").each_line do |line|
        if line =~ /^(.*?\.rb):(\d+):.*does not exist on/
          current = true
        elsif current && line =~ /^\s+(.*?\.rb):(\d+):/
          origins["#{$1}:#{$2}"] += 1
          current = false
        end
      end
      origins.sort_by { |_, count| -count }.map { |origin, count| { "origin" => origin, "count" => count } }
    end

    def parse_sorbet_feedback(output)
      feedback = []
      lines = output.gsub(/\e\[[0-9;]*m/, "").lines
      lines.each_with_index do |line, idx|
        case line
        when /^(.+?\.rb):(\d+): Expected `(.+?)` but found `(.+?)` for argument `(.+?)` https:\/\/srb\.help\/7002/
          path = $1
          line_no = $2.to_i
          expected = $3
          found = $4
          arg = $5
          sig_path, sig_line = following_sig_location(lines, idx, /for argument `#{Regexp.escape(arg)}` of method/)
          feedback << { "code" => "7002", "path" => sig_path || path, "line" => sig_line || line_no,
            "arg" => arg, "expected" => expected, "found" => found,
            "message" => "Sorbet 7002 suggests widening param #{arg}: expected #{expected}, found #{found}" }
        when /^(.+?\.rb):(\d+): Expected `(.+?)` but found `(.+?)` for method result type https:\/\/srb\.help\/7005/
          path = $1
          line_no = $2.to_i
          expected = $3
          found = $4
          sig_path, sig_line = following_sig_location(lines, idx, /for result type of method/)
          feedback << { "code" => "7005", "path" => sig_path || path, "line" => sig_line || line_no,
            "expected" => expected, "found" => found,
            "message" => "Sorbet 7005 suggests widening return: expected #{expected}, found #{found}" }
        when /^(.+?\.rb):(\d+): Used `&\.` operator on `(.+?)`, which can never be nil https:\/\/srb\.help\/7034/
          path = $1
          line_no = $2.to_i
          type = $3
          origin_path, origin_line = following_origin_location(lines, idx)
          feedback << { "code" => "7034", "path" => origin_path || path, "line" => origin_line || line_no,
            "site_path" => path, "site_line" => line_no, "type" => type,
            "message" => "Sorbet 7034 says defensive safe navigation is unreachable; review before removing or widen origin" }
        end
      end
      feedback
    end

    def following_sig_location(lines, start_idx, marker)
      idx = start_idx + 1
      while idx < lines.length && idx < start_idx + 30
        if lines[idx].match?(marker)
          loc = lines[idx + 1]
          return [$1, $2.to_i] if loc && loc =~ /^\s+(.+?\.rb):(\d+):$/
        end
        idx += 1
      end
      [nil, nil]
    end

    def following_origin_location(lines, start_idx)
      idx = start_idx + 1
      while idx < lines.length && idx < start_idx + 25
        if lines[idx] =~ /^\s+Got `.+` originating from:$/
          loc = lines[idx + 1]
          return [$1, $2.to_i] if loc && loc =~ /^\s+(.+?\.rb):(\d+):/
        end
        idx += 1
      end
      [nil, nil]
    end
  end
end
