# typed: false
# frozen_string_literal: true

module NilKill
  class TracePlan
    def self.write(path = TRACE_PLAN_PATH)
      new.write(path)
    end

    def initialize
      @methods = {}
      @tlets = {}
      @struct_fields = {}
      @state_write_site_owners = {}
      @runtime_call_sites = {}
      @runtime_result_call_sites = {}
      @runtime_collection_receiver_sites = {}
      @runtime_native_activation_sites = {}
    end

    def write(path)
      files = NilKill.target_files
      runtime_evidence_plan = nil
      unless files.empty?
        static = StaticEvidence.build_trace_plan(files, root: ROOT)
        runtime_evidence_plan = StaticEvidence.build_runtime_evidence_plan(files, root: ROOT)
        static.fetch("methods", []).each { |method| add_static_method(method) }
        facts = Hash(static["facts"])
        tlet_types = Array(facts["tlet_sites"]).to_h do |site|
          add_tlet(site)
          [[File.expand_path(site["path"], ROOT), site["line"].to_i], site["type"]]
        end
        Array(facts["struct_declarations"]).each { |decl| add_struct_decl(decl) }
        Array(facts["runtime_call_sites"]).each { |site| add_runtime_value_site(@runtime_call_sites, site) }
        Array(facts["runtime_result_call_sites"]).each { |site| add_runtime_value_site(@runtime_result_call_sites, site) }
        Array(facts["runtime_collection_receiver_sites"]).each { |site| add_runtime_value_site(@runtime_collection_receiver_sites, site) }
        static.fetch("fields", []).each { |field| add_static_field(field, tlet_types) }
        Array(facts["state_type_records"]).each { |field| add_static_state_type(field) }
        # Flow-derived state records are intentionally conservative and may
        # report T.untyped for assignments to a field whose declaration is
        # already strong. The declaration is the enforceable Sorbet contract,
        # so apply it last and let it suppress redundant runtime sampling.
        Array(facts["type_definitions"]).each { |definition| add_static_type_definition(definition) }
      end
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, JSON.pretty_generate({
        "version" => 1,
        "generated_at" => Time.now.utc.iso8601,
        "target_dirs" => NilKill.target_dirs.map { |dir| File.expand_path(dir, ROOT) }.sort,
        "target_exclude_dirs" => NilKill.target_exclude_dirs.map { |dir| File.expand_path(dir, ROOT) }.sort,
        "methods" => @methods,
        "tlets" => @tlets,
        "struct_fields" => @struct_fields,
        "state_write_sites" => state_write_sites,
        "runtime_call_sites" => @runtime_call_sites,
        "runtime_result_call_sites" => @runtime_result_call_sites,
        "runtime_collection_receiver_sites" => @runtime_collection_receiver_sites,
        "runtime_native_activation_sites" => @runtime_native_activation_sites,
        # Public FactMine <-> collector contract. The other fields in this
        # file are private NilKill instrumentation controls.
        "runtime_evidence" => runtime_evidence_plan,
      }))
      write_collector_plan(File.join(File.dirname(path), COLLECTOR_PLAN_NAME), runtime_evidence_plan)
    end

    private

    # The collector reads this instead of the plan above. Everything it needs is
    # already decided here, so the traced process is handed flat records rather
    # than a JSON document plus the reshaping code to turn it into demands.
    # Records are \x02-separated because demand keys themselves contain \x01.
    def write_collector_plan(path, runtime_evidence_plan)
      lines = []
      NilKill.target_dirs.each { |dir| lines << ["t", File.expand_path(dir, ROOT)] }
      demands = {}
      states = {}
      Array(runtime_evidence_plan && runtime_evidence_plan["requests"]).each do |request|
        anchor = request["anchor"]
        next unless anchor.is_a?(Hash)

        abs = File.expand_path(anchor.fetch("relative_path"), ROOT)
        name = anchor.fetch("display_name").to_s
        range = request["execution_range"] || anchor["range"]
        if range.is_a?(Hash)
          symbol = anchor.fetch("symbol").to_s
          (range.fetch("start_line").to_i..range.fetch("end_line").to_i).each do |line|
            demands["#{abs}\x01#{line + 1}\x01#{name}"] ||= symbol
          end
        end
        next unless anchor["kind"] == "STATE_WRITE" && !name.empty?

        own_range = anchor["range"]
        next unless own_range.is_a?(Hash)

        states["#{abs}\x01#{own_range.fetch("start_line").to_i + 1}\x01#{name}"] = "@#{name}"
      end
      demands.each { |key, symbol| lines << ["d", key, symbol] }
      states.each { |key, ivar| lines << ["s", key, ivar] }
      @struct_fields.each { |key, sampled| lines << ["f", key, sampled ? "1" : "0"] }
      @tlets.each_key { |key| lines << ["l", key] }
      File.write(path, lines.map { |fields| fields.join("\x02") }.join("\n") + "\n")
    end

    def add_method(method)
      abs = File.expand_path(method["path"], ROOT)
      key = [method["class"], method["method"], method["kind"], abs, method["line"]].join("\0")
      param_types = NilKill.extract_param_entries(method["sig"]).to_h
      params = {}
      method["params"].each do |param|
        name = param["name"].to_s
        type = param_types[name] || param["type"]
        params[name] = !NilKill.strong_trace_type?(type)
      end
      return_type = NilKill.extract_return_type(method["sig"])
      sample_return = !void_signature?(method["sig"]) && !NilKill.strong_trace_type?(return_type)
      sample_method = params.values.any? || sample_return
      @methods[key] = {
        "frame" => sample_method,
        "params" => params,
        "return" => sample_return,
        "sample" => sample_method,
      }
    end

    def add_static_method(method)
      signature = method["signature"].to_s
      param_types = NilKill.extract_param_entries(signature).to_h
      untraceable = Array(method["untraceable_params"]).map(&:to_s).to_set
      params = Array(method["params"]).reject { |name| untraceable.include?(name.to_s) }.to_h do |name|
        type = param_types[name.to_s]
        [name.to_s, !NilKill.strong_trace_type?(type)]
      end
      return_type = NilKill.extract_return_type(signature)
      sample_return = !void_signature?(signature) && !NilKill.strong_trace_type?(return_type)
      sample_method = params.values.any? || sample_return
      name = method_name(method)
      key = [
        method["owner"].to_s,
        name,
        method_kind(method),
        File.expand_path(method["path"], ROOT),
        method["line"],
      ].join("\0")
      @methods[key] = {
        "frame" => sample_method,
        "params" => params,
        "return" => sample_return,
        "sample" => sample_method,
      }
    end

    def add_tlet(site)
      return unless site["tlet"]
      type = site["type"]
      return if NilKill.strong_trace_type?(type)
      @tlets[[File.expand_path(site["path"], ROOT), site["line"]].join("\0")] = true
    end

    # FactMine has already chosen these semantic source ranges. TracePoint
    # exposes a line (not a source AST), so expand only the selected range's
    # lines into opaque lookup keys. No Ruby syntax or flow interpretation
    # belongs in this adapter.
    def add_runtime_value_site(index, site)
      path = site["path"].to_s
      span = Array(site["span"])
      return if path.empty? || span.length != 4

      activation_span = Array(site["activation_span"])
      activation_span = span unless activation_span.length == 4
      activation_line = activation_span.values_at(0, 2).map(&:to_i).min
      selector = site["selector"].to_s
      first_line, last_line = span.values_at(0, 2).map(&:to_i).minmax
      # FactMine may select an enclosing line to arm a native call before a
      # multiline expression begins. Ruby then emits later :line events inside
      # that expression. Retain the same explicit selector window on every
      # capture-span line so those events do not disarm the requested capture.
      # This is a direct span-to-instrumentation projection; NilKill performs no
      # source, CFG, or DFG inference here.
      ([activation_line] + (first_line..last_line).to_a).uniq.each do |line|
        activation_key = [File.expand_path(path, ROOT), line].join("\0")
        if selector.empty?
          @runtime_native_activation_sites[activation_key] = true
        elsif @runtime_native_activation_sites[activation_key] != true
          @runtime_native_activation_sites[activation_key] =
            (Array(@runtime_native_activation_sites[activation_key]) | [selector]).sort
        end
      end

      (first_line..last_line).each do |line|
        key = [File.expand_path(path, ROOT), line].join("\0")
        if selector.empty?
          index[key] = true
        elsif index[key] != true
          index[key] = (Array(index[key]) | [selector]).sort
        end
      end
    end

    def add_struct_decl(decl)
      field_types = Hash(decl["field_types"])
      decl.fetch("fields", []).each do |field|
        type = field_types[field.to_s]
        @struct_fields[[decl["class"], field.to_s].join("\0")] =
          type.to_s.empty? || !NilKill.strong_trace_type?(type)
      end
    end

    def add_struct_static(field)
      klass = field["class"].to_s
      name = field["field"].to_s
      type = field["type"] || field["candidate_type"]
      key = [klass, name].join("\0")
      @struct_fields[key] = !NilKill.strong_trace_type?(type)
    end

    def add_static_state_type(field)
      klass = field["owner"].to_s
      name = field["field"].to_s.sub(/\A@/, "")
      type = field["declared_type"].to_s
      return if klass.empty? || name.empty? || type.empty?

      @struct_fields[[klass, name].join("\0")] = !NilKill.strong_trace_type?(type)
    end

    def add_static_type_definition(definition)
      return unless definition["kind"].to_s == "state_field"

      klass = definition["owner"].to_s
      name = definition["name"].to_s.sub(/\A@/, "")
      type = definition["declared_type"].to_s
      return if klass.empty? || name.empty? || type.empty?

      @struct_fields[[klass, name].join("\0")] = !NilKill.strong_trace_type?(type)
    end

    def add_static_field(field, tlet_types)
      klass = field["owner"].to_s
      name = (field["name"] || field["field"]).to_s.sub(/\A@/, "")
      path = File.expand_path(field["path"], ROOT)
      unless klass.empty? || name.empty?
        site_key = [path, field["line"].to_i, name].join("\0")
        @state_write_site_owners[site_key] = [klass, name].join("\0")
      end
      type = field["declared_type"]
      type = tlet_types[[path, field["line"].to_i]] if type.to_s.empty?
      return if klass.empty? || name.empty? || type.to_s.empty?

      @struct_fields[[klass, name].join("\0")] = !NilKill.strong_trace_type?(type)
    end

    # Exact source sites let the rewriter omit the recorder call entirely for
    # a state slot whose final enforceable contract is strong. Unknown sites
    # are deliberately absent and therefore remain sampled.
    def state_write_sites
      @state_write_site_owners.to_h do |site_key, owner_key|
        [site_key, @struct_fields.fetch(owner_key, true)]
      end
    end

    def method_name(method)
      method["name"].to_s.sub(/\Aself\./, "")
    end

    def method_kind(method)
      raw = method["kind"].to_s
      name = method["name"].to_s
      return "class" if name.start_with?("self.") || raw == "class" || raw == "class_method"
      return "function" if raw == "function" || method["owner"].to_s.empty?

      "instance"
    end

    def void_signature?(signature)
      signature.to_s.match?(/\bvoid\b/)
    end
  end
end
