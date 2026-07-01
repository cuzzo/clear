# typed: false
# frozen_string_literal: true

module NilKill
  module Runtime
    class Normalizer
      def initialize(root: NilKill::ROOT)
        @root = root
      end

      def normalize(static:, trace_paths:, analyze: true)
        @static_index = StaticIndex.new(static, root: @root)
        runtime = empty_runtime
        diagnostics = []
        TraceLoader.new(trace_paths).each_event do |event, diagnostic|
          if diagnostic
            diagnostics << diagnostic
          else
            normalize_event(event, runtime, diagnostics)
          end
        end
        diagnostics.concat(runtime.delete("diagnostics"))
        diagnostics.uniq! { |diagnostic| [diagnostic["code"], diagnostic["path"], diagnostic["line"], JSON.generate(diagnostic["locator"])] }
        bundle = Schema::EvidenceBundle.build(root: @root, static: @static_index.static, runtime: runtime,
          diagnostics: diagnostics, metadata: { "trace_files" => TraceLoader.new(trace_paths).event_files.map { |path| rel(path) } })
        if analyze
          bundle["actions"] = Analyzers::RuntimeEvidenceAnalyzer.new(bundle).analyze
        end
        bundle
      end

      def load_legacy_ruby!(store, runtime_dir: NilKill::RUNTIME_DIR)
        load_legacy_methods!(store, runtime_dir)
        load_legacy_edges!(store, runtime_dir)
        load_legacy_tlets!(store, runtime_dir)
        load_legacy_fact_file!(store, runtime_dir, "structs-*.jsonl", "struct_field_runtime")
        load_legacy_fact_file!(store, runtime_dir, "ivars-*.jsonl", "ivar_runtime", target_filter: false)
        load_legacy_coverage!(store, runtime_dir)
        load_legacy_fact_file!(store, runtime_dir, "tuples-*.jsonl", "tuple_runtime")
        load_legacy_fact_file!(store, runtime_dir, "collections-*.jsonl", "collection_runtime")
      end

      private

      def empty_runtime
        {
          "runs" => [],
          "method_hits" => {},
          "param_observations" => {},
          "return_observations" => {},
          "field_observations" => {},
          "collection_observations" => {},
          "hash_shape_observations" => {},
          "call_edges" => [],
          "coverage" => {},
          "exceptions" => {},
          "diagnostics" => [],
        }
      end

      def normalize_event(event, runtime, diagnostics)
        schema = event["schema_version"].to_i
        if schema != 1
          diagnostics << event_diagnostic(event, "unsupported_trace_schema", "unsupported raw trace schema_version #{event["schema_version"].inspect}")
          return
        end

        case event["event"].to_s
        when "process_start"
          runtime["runs"] << run_record(event).merge("started_at_ns" => event["timestamp_ns"])
        when "process_end"
          runtime["runs"] << run_record(event).merge("ended_at_ns" => event["timestamp_ns"])
        when "method_call"
          method_id, method, resolved = resolve_method(event, diagnostics)
          hit = method_hit(runtime, method_id, method, event)
          hit["calls"] += sample_count(event)
          hit["resolved"] &&= resolved
        when "method_return", "return_observed"
          method_id, method, resolved = resolve_method(event, diagnostics)
          hit = method_hit(runtime, method_id, method, event)
          hit["ok_calls"] += sample_count(event)
          hit["resolved"] &&= resolved
          add_return_observation(runtime, method_id, event)
        when "method_raise"
          method_id, method, resolved = resolve_method(event, diagnostics)
          hit = method_hit(runtime, method_id, method, event)
          hit["raised_calls"] += sample_count(event)
          hit["resolved"] &&= resolved
          add_exception_observation(runtime, method_id, event)
        when "param_observed"
          method_id, method, resolved = resolve_method(event, diagnostics)
          method_hit(runtime, method_id, method, event)["resolved"] &&= resolved
          add_param_observation(runtime, method_id, event)
        when "field_observed"
          add_field_observation(runtime, event)
        when "collection_observed"
          add_collection_observation(runtime, event)
        when "hash_shape_observed"
          add_hash_shape_observation(runtime, event)
        when "call_edge"
          add_call_edge(runtime, event, diagnostics)
        when "coverage", "branch_observed"
          add_coverage(runtime, event)
        else
          diagnostics << event_diagnostic(event, "unknown_trace_event", "unknown raw trace event #{event["event"].inspect}")
        end
      end

      def resolve_method(event, diagnostics)
        method_id, method, resolved = @static_index.resolve_method(event)
        unless resolved
          diagnostics << event_diagnostic(event, "unresolved_method_locator", "could not resolve trace event to a static method")
        end
        [method_id, method, resolved]
      end

      def method_hit(runtime, method_id, method, event)
        hit = (runtime["method_hits"][method_id] ||= {
          "method_id" => method_id,
          "language" => (event["language"] || method["language"]).to_s,
          "path" => method["path"].to_s.empty? ? rel(event["path"]) : method["path"],
          "line" => method["line"].to_i,
          "owner" => method["owner"].to_s,
          "name" => method["name"].to_s,
          "kind" => method["kind"].to_s,
          "calls" => 0,
          "ok_calls" => 0,
          "raised_calls" => 0,
          "run_ids" => [],
          "resolved" => true,
        })
        hit["run_ids"] |= [event["run_id"].to_s] unless event["run_id"].to_s.empty?
        hit
      end

      def add_param_observation(runtime, method_id, event)
        payload = event["payload"] || {}
        param = payload["param"].to_s
        return if param.empty?

        bucket = (((runtime["param_observations"][method_id] ||= {})[param] ||= observation_bucket(event)))
        add_type(bucket, payload["type"] || payload["runtime_type"] || payload["class"], event)
      end

      def add_return_observation(runtime, method_id, event)
        payload = event["payload"] || {}
        type = payload["type"] || payload["runtime_type"] || payload["return"] || payload["class"]
        return unless type

        bucket = (runtime["return_observations"][method_id] ||= observation_bucket(event))
        add_type(bucket, type, event)
      end

      def add_field_observation(runtime, event)
        payload = event["payload"] || {}
        language = event["language"].to_s
        path = rel(event["path"])
        owner = (payload["owner"] || payload["class"] || payload["owner_id"]).to_s
        field = (payload["field"] || payload["name"]).to_s
        field_id = (payload["field_id"] || "#{language}\0#{path}\0#{owner}\0field\0#{field}").to_s
        bucket = (runtime["field_observations"][field_id] ||= observation_bucket(event).merge(
          "field_id" => field_id,
          "language" => language,
          "path" => path,
          "owner" => owner,
          "field" => field
        ))
        add_type(bucket, payload["type"] || payload["runtime_type"] || payload["class"], event)
      end

      def add_collection_observation(runtime, event)
        payload = event["payload"] || {}
        key = [
          event["language"], rel(event["path"]), payload["owner"], payload["name"], payload["kind"], event["line"]
        ].map(&:to_s).join("\0")
        bucket = (runtime["collection_observations"][key] ||= observation_bucket(event).merge(
          "id" => key,
          "language" => event["language"].to_s,
          "path" => rel(event["path"]),
          "line" => event["line"].to_i,
          "owner" => payload["owner"].to_s,
          "name" => payload["name"].to_s,
          "kind" => payload["kind"].to_s
        ))
        Array(payload["element_types"] || payload["types"] || payload["elem_classes"]).each { |type| add_type(bucket, type, event) }
      end

      def add_hash_shape_observation(runtime, event)
        payload = event["payload"] || {}
        key = [event["language"], rel(event["path"]), event["line"], payload["owner"], payload["name"]].map(&:to_s).join("\0")
        bucket = (runtime["hash_shape_observations"][key] ||= observation_bucket(event).merge(
          "id" => key,
          "language" => event["language"].to_s,
          "path" => rel(event["path"]),
          "line" => event["line"].to_i,
          "owner" => payload["owner"].to_s,
          "name" => payload["name"].to_s,
          "shapes" => []
        ))
        bucket["shapes"] << payload["shape"] if payload["shape"]
        bucket["shapes"].uniq! { |shape| JSON.generate(shape) }
      end

      def add_call_edge(runtime, event, diagnostics)
        payload = event["payload"] || {}
        caller_event = endpoint_event(event, payload["caller"] || payload[:caller])
        callee_event = endpoint_event(event, payload["callee"] || payload[:callee])
        caller_id, caller, caller_resolved = resolve_method(caller_event, diagnostics)
        callee_id, callee, callee_resolved = resolve_method(callee_event, diagnostics)
        runtime["call_edges"] << {
          "caller_id" => caller_id,
          "callee_id" => callee_id,
          "caller" => caller,
          "callee" => callee,
          "calls" => sample_count(event),
          "resolved" => caller_resolved && callee_resolved,
        }
      end

      def endpoint_event(event, endpoint)
        endpoint = endpoint.is_a?(Hash) ? endpoint : {}
        event.merge(
          "language" => endpoint["language"] || endpoint[:language] || event["language"],
          "path" => endpoint["path"] || endpoint[:path] || event["path"],
          "line" => endpoint["line"] || endpoint[:line] || event["line"],
          "method_id" => endpoint["method_id"] || endpoint[:method_id],
          "locator" => endpoint
        )
      end

      def add_coverage(runtime, event)
        path = rel(event["path"])
        payload = event["payload"] || {}
        lines = Array(payload["lines"] || event["lines"] || event["line"]).map(&:to_i).reject(&:zero?)
        runtime["coverage"][path] ||= []
        runtime["coverage"][path] = (runtime["coverage"][path] + lines).uniq.sort
      end

      def add_exception_observation(runtime, method_id, event)
        payload = event["payload"] || {}
        bucket = (runtime["exceptions"][method_id] ||= observation_bucket(event).merge("exceptions" => []))
        bucket["exceptions"] |= [payload["class"] || payload["type"] || "unknown"]
      end

      def observation_bucket(event)
        { "types" => [], "sample_count" => 0, "run_ids" => [event["run_id"].to_s].reject(&:empty?) }
      end

      def add_type(bucket, type, event)
        return unless type

        normalized = Schema::RuntimeType.normalize(type, language: event["language"].to_s)
        bucket["types"] << normalized
        bucket["types"].uniq! { |entry| JSON.generate(entry) }
        bucket["sample_count"] = bucket["sample_count"].to_i + sample_count(event)
        bucket["run_ids"] |= [event["run_id"].to_s] unless event["run_id"].to_s.empty?
      end

      def run_record(event)
        {
          "run_id" => event["run_id"].to_s,
          "language" => event["language"].to_s,
          "pid" => event["pid"],
          "thread_id" => event["thread_id"].to_s,
        }
      end

      def sample_count(event)
        payload = event["payload"] || {}
        (payload["sample_count"] || event["sample_count"] || 1).to_i
      end

      def event_diagnostic(event, code, message)
        {
          "severity" => "warning",
          "code" => code,
          "language" => event["language"],
          "path" => rel(event["path"]),
          "line" => event["line"].to_i,
          "locator" => event["locator"],
          "message" => message,
        }
      end

      def load_legacy_methods!(store, runtime_dir)
        files = Dir.glob(File.join(runtime_dir, "methods-*.jsonl"))
        files.each do |file|
          File.foreach(file) do |line|
            obs = JSON.parse(line) rescue next
            next unless NilKill.target_path?(obs["path"])
            key_str = "#{obs["class"]}\0#{obs["method"]}\0#{obs["kind"]}\0#{obs["path"]}\0#{obs["line"]}"
            rec = store.method_record_by_key_str(key_str) do
              [obs["class"].to_s, obs["method"].to_s, obs["kind"].to_s, obs["path"].to_s, obs["line"].to_i]
            end
            rec["calls"] += obs["calls"].to_i
            rec["ok_calls"] += obs["ok_calls"].to_i
            rec["raised_calls"] += obs["raised_calls"].to_i

            %w[returns return_elem raised].each do |k|
              rec[k] = Set.new(rec[k]) unless rec[k].is_a?(Set)
              rec[k].merge(Array(obs[k]))
            end

            merge_hash_sets(rec["params_by_name"], obs["params_by_name"])
            merge_hash_sets(rec["params_ok"], obs["params_ok"])
            merge_hash_sets(rec["params_raised"], obs["params_raised"])
            merge_hash_counts(rec["param_sites"], obs["param_sites"])
            merge_hash_counts(rec["param_sites_ok"], obs["param_sites_ok"])
            merge_hash_counts(rec["param_sites_raised"], obs["param_sites_raised"])
            merge_hash_counts(rec["param_traces"], obs["param_traces"])
            merge_hash_counts(rec["param_traces_ok"], obs["param_traces_ok"])
            merge_hash_counts(rec["param_traces_raised"], obs["param_traces_raised"])

            rec["param_elem"] ||= {}
            (obs["param_elem"] || {}).each do |name, vals|
              rec["param_elem"][name] = Set.new(rec["param_elem"][name]) unless rec["param_elem"][name].is_a?(Set)
              rec["param_elem"][name].merge(Array(vals))
            end

            merge_hash_kv(rec["param_kv"], obs["param_kv"])
            merge_hash_shapes(rec["param_elem_shapes"], obs["param_elem_shapes"])
            merge_hash_kv_shapes(rec["param_kv_shapes"], obs["param_kv_shapes"])
            merge_kv(rec["return_kv"], obs["return_kv"])
            merge_shapes_in_wrapper(rec, "return_elem_shapes", obs["return_elem_shapes"])
            merge_kv_shapes(rec["return_kv_shapes"], obs["return_kv_shapes"])
          end
        end

        # Post-process: convert all Sets/Hashes back to sorted arrays
        store.methods.each_value do |rec|
          %w[returns return_elem raised].each do |k|
            rec[k] = rec[k].to_a.sort if rec[k].is_a?(Set)
          end
          %w[params_by_name params_ok params_raised param_elem].each do |k|
            rec[k].each do |name, val|
              rec[k][name] = val.to_a.sort if val.is_a?(Set)
            end
          end
          rec["param_kv"].each do |name, kv|
            kv[0] = kv[0].to_a.sort if kv[0].is_a?(Set)
            kv[1] = kv[1].to_a.sort if kv[1].is_a?(Set)
          end
          if rec["return_kv"]
            rec["return_kv"][0] = rec["return_kv"][0].to_a.sort if rec["return_kv"][0].is_a?(Set)
            rec["return_kv"][1] = rec["return_kv"][1].to_a.sort if rec["return_kv"][1].is_a?(Set)
          end
          if rec["param_elem_shapes"]
            rec["param_elem_shapes"].each do |name, list|
              rec["param_elem_shapes"][name] = list.values.sort_by { |s| JSON.generate(s) } if list.is_a?(Hash)
            end
          end
          if rec["param_kv_shapes"]
            rec["param_kv_shapes"].each do |name, kv|
              kv[0] = kv[0].values.sort_by { |s| JSON.generate(s) } if kv[0].is_a?(Hash)
              kv[1] = kv[1].values.sort_by { |s| JSON.generate(s) } if kv[1].is_a?(Hash)
            end
          end
          if rec["return_elem_shapes"].is_a?(Hash)
            rec["return_elem_shapes"] = rec["return_elem_shapes"].values.sort_by { |s| JSON.generate(s) }
          end
          if rec["return_kv_shapes"]
            rec["return_kv_shapes"][0] = rec["return_kv_shapes"][0].values.sort_by { |s| JSON.generate(s) } if rec["return_kv_shapes"][0].is_a?(Hash)
            rec["return_kv_shapes"][1] = rec["return_kv_shapes"][1].values.sort_by { |s| JSON.generate(s) } if rec["return_kv_shapes"][1].is_a?(Hash)
          end
        end

        GC.start
      end

      def load_legacy_edges!(store, runtime_dir)
        runtime_edges = {}
        Dir.glob(File.join(runtime_dir, "method-edges-*.jsonl")).each do |file|
          File.foreach(file) do |line|
            obs = JSON.parse(line) rescue next
            c_info = obs["caller"]
            e_info = obs["callee"]
            next unless c_info && e_info
            next unless NilKill.target_path?(c_info["path"]) && NilKill.target_path?(e_info["path"])

            key_str = "#{c_info["path"]}\0#{c_info["line"]}\0#{c_info["class"]}\0#{c_info["method"]}\0#{c_info["kind"]}\0#{e_info["path"]}\0#{e_info["line"]}\0#{e_info["class"]}\0#{e_info["method"]}\0#{e_info["kind"]}"
            rec = runtime_edges[key_str]
            if rec.nil?
              caller = legacy_runtime_edge_endpoint(c_info)
              callee = legacy_runtime_edge_endpoint(e_info)
              next unless caller && callee
              rec = runtime_edges[key_str] = {
                "caller" => caller,
                "callee" => callee,
                "calls" => 0,
                "ok_calls" => 0,
                "raised_calls" => 0,
              }
            end
            rec["calls"] += obs["calls"].to_i
            rec["ok_calls"] += obs["ok_calls"].to_i
            rec["raised_calls"] += obs["raised_calls"].to_i
          end
        end
        store.facts["runtime_call_edges"] = runtime_edges.values.sort_by do |edge|
          caller = edge.fetch("caller")
          callee = edge.fetch("callee")
          [caller["path"], caller["line"].to_i, caller["class"], caller["kind"], caller["method"],
           callee["path"], callee["line"].to_i, callee["class"], callee["kind"], callee["method"]]
        end
      end

      def load_legacy_tlets!(store, runtime_dir)
        Dir.glob(File.join(runtime_dir, "tlets-*.jsonl")).each do |file|
          File.foreach(file) do |line|
            obs = JSON.parse(line) rescue next
            next unless NilKill.target_path?(obs["path"])
            key = "#{obs["path"]}:#{obs["line"]}"
            rec = (store.tlets[key] ||= { "path" => obs["path"], "line" => obs["line"], "calls" => 0, "classes" => [] })
            rec["calls"] += obs["calls"].to_i
            rec["classes"] = (rec["classes"] + Array(obs["classes"])).uniq.sort
          end
        end
      end

      def load_legacy_fact_file!(store, runtime_dir, pattern, fact_key, target_filter: true)
        Dir.glob(File.join(runtime_dir, pattern)).each do |file|
          File.foreach(file) do |line|
            obs = JSON.parse(line) rescue next
            next if target_filter && !NilKill.target_path?(obs["path"])
            store.facts[fact_key] ||= []
            store.facts[fact_key] << obs
          end
        end
      end

      def load_legacy_coverage!(store, runtime_dir)
        cov = Hash.new { |h, k| h[k] = [] }
        Dir.glob(File.join(runtime_dir, "coverage-*.jsonl")).each do |file|
          File.foreach(file) do |line|
            obs = JSON.parse(line) rescue next
            next unless NilKill.target_path?(obs["path"])
            cov[NilKill.rel(obs["path"])].concat(Array(obs["lines"]))
          end
        end
        store.facts["collect_coverage"] = cov.transform_values { |ls| ls.uniq.sort } unless cov.empty?
      end

      def legacy_runtime_edge_endpoint(endpoint)
        return nil unless endpoint.is_a?(Hash)
        path = endpoint["path"] || endpoint[:path]
        return nil if path.to_s.empty?

        {
          "class" => (endpoint["class"] || endpoint[:class]).to_s,
          "method" => (endpoint["method"] || endpoint[:method]).to_s,
          "kind" => (endpoint["kind"] || endpoint[:kind]).to_s,
          "path" => File.expand_path(path, ROOT),
          "line" => (endpoint["line"] || endpoint[:line]).to_i,
        }
      end

      def merge_hash_sets(target, source)
        (source || {}).each do |name, vals|
          target[name] = Set.new(target[name]) unless target[name].is_a?(Set)
          target[name].merge(Array(vals))
        end
      end

      def merge_hash_kv(target, source)
        (source || {}).each { |name, kv| merge_kv((target[name] ||= [[], []]), kv) }
      end

      def merge_hash_shapes(target, source)
        (source || {}).each do |name, shapes|
          target[name] ||= {}
          if target[name].is_a?(Array)
            hash = {}
            target[name].each do |s|
              parsed = NilKill.parse_shape(s)
              hash[JSON.generate(parsed)] = parsed
            end
            target[name] = hash
          end
          Array(shapes).each do |s|
            parsed = NilKill.parse_shape(s)
            target[name][JSON.generate(parsed)] = parsed
          end
        end
      end

      def merge_hash_kv_shapes(target, source)
        (source || {}).each do |name, kv|
          target[name] ||= [{}, {}]
          merge_kv_shapes(target[name], kv)
        end
      end

      def merge_hash_counts(target, source)
        (source || {}).each do |name, sites|
          bucket = (target[name] ||= {})
          (sites || {}).each { |site, count| bucket[site] = bucket.fetch(site, 0) + count.to_i }
        end
      end

      def merge_kv(target, source)
        return unless source
        target[0] = Set.new(target[0]) unless target[0].is_a?(Set)
        target[1] = Set.new(target[1]) unless target[1].is_a?(Set)
        target[0].merge(Array(source[0]))
        target[1].merge(Array(source[1]))
      end

      def merge_shapes_in_wrapper(target_wrapper, key, source)
        return unless source
        list = target_wrapper[key]
        if list.is_a?(Array)
          hash = {}
          list.each { |s| p = NilKill.parse_shape(s); hash[JSON.generate(p)] = p }
          list = target_wrapper[key] = hash
        end
        Array(source).each do |s|
          parsed = NilKill.parse_shape(s)
          list[JSON.generate(parsed)] = parsed
        end
      end

      def merge_kv_shapes(target, source)
        return unless source
        if target[0].is_a?(Array)
          h0 = {}
          target[0].each { |s| p = NilKill.parse_shape(s); h0[JSON.generate(p)] = p }
          target[0] = h0
        end
        if target[1].is_a?(Array)
          h1 = {}
          target[1].each { |s| p = NilKill.parse_shape(s); h1[JSON.generate(p)] = p }
          target[1] = h1
        end

        Array(source[0]).each do |s|
          parsed = NilKill.parse_shape(s)
          target[0][JSON.generate(parsed)] = parsed
        end
        Array(source[1]).each do |s|
          parsed = NilKill.parse_shape(s)
          target[1][JSON.generate(parsed)] = parsed
        end
      end

      def rel(path)
        return "" if path.to_s.empty?

        Pathname.new(File.expand_path(path, @root)).relative_path_from(Pathname.new(@root)).to_s
      rescue StandardError
        path.to_s
      end
    end
  end
end
