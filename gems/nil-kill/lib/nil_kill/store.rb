# typed: false
# frozen_string_literal: true

module NilKill
  class Store
    attr_reader :methods, :tlets, :facts, :diagnostics, :actions

    def initialize
      @methods = {}
      @tlets = {}
      @facts = { "files" => {}, "unsigned_methods" => [], "existing_sigs" => [], "tlet_sites" => [], "dead_nil_checks" => [],
                 "deterministic_guards" => [],
                 "struct_declarations" => [], "struct_field_static" => [], "tuple_arrays" => [], "hash_shapes" => [],
                 "collection_index_lookups" => [], "hash_record_blockers" => [],
                 "hash_record_member_calls" => [],
                 "collection_runtime" => [], "ivar_runtime" => [], "collect_coverage" => {},
                 "type_normalizers" => [], "dispatcher_inferences" => [], "return_origins" => [], "param_origins" => [],
                 "rbi_field_types" => [], "noreturn_methods" => [],
                 "runtime_call_edges" => [], "fallibility_pressure" => [], "hidden_enum_pressure" => [], "flow_graph" => nil,
                 "static_evidence_summary" => {} }
      @diagnostics = { "sorbet_errors" => [], "nil_origins" => [], "sorbet_feedback" => [] }
      @actions = []
    end

    def method_record(key)
      @methods[key.join("\0")] ||= {
        "key" => key, "calls" => 0, "ok_calls" => 0, "raised_calls" => 0,
        "params_by_name" => {}, "params_ok" => {}, "params_raised" => {}, "param_elem" => {}, "param_kv" => {},
        "param_elem_shapes" => {}, "param_kv_shapes" => {},
        "param_sites" => {}, "param_sites_ok" => {}, "param_sites_raised" => {},
        "param_traces" => {}, "param_traces_ok" => {}, "param_traces_raised" => {},
        "returns" => [], "return_elem" => [], "return_kv" => [[], []],
        "return_elem_shapes" => [], "return_kv_shapes" => [[], []], "raised" => [],
        "source" => nil, "has_sig" => false,
      }
    end

    def to_h
      { "version" => 1, "generated_at" => Time.now.utc.iso8601, "target_dirs" => NilKill.target_dirs.map { |d| NilKill.rel(d) },
        "target_exclude_dirs" => NilKill.target_exclude_dirs.map { |d| NilKill.rel(d) },
        "methods" => @methods.values, "tlets" => @tlets.values, "facts" => @facts,
        "diagnostics" => @diagnostics, "actions" => @actions }
    end

    def write(evidence = to_h)
      FileUtils.mkdir_p(TMP_DIR)
      File.write(EVIDENCE_PATH, JSON.pretty_generate(evidence))
    end

    def self.read
      abort "missing #{NilKill.rel(EVIDENCE_PATH)}; run `bundle exec tools/nil-kill infer` first" unless File.exist?(EVIDENCE_PATH)
      FactMine::Syntax::TypeExpr.wrap_types!(JSON.parse(File.read(EVIDENCE_PATH)))
    end
  end
end
