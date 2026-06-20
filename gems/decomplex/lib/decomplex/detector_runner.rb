# frozen_string_literal: true

require "json"
require "ostruct"
require_relative "co_update"
require_relative "flay_similarity"
require_relative "local_flow"
require_relative "structural_topology"
require_relative "native/co_update"
require_relative "native/decision_pressure"
require_relative "native/predicate_aliases"
require_relative "native/flay_similarity"
require_relative "native/miner"
require_relative "native/semantic_aliases"
require_relative "native/local_flow"
require_relative "native/structural_topology"
require_relative "miner"
require_relative "decision_pressure"
require_relative "predicate_alias"
require_relative "semantic_alias"
require_relative "state_mesh"
require_relative "state_branch_density"
require_relative "temporal_ordering_pressure"
require_relative "redundant_nil_guard"
require_relative "inconsistent_rename_clone"
require_relative "derived_state"
require_relative "ordered_protocol_mine"
require_relative "weighted_inlined_cognitive_complexity"
require_relative "locality_drag"
require_relative "operational_discontinuity"
require_relative "oversized_predicate"
require_relative "path_condition"
require_relative "sequence_mine"
require_relative "function_lcom"
require_relative "false_simplicity"
require_relative "fat_union"

module Decomplex
  # Runs one detector in isolation and emits deterministic machine output.
  #
  # This is intentionally narrower than Report: it gives parser/runtime
  # migration work an apples-to-apples target that excludes report wording,
  # timing, SARIF metadata, and other nondeterministic details.
  module DetectorRunner
    DETECTORS = {
      "co-update" => :co_update,
      "decision-pressure" => :decision_pressure,
      "predicate-alias" => :predicate_alias,
      "predicate-aliases" => :predicate_alias,
      "miner" => :miner,
      "decision-miner" => :miner,
      "missing-abstractions" => :miner,
      "neglected-conditions" => :miner,
      "semantic-alias" => :semantic_alias,
      "semantic-aliases" => :semantic_alias,
      "semantic-predicate-aliases" => :semantic_alias,
      "reification-misses" => :semantic_alias,
      "flay-similarity" => :flay_similarity,
      "structural-similarity" => :flay_similarity,
      "temporal-ordering-pressure" => :temporal_ordering_pressure,
      "state-branch-density" => :state_branch_density,
      "redundant-nil-guard" => :redundant_nil_guard,
      "state-mesh" => :state_mesh,
      "state-heatmap" => :state_mesh,
      "inconsistent-rename-clone" => :inconsistent_rename_clone,
      "derived-state" => :derived_state,
      "implicit-control-flow" => :implicit_control_flow,
      "weighted-inlined-complexity" => :weighted_inlined_complexity,
      "locality-drag" => :locality_drag,
      "operational-discontinuity" => :operational_discontinuity,
      "oversized-predicate" => :oversized_predicate,
      "path-condition" => :path_condition,
      "broken-protocol" => :sequence_mine,
      "sequence-mine" => :sequence_mine,
      "function-lcom" => :function_lcom,
      "false-simplicity" => :false_simplicity,
      "fat-union" => :fat_union,
      "local-flow" => :local_flow,
      "structural-topology" => :structural_topology
    }.freeze
    ENGINES = %w[ruby rust].freeze

    module_function

    def run(detector, files, engine: "ruby", mass: FlaySimilarity::DEFAULT_MASS, fuzzy: FlaySimilarity::DEFAULT_FUZZY, jobs: nil)
      canonical = canonical_detector(detector)
      validate_engine!(engine)

      case canonical
      when :co_update
        co_update(files, engine: engine, jobs: jobs)
      when :decision_pressure
        decision_pressure(files, engine: engine, jobs: jobs)
      when :predicate_alias
        predicate_alias(files, engine: engine, jobs: jobs)
      when :miner
        miner(files, engine: engine, jobs: jobs)
      when :semantic_alias
        semantic_alias(files, engine: engine, jobs: jobs)
      when :flay_similarity
        flay_similarity(files, engine: engine, mass: mass, fuzzy: fuzzy, jobs: jobs)
      when :temporal_ordering_pressure
        temporal_ordering_pressure(files, engine: engine, jobs: jobs)
      when :state_branch_density
        state_branch_density(files, engine: engine, jobs: jobs)
      when :redundant_nil_guard
        redundant_nil_guard(files, engine: engine, jobs: jobs)
      when :state_mesh
        state_mesh(files, engine: engine, jobs: jobs)
      when :inconsistent_rename_clone
        inconsistent_rename_clone(files, engine: engine, jobs: jobs)
      when :derived_state
        derived_state(files, engine: engine, jobs: jobs)
      when :implicit_control_flow
        implicit_control_flow(files, engine: engine, jobs: jobs)
      when :weighted_inlined_complexity
        weighted_inlined_complexity(files, engine: engine, jobs: jobs)
      when :locality_drag
        locality_drag(files, engine: engine, jobs: jobs)
      when :operational_discontinuity
        operational_discontinuity(files, engine: engine, jobs: jobs)
      when :oversized_predicate
        oversized_predicate(files, engine: engine, jobs: jobs)
      when :path_condition
        path_condition(files, engine: engine, jobs: jobs)
      when :sequence_mine
        sequence_mine(files, engine: engine, jobs: jobs)
      when :function_lcom
        function_lcom(files, engine: engine, jobs: jobs)
      when :false_simplicity
        false_simplicity(files, engine: engine, jobs: jobs)
      when :fat_union
        fat_union(files, engine: engine, jobs: jobs)
      when :local_flow
        local_flow(files, engine: engine, jobs: jobs)
      when :structural_topology
        structural_topology(files, engine: engine, jobs: jobs)
      else
        raise ArgumentError, "unsupported decomplex detector: #{detector}"
      end
    end

    def canonical_json(detector, files, engine: "ruby", **options)
      JSON.generate(canonicalize(run(detector, files, engine: engine, **options))) << "\n"
    end

    def run_fact_fixture(path, engine: "ruby")
      fixture = JSON.parse(File.read(path.to_s))
      detector = fixture.fetch("detector")

      case engine.to_s
      when "ruby"
        documents = fact_documents(fixture.fetch("input").fetch("documents"))
        options = symbolize_options(fixture.fetch("options", {}))
        with_fact_documents(documents) do
          run(detector, documents.map(&:file), engine: "ruby", **options)
        end
      when "rust"
        JSON.parse(Native::Command.run("detector-facts", "--input", path.to_s))
      else
        raise ArgumentError, "unsupported decomplex detector engine: #{engine}"
      end
    end

    def canonical_json_from_fact_fixture(path, engine: "ruby")
      JSON.generate(canonicalize(run_fact_fixture(path, engine: engine))) << "\n"
    end

    def compare(detector, files, **options)
      ruby_json = canonical_json(detector, files, engine: "ruby", **options)
      rust_json = canonical_json(detector, files, engine: "rust", **options)
      [ruby_json == rust_json, ruby_json, rust_json]
    end

    def compare_fact_fixture(path)
      ruby_json = canonical_json_from_fact_fixture(path, engine: "ruby")
      rust_json = canonical_json_from_fact_fixture(path, engine: "rust")
      [ruby_json == rust_json, ruby_json, rust_json]
    end

    def detector_names
      DETECTORS.keys
    end

    private_class_method def self.canonical_detector(detector)
      DETECTORS.fetch(detector.to_s) do
        raise ArgumentError, "unsupported decomplex detector: #{detector}"
      end
    end

    private_class_method def self.validate_engine!(engine)
      return if ENGINES.include?(engine.to_s)

      raise ArgumentError, "unsupported decomplex detector engine: #{engine}"
    end

    private_class_method def self.symbolize_options(options)
      options.each_with_object({}) { |(key, value), out| out[key.to_sym] = value }
    end

    private_class_method def self.fact_documents(rows)
      Array(rows).map { |row| FactDocument.new(row) }
    end

    private_class_method def self.with_fact_documents(documents)
      by_file = documents.to_h { |document| [document.file.to_s, document] }
      original_parse = Syntax.method(:parse)
      Syntax.define_singleton_method(:parse) do |file, **kwargs|
        by_file.fetch(file.to_s) { original_parse.call(file, **kwargs) }
      end
      yield
    ensure
      Syntax.define_singleton_method(:parse, original_parse)
    end

    class FactDocument
      attr_reader :file, :language, :source, :lines

      FACT_ARRAYS = %w[
        branch_arms branch_decisions call_sites comparison_sites decision_sites
        dispatch_sites function_defs local_methods owner_defs path_condition_sites
        predicate_aliases predicate_defs semantic_effect_sites state_declarations
        state_param_origins state_reads state_writes
      ].freeze

      def initialize(row)
        @row = row
        @file = row.fetch("file")
        @language = row.fetch("language", "ruby").to_sym
        @source = row.fetch("source", "")
        @lines = row.fetch("lines", @source.lines)
        @root = objectify(row.fetch("root", empty_fact_node("program")))
        @normalized_root = objectify(row.fetch("normalized_root", {
                                                "type" => "ROOT",
                                                "children" => [],
                                                "first_lineno" => 1,
                                                "first_column" => 0,
                                                "last_lineno" => 1,
                                                "last_column" => 0,
                                                "text" => ""
                                              }))
        @immutable_struct_readers = object_hash(row.fetch("immutable_struct_readers", {}))
        @immutable_struct_reader_types = object_hash(row.fetch("immutable_struct_reader_types", {}))
        @type_aliases = object_hash(row.fetch("type_aliases", {}))
        @local_complexity_scores = row.fetch("local_complexity_scores", {}).to_h do |id, score|
          [id.to_s, symbolized_value(score)]
        end
        @local_contract_assignments = row.fetch("local_contract_assignments", {})

        FACT_ARRAYS.each do |name|
          instance_variable_set("@#{name}", fact_array(row.fetch(name, [])))
        end
      end

      FACT_ARRAYS.each do |name|
        define_method(name) { instance_variable_get("@#{name}") }
      end

      attr_reader :root, :normalized_root

      def clone_candidates
        Syntax.language_profile(language).clone_candidates(self)
      end

      def local_methods
        return @local_methods if @row.key?("local_methods")

        Syntax.language_profile(language).local_methods(self)
      end

      def path_condition_sites
        return @path_condition_sites if @row.key?("path_condition_sites")

        Syntax.language_profile(language).path_condition_sites(self)
      end

      def branch_decisions(immutable_readers:, immutable_reader_types:, type_aliases:)
        @branch_decisions
      end

      def immutable_struct_readers
        @immutable_struct_readers
      end

      def immutable_struct_reader_types
        @immutable_struct_reader_types
      end

      def type_aliases
        @type_aliases
      end

      def local_complexity_scores
        @local_complexity_scores
      end

      def local_contract_assignments(method)
        @local_contract_assignments.fetch(method.name.to_s, {})
      end

      def redundant_nil_guard_findings
        Syntax::NilGuardAnalyzer.new(self).scan
      end

      private

      def fact_array(value)
        Array(value).map { |item| objectify(item) }
      end

      def empty_fact_node(kind)
        {
          "kind" => kind,
          "text" => "",
          "span" => [1, 0, 1, 0],
          "named" => true,
          "field_name" => nil,
          "children" => []
        }
      end

      def object_hash(value)
        value.to_h { |key, child| [key.to_s, child] }
      end

      def objectify(value)
        case value
        when Hash
          if value.key?("kind") && value.key?("span") && value.key?("children")
            return FactNode.new(value, method(:objectify_field))
          end

          OpenStruct.new(value.to_h { |key, child| [key.to_s, objectify_field(key.to_s, child)] })
        when Array
          value.map { |child| objectify(child) }
        else
          value
        end
      end

      def objectify_field(key, value)
        if key == "control" && %w[conditional iterates].include?(value.to_s)
          return value.to_sym
        end
        if key == "visibility" && %w[public protected private].include?(value.to_s)
          return value.to_sym
        end

        objectify(value)
      end

      def symbolized_value(value)
        case value
        when Hash
          value.to_h { |key, child| [key.to_sym, symbolized_value(child)] }
        when Array
          value.map { |child| symbolized_value(child) }
        else
          value
        end
      end
    end

    class FactPoint
      attr_reader :row, :column

      def initialize(row, column)
        @row = row
        @column = column
      end
    end

    class FactNode
      attr_reader :kind, :text, :span, :field_name, :children, :start_point, :end_point
      attr_reader :start_byte, :end_byte
      attr_accessor :parent, :prev_sibling, :next_sibling

      def initialize(row, objectifier)
        @kind = row.fetch("kind")
        @text = row.fetch("text", "")
        @span = row.fetch("span")
        @field_name = row["field_name"]
        @named = row.fetch("named", true)
        @start_byte = row.fetch("start_byte", byte_offset(@span[0], @span[1]))
        @end_byte = row.fetch("end_byte", byte_offset(@span[2], @span[3]))
        @children = Array(row.fetch("children", [])).map { |child| objectifier.call("node", child) }
        @children.each { |child| child.parent = self if child.respond_to?(:parent=) }
        @children.each_cons(2) do |left, right|
          left.next_sibling = right if left.respond_to?(:next_sibling=)
          right.prev_sibling = left if right.respond_to?(:prev_sibling=)
        end
        @start_point = FactPoint.new(@span[0].to_i - 1, @span[1].to_i)
        @end_point = FactPoint.new(@span[2].to_i - 1, @span[3].to_i)
      end

      def named?
        @named
      end

      def child_count
        @children.length
      end

      def named_children
        @children.select { |child| child.respond_to?(:named?) && child.named? }
      end

      def named_child_count
        named_children.length
      end

      def child_by_field_name(name)
        @children.find { |child| child.respond_to?(:field_name) && child.field_name.to_s == name.to_s }
      end

      private

      def byte_offset(line, column)
        ((line.to_i - 1) * 1_000_000) + column.to_i
      end
    end

    private_class_method def self.co_update(files, engine:, jobs:)
      return Native::CoUpdate.scan(files, jobs: jobs) if engine.to_s == "rust"

      report = CoUpdate.scan(files)

      {
        "co_written_pairs" => report.co_written_pairs,
        "neglected_updates" => report.neglected_updates
      }
    end

    private_class_method def self.decision_pressure(files, engine:, jobs:)
      return Native::DecisionPressure.scan(files, jobs: jobs) if engine.to_s == "rust"

      DecisionPressure.scan(files).ranked
    end

    private_class_method def self.predicate_alias(files, engine:, jobs:)
      return Native::PredicateAliases.scan(files, jobs: jobs) if engine.to_s == "rust"

      report = PredicateAlias.scan(files)

      { "alias_clusters" => report.alias_clusters }
    end

    private_class_method def self.miner(files, engine:, jobs:)
      return Native::Miner.scan(files, jobs: jobs) if engine.to_s == "rust"

      report = Miner.scan(files)

      {
        "missing_abstractions" => report.missing_abstractions,
        "neglected_conditions" => report.neglected_conditions
      }
    end

    private_class_method def self.semantic_alias(files, engine:, jobs:)
      return Native::SemanticAliases.scan(files, jobs: jobs) if engine.to_s == "rust"

      report = SemanticAlias.scan(files)

      {
        "alias_clusters" => report.alias_clusters,
        "reification_misses" => report.reification_misses
      }
    end

    private_class_method def self.flay_similarity(files, engine:, mass:, fuzzy:, jobs:)
      findings =
        if engine.to_s == "rust"
          Native::FlaySimilarity.scan(files, mass: mass, fuzzy: fuzzy, jobs: jobs)
        else
          FlaySimilarity.scan(files, mass: mass, fuzzy: fuzzy)
        end

      { "findings" => findings }
    end

    private_class_method def self.temporal_ordering_pressure(files, engine:, jobs:)
      if engine.to_s == "rust"
        require_relative "native/temporal_ordering_pressure"
        return Native::TemporalOrderingPressure.scan(files, jobs: jobs)
      end

      TemporalOrderingPressure.scan(files)
    end

    private_class_method def self.state_branch_density(files, engine:, jobs:)
      if engine.to_s == "rust"
        require_relative "native/state_branch_density"
        return Native::StateBranchDensity.scan(files, jobs: jobs)
      end

      StateBranchDensity.scan(files).findings
    end

    private_class_method def self.redundant_nil_guard(files, engine:, jobs:)
      if engine.to_s == "rust"
        require_relative "native/redundant_nil_guard"
        return Native::RedundantNilGuard.scan(files, jobs: jobs)
      end

      RedundantNilGuard.scan(files)
    end

    private_class_method def self.state_mesh(files, engine:, jobs:)
      if engine.to_s == "rust"
        require_relative "native/state_mesh"
        return Native::StateMesh.scan(files, jobs: jobs)
      end

      StateMesh.scan(files).tap(&:run).to_json_graph
    end

    private_class_method def self.inconsistent_rename_clone(files, engine:, jobs:)
      if engine.to_s == "rust"
        require_relative "native/inconsistent_rename_clone"
        return Native::InconsistentRenameClone.scan(files, jobs: jobs)
      end

      InconsistentRenameClone.scan(files)
    end

    private_class_method def self.derived_state(files, engine:, jobs:)
      if engine.to_s == "rust"
        require_relative "native/derived_state"
        return Native::DerivedState.scan(files, jobs: jobs)
      end

      DerivedState.scan(files)
    end

    private_class_method def self.implicit_control_flow(files, engine:, jobs:)
      if engine.to_s == "rust"
        require_relative "native/implicit_control_flow"
        return Native::ImplicitControlFlow.scan(files, jobs: jobs)
      end

      report = ImplicitControlFlow.scan(files)
      {
        "ordered_protocols" => report.ordered_protocols,
        "order_drift" => report.drift
      }
    end

    private_class_method def self.weighted_inlined_complexity(files, engine:, jobs:)
      if engine.to_s == "rust"
        require_relative "native/weighted_inlined_complexity"
        return Native::WeightedInlinedComplexity.scan(files, jobs: jobs)
      end

      WeightedInlinedCognitiveComplexity.scan(files)
    end

    private_class_method def self.locality_drag(files, engine:, jobs:)
      if engine.to_s == "rust"
        require_relative "native/locality_drag"
        return Native::LocalityDrag.scan(files, jobs: jobs)
      end

      LocalityDrag.scan(files)
    end

    private_class_method def self.operational_discontinuity(files, engine:, jobs:)
      if engine.to_s == "rust"
        require_relative "native/operational_discontinuity"
        return Native::OperationalDiscontinuity.scan(files, jobs: jobs)
      end

      OperationalDiscontinuity.scan(files)
    end

    private_class_method def self.oversized_predicate(files, engine:, jobs:)
      if engine.to_s == "rust"
        require_relative "native/oversized_predicate"
        return Native::OversizedPredicate.scan(files, jobs: jobs)
      end

      { "findings" => OversizedPredicate.scan(files).findings }
    end

    private_class_method def self.path_condition(files, engine:, jobs:)
      if engine.to_s == "rust"
        require_relative "native/path_condition"
        return Native::PathCondition.scan(files, jobs: jobs)
      end

      report = PathCondition.scan(files)
      { "neglected" => report.neglected }
    end

    private_class_method def self.sequence_mine(files, engine:, jobs:)
      if engine.to_s == "rust"
        require_relative "native/sequence_mine"
        return Native::SequenceMine.scan(files, jobs: jobs)
      end

      report = SequenceMine.scan(files)
      { "broken" => report.broken_protocol }
    end

    private_class_method def self.function_lcom(files, engine:, jobs:)
      if engine.to_s == "rust"
        require_relative "native/function_lcom"
        return Native::FunctionLcom.scan(files, jobs: jobs)
      end

      FunctionLCOM.scan(files)
    end

    private_class_method def self.false_simplicity(files, engine:, jobs:)
      if engine.to_s == "rust"
        require_relative "native/false_simplicity"
        return Native::FalseSimplicity.scan(files, jobs: jobs)
      end

      FalseSimplicity.scan(files).findings
    end

    private_class_method def self.fat_union(files, engine:, jobs:)
      if engine.to_s == "rust"
        require_relative "native/fat_union"
        return Native::FatUnion.scan(files, jobs: jobs)
      end

      { "fat_unions" => FatUnion.scan(files).fat_unions }
    end

    private_class_method def self.local_flow(files, engine:, jobs:)
      return Native::LocalFlow.scan(files, jobs: jobs) if engine.to_s == "rust"

      LocalFlow.scan(files).map { |summary| local_flow_summary(summary) }
    end

    private_class_method def self.structural_topology(files, engine:, jobs:)
      return Native::StructuralTopology.scan(files, jobs: jobs) if engine.to_s == "rust"

      graph = StructuralTopology.scan(files)
      {
        "methods" => graph.methods.map { |method| structural_method(method) },
        "edges" => graph.edges.map { |edge| structural_edge(edge) }
      }
    end

    private_class_method def self.local_flow_summary(summary)
      {
        "id" => summary.id,
        "owner" => summary.owner,
        "name" => summary.name,
        "file" => summary.file,
        "line" => summary.line,
        "span" => summary.span,
        "statements" => summary.statements.map { |statement| local_flow_statement(statement) },
        "boundaries" => summary.boundaries.map { |boundary| local_flow_boundary(boundary) }
      }
    end

    private_class_method def self.local_flow_statement(statement)
      {
        "index" => statement.index,
        "line" => statement.line,
        "end_line" => statement.end_line,
        "span" => statement.span,
        "source" => statement.source,
        "reads" => statement.reads.to_a.sort,
        "writes" => statement.writes.to_a.sort,
        "dependencies" => statement.dependencies.map { |edge| Array(edge).map(&:to_s) }.sort,
        "co_uses" => statement.co_uses.map { |edge| Array(edge).map(&:to_s).sort }.sort
      }
    end

    private_class_method def self.local_flow_boundary(boundary)
      {
        "before_index" => boundary.before_index,
        "after_index" => boundary.after_index,
        "line" => boundary.line,
        "kind" => boundary.kind.to_s,
        "text" => boundary.text
      }
    end

    private_class_method def self.structural_method(method)
      {
        "id" => method.id,
        "owner" => method.owner,
        "name" => method.name,
        "file" => method.file,
        "line" => method.line,
        "span" => method.span,
        "visibility" => method.visibility.to_s
      }
    end

    private_class_method def self.structural_edge(edge)
      {
        "caller" => edge.caller,
        "callee" => edge.callee,
        "caller_name" => edge.caller_name,
        "callee_name" => edge.callee_name,
        "file" => edge.file,
        "line" => edge.line,
        "span" => edge.span,
        "type" => edge.type.to_s,
        "kind" => edge.kind.to_s,
        "confidence" => edge.confidence.to_s
      }
    end

    private_class_method def self.canonicalize(value)
      case value
      when Hash
        value.keys.map(&:to_s).sort.each_with_object({}) do |key, out|
          original = value.key?(key) ? key : value.keys.find { |candidate| candidate.to_s == key }
          out[key] = canonicalize(value.fetch(original))
        end
      when Array
        value.map { |item| canonicalize(item) }
      when Symbol
        value.to_s
      else
        value
      end
    end
  end
end
