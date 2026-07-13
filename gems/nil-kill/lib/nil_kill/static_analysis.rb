# typed: false
# frozen_string_literal: true

module NilKill
  class StaticAnalysis
    FACT_LISTS = %w[
      tlet_sites dead_nil_checks deterministic_guards struct_declarations struct_field_static
      tuple_arrays hash_shapes collection_index_lookups hash_record_blockers hash_record_member_calls
      type_definitions type_normalizers dispatcher_inferences return_origins param_origins rbi_field_types noreturn_methods
      flow_local_types
    ].freeze

    attr_reader :store, :evidence

    def self.index_store(store:, targets: NilKill.target_dirs, root: ROOT, language: nil, vcs: nil)
      evidence = StaticEvidence.build(targets, root: root, language: language, vcs: vcs)
      Inference::Providers.index(store: store, static: evidence, root: root)
      evidence
    end

    def self.source_lines(path)
      @source_lines ||= {}
      @source_lines[path] ||= File.readlines(path)
    end

    def self.clear_caches!
      @source_lines = {}
    end

    def initialize(targets = NilKill.target_dirs, root: ROOT, language: nil, vcs: nil)
      @root = root
      @store = Store.new
      @evidence = self.class.index_store(store: @store, targets: Array(targets), root: root, language: language, vcs: vcs)
    end

    def methods
      Array(store.facts["existing_sigs"]) + Array(store.facts["unsigned_methods"])
    end

    def summary
      Hash(store.facts["static_evidence_summary"])
    end

    def ivar_protocols
      Hash(store.facts["ivar_protocols"])
    end

    def ivar_param_origins
      Hash(store.facts["ivar_param_origins"])
    end

    FACT_LISTS.each do |name|
      define_method(name) { Array(store.facts[name]) }
    end
  end
end
