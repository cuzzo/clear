# frozen_string_literal: true

# Oracle-bearing admission layer for the language surfaces that historically
# lived in separate explicit matrices.  It deliberately owns the *contract*
# (legality, trace and diagnostic identity) while reusing a reviewed renderer
# until a surface has enough generated productions to replace that renderer.
require 'digest'
require_relative 'semantic_equivalence'

module SemanticAdvanced
  WORKSTREAMS = %i[capability depth concurrency effects generics diagnostics].freeze

  Gap = Struct.new(:id, :status, :summary, :witness, keyword_init: true)
  # Advanced generation has its own ledger because not every finding is a
  # language-runtime bug.  This one was a stale diagnostic oracle exposed by
  # the structured probe and is retained as the raw source witness.
  FIXED_GAPS = [
    Gap.new(
      id: :generic_map_wrong_key_diagnostic_code,
      status: :fixed,
      summary: 'The generated wrong-key Map case named TYPE_MISMATCH_ASSIGN while the registered compiler diagnostic is GENERIC_MAP_KEY_MISMATCH.',
      witness: <<~CLEAR
        STRUCT Index<M: Map> { entries: {M::Key}Int64 }
        IMPLEMENTATION Index<M> {
          METHOD bad(self) RETURNS ?Int64 -> RETURN self.entries[TRUE]; END
        }
      CLEAR
    ).freeze,
    Gap.new(
      id: :managed_copy_give_takes_plain_parameter,
      status: :fixed,
      summary: 'GIVE COPY of an @multiowned/@shared value now materializes a plain owned payload for a plain TAKES parameter while preserving cleanup of the source handle.',
      witness: <<~CLEAR
        STRUCT SemanticBox { v: Int64 }
        FN consume(TAKES input: SemanticBox) RETURNS Void ->
          ASSERT input.v == 1_i64;
          RETURN;
        END
        FN main() RETURNS Void ->
          value = SemanticBox{ v: 1_i64 } @multiowned;
          copied = COPY value;
          consume(GIVE copied);
          RETURN;
        END
      CLEAR
    ).freeze,
    Gap.new(
      id: :generic_identity_owned_return,
      status: :fixed,
      summary: 'Generic identity returns now materialize owned String, list, map, and tuple payloads with a runtime allocator and preserve value ABI at generic call boundaries.',
      witness: <<~CLEAR
        FN genericIdentity<T>(value: T) RETURNS T -> RETURN value; END
        FN main() RETURNS Void ->
          result: String = genericIdentity(COPY "x");
          ASSERT result.length() == 1_i64;
          RETURN;
        END
      CLEAR
    ).freeze,
    Gap.new(
      id: :allocation_fault_or_else_value,
      status: :fixed,
      summary: 'OR_ELSE value fallback on an allocation-fallible call now recognizes the hidden allocation FAULT and lowers through catch instead of optional orelse.',
      witness: <<~CLEAR
        FN grow(n: Int64) RETURNS Int64 ->
          MUTABLE xs: Int64[] = [];
          MUTABLE i = 0_i64;
          WHILE i < n DO &xs.append(i); i += 1_i64; END
          RETURN xs.length();
        END
        FN main() RETURNS Void ->
          size = grow(100000_i64) OR_ELSE 0_i64;
          ASSERT size == 0_i64;
          RETURN;
        END
      CLEAR
    ).freeze,
    Gap.new(
      id: :select_modifier_order_contract,
      status: :fixed,
      summary: 'SELECT now preserves and validates the exact ordered !/?/~ modifier sequence instead of collapsing it to an unordered effect mode.',
      witness: 'values |> SELECT:!~? project(_)'
    ).freeze,
    Gap.new(
      id: :select_outer_fallible_tense_type,
      status: :fixed,
      summary: 'The type parser now admits recursively ordered outer-fallible tense types such as !~T, !~!T, and !~?T.',
      witness: 'FN project(value: Int64) RETURNS !~?Int64 -> RETURN BG { value; }; END'
    ).freeze,
    Gap.new(
      id: :select_stream_cardinality_inference,
      status: :fixed,
      summary: 'SELECT type inference preserves [~], [~N], and [~INF] source cardinality and places selector wrappers on the correct side of the stream boundary.',
      witness: 'selected: [~2]?Int64 = input |> SELECT:? project(_)'
    ).freeze,
    Gap.new(
      id: :select_stream_effect_annotation,
      status: :fixed,
      summary: 'A list selector returning ~T now requires SELECT:~ and infers [~]T; omitting the marker produces a focused annotation error.',
      witness: 'selected: [~]Int64 = values |> SELECT:~ streamBar(_)'
    ).freeze,
    Gap.new(
      id: :obsolete_question_stream_syntax,
      status: :fixed,
      summary: 'The parser rejects ?[~]T and obsolete ~T[?], while retaining [~]?T for optional stream items.',
      witness: 'ok: [~]?Int64 = source; bad_outer: ?[~]Int64 = DEFAULT; bad_legacy: ~Int64[?] = DEFAULT;'
    ).freeze,
  ].freeze
  SELECT_LOWERING_FIXED_GAPS = [
    Gap.new(
      id: :select_preserves_tense,
      status: :fixed,
      summary: 'SELECT lowering now emits cardinality-preserving [~]/[~N]/[~INF] producers instead of materializing an ArrayList.',
      witness: <<~CLEAR
        FN main() RETURNS !Void ->
          source: [~]Int64 = BG STREAM { YIELD 1_i64; YIELD 2_i64; CLOSE; };
          selected: [~]Int64 = source |> SELECT _ * 2_i64;
          IF NEXT selected EXISTS AS first THEN ASSERT first == 2_i64; END
          RETURN;
        END
      CLEAR
    ).freeze,
    Gap.new(
      id: :select_outer_fallible_tense_lowering,
      status: :fixed,
      summary: 'SELECT:!~* now tracks the outer fallible stream payload lifecycle and emits conditional cleanup without an invalid ownership DROP.',
      witness: <<~CLEAR
        FN project(value: Int64) RETURNS !~?Int64 -> RETURN BG { value; }; END
        FN main(values: []Int64) RETURNS !Void ->
          selected: ![~]?Int64 = values |> SELECT:!~? project(_);
          RETURN;
        END
      CLEAR
    ).freeze,
    Gap.new(
      id: :select_fallible_future_payload_lowering,
      status: :fixed,
      summary: 'Selectors returning ~!T or ~!?T preserve the nested error payload through FSM storage and Promise spawn/error ABI lowering.',
      witness: <<~CLEAR
        FN project(value: Int64) RETURNS ~!Int64 ->
          RETURN BG { value.toString().toInt(); };
        END
      CLEAR
    ).freeze,
  ].freeze
  EXPECTED_GAPS = [].freeze
  GAPS = (FIXED_GAPS + SELECT_LOWERING_FIXED_GAPS + EXPECTED_GAPS).freeze

  Trace = Struct.new(:value, :state, :events, :outcome, keyword_init: true) do
    def validate!
      raise 'advanced trace needs an outcome' unless %i[return reject].include?(outcome)
      raise 'advanced trace events must be ordered' unless events.is_a?(Array) && events == events.map(&:to_sym)
      raise 'rejected trace cannot carry a runtime value' if outcome == :reject && !value.nil?
      self
    end

    def to_h = { value: value, state: state, events: events, outcome: outcome }
  end

  Entry = Struct.new(
    :id, :workstream, :expected, :template, :params, :trace, :error_code,
    :provenance, :span_class, :termination, keyword_init: true
  ) do
    def fingerprint = Digest::SHA256.hexdigest(id)[0, 16]
    def rejected? = expected == :compile_error
  end

  class Registry
    attr_reader :entries

    def initialize(entries)
      @entries = entries.freeze
      validate!
    end

    def report
      {
        entries: entries.length,
        enabled: entries.count { |entry| !entry.rejected? },
        rejected: entries.count(&:rejected?),
        workstreams: entries.group_by(&:workstream).transform_values(&:length).sort.to_h,
        diagnostic_codes: entries.filter_map(&:error_code).uniq.sort,
        depth_cases: entries.count { |entry| entry.workstream == :depth },
        gaps: {
          discovered: GAPS.length,
          fixed: GAPS.count { |gap| gap.status == :fixed },
          expected: EXPECTED_GAPS.length,
          outstanding: EXPECTED_GAPS.length,
        },
      }
    end

    def validate!
      raise 'duplicate advanced semantic ids' unless entries.map(&:id).uniq.length == entries.length
      raise 'duplicate advanced gap ids' unless GAPS.map(&:id).uniq.length == GAPS.length
      raise 'advanced gap missing witness' if GAPS.any? { |gap| gap.witness.to_s.strip.empty? }
      missing = WORKSTREAMS - entries.map(&:workstream).uniq
      raise "advanced semantic workstreams missing: #{missing.join(', ')}" unless missing.empty?
      entries.each do |entry|
        raise "invalid advanced expectation #{entry.id}" unless %i[pass compile_error].include?(entry.expected)
        raise "missing provenance #{entry.id}" if entry.provenance.to_s.empty?
        entry.trace.validate!
        if entry.workstream == :diagnostics && entry.rejected? && entry.error_code.nil?
          raise "diagnostic case needs a code: #{entry.id}"
        end
        if entry.workstream == :diagnostics && entry.termination != :halts
          raise "diagnostic must declare halting recovery policy: #{entry.id}"
        end
        Models.validate!(entry)
      end
      self
    end
  end

  module_function

  # These models are deliberately small and closed.  They do not call the
  # compiler under test; they define the admission rule that a rendered case
  # must satisfy before it reaches the compiler/runtime lane.
  module Models
    module Capability
      ACCESS = {
        locked: :exclusive, write_locked: :exclusive, always_mutable: :direct,
        versioned: :snapshot, atomic_ptr: :snapshot, multiowned: :direct,
        shared: :direct, shared_locked: :exclusive,
        shared_write_locked: :exclusive, shared_versioned: :snapshot,
        shared_atomic: :direct,
      }.freeze
      REJECTED = %i[
        locked_direct_field write_locked_direct_field atomic_ptr_direct_field
        snapshot_plain borrowed_shared borrowed_write_locked materialized_plain
        view_plain observable_direct_index observable_direct_binary
        observable_direct_field observable_direct_method
      ].freeze

      module_function

      def validate!(entry)
        return unless entry.template == :capability_wrap_matrix
        mode = entry.params.fetch(:mode)
        if REJECTED.include?(mode)
          raise "capability legality accepted #{mode}" unless entry.rejected?
        elsif ACCESS.key?(mode)
          raise "capability legality rejected #{mode}" unless entry.expected == :pass
        elsif !%i[restrict_plain materialized_distinct observable_view].include?(mode)
          raise "unmodelled capability mode #{mode}"
        end
      end
    end

    module Effects
      PROPAGATES = %i[direct_raise or_raise_builtin fallible_callee_propagated].freeze

      module_function

      def expected(fail_source:, declaration:)
        declaration == :plain && PROPAGATES.include?(fail_source) ? :compile_error : :pass
      end

      def validate!(entry)
        if entry.template == :infallible_signature
          actual = expected(fail_source: entry.params.fetch(:fail_source), declaration: entry.params.fetch(:decl))
          raise "effect oracle mismatch #{entry.id}: #{actual} != #{entry.expected}" unless actual == entry.expected
        elsif entry.provenance == :commit_rollback_state_machine
          result = SemanticAdvanced.effect_machine_result(entry.params.fetch(:events))
          raise "effect trace mismatch #{entry.id}" unless entry.trace.value == result.fetch(:balance) && entry.trace.events == result.fetch(:events)
        end
      end
    end

    module Generics
      MAP_REJECTED = %i[
        duplicate_user_protocol_requirement user_protocol_conformance_mismatch
        associated_storage_wrong_key borrowed_value non_map_argument
        non_shared_argument unknown_associated_type unstable_method
      ].freeze
      SHARED_REJECTED = %i[direct_index direct_method plain_with unshared].freeze

      module_function

      def validate!(entry)
        if entry.provenance == :concrete_monomorph_oracle
          type = entry.params.fetch(:substitution).fetch(:T)
          source = entry.params.fetch(:source)
          raise "generic substitution missing #{entry.id}" unless source.include?("result: #{type}") && source.include?('FN genericIdentity<T>')
          return
        end
        case entry.template
        when :generic_map_protocol_matrix
          expected = MAP_REJECTED.include?(entry.params.fetch(:shape)) ? :compile_error : :pass
        when :generic_shared_map_capability_matrix
          expected = SHARED_REJECTED.include?(entry.params.fetch(:family)) ? :compile_error : :pass
        else
          return
        end
        raise "generic constraint mismatch #{entry.id}: #{expected} != #{entry.expected}" unless expected == entry.expected
      end
    end

    module Depth
      module_function

      def validate!(entry)
        return unless entry.workstream == :depth
        depth = entry.id[/-d(\d+)-/, 1].to_i
        source = entry.params.fetch(:source)
        actual = source.scan('NIL OR_ELSE').length
        raise "depth provenance mismatch #{entry.id}: #{actual + 1} != #{depth}" unless actual + 1 == depth
      end
    end

    # A schedule is an interleaving of fixed per-actor yield sequences.  The
    # model exhaustively enumerates two actors through six yield points (20
    # schedules), then verifies the commutative shared-counter outcome for
    # every schedule.  This is independent of the runtime scheduler and makes
    # the permitted trace set explicit.
    module Schedule
      module_function

      def enumerate(lengths)
        return [[]] if lengths.all?(&:zero?)
        lengths.each_index.flat_map do |actor|
          next [] if lengths[actor].zero?
          remaining = lengths.dup
          remaining[actor] -= 1
          enumerate(remaining).map { |tail| [actor] + tail }
        end
      end

      def counter_trace(schedule)
        state = 0
        schedule.map do |actor|
          state += 1
          [actor, state]
        end
      end

      def validate!
        schedules = enumerate([3, 3])
        raise 'two-actor six-yield schedule coverage drifted' unless schedules.length == 20
        raise 'counter schedule oracle is not invariant' unless schedules.all? { |schedule| counter_trace(schedule).last.last == 6 }
      end
    end

    module_function

    def validate!(entry)
      Capability.validate!(entry)
      Effects.validate!(entry)
      Generics.validate!(entry)
      Depth.validate!(entry)
      Schedule.validate! if entry.workstream == :concurrency
    end
  end

  # Called after FuzzGenerator has loaded the source matrices.  The entry
  # registry makes every admitted/rejected tuple visible in one report rather
  # than silently depending on template load order.
  def registry(templates: FuzzGenerator::TEMPLATES, depth_seeds: 1)
    @registries ||= {}
    @registries[[templates.object_id, depth_seeds]] ||= Registry.new(build_entries(templates, depth_seeds: depth_seeds))
  end

  def source_for(entry, templates: FuzzGenerator::TEMPLATES)
    template = templates.fetch(entry.template)
    rendered = template.renderer.call(entry.params.dup)
    rendered = { source: rendered } unless rendered.is_a?(Hash)
    rendered.merge(
      source: rendered.fetch(:source),
      error_code: entry.error_code || rendered[:error_code],
      diagnostic_code_required: entry.workstream == :diagnostics && entry.rejected?
    )
  end

  DiagnosticResult = Struct.new(:code, :line, :column, :token_type, keyword_init: true)

  # Uses the structured compiler error rather than CLI text.  The error code
  # is populated by ErrorHelper and the primary token supplies the span
  # contract.  Callers intentionally provide the frontend dependencies so the
  # generator itself remains cheap to load in ordinary fuzz runs.
  def verify_diagnostic!(entry, templates: FuzzGenerator::TEMPLATES, source_dir: Dir.pwd)
    raise "not a generated diagnostic #{entry.id}" unless entry.workstream == :diagnostics && entry.rejected?
    source = source_for(entry, templates: templates).fetch(:source)
    importer = ModuleImporter.new(base_dir: source_dir, use_mir: true)
    CompilerFrontend.compile(source, importer: importer, source_dir: source_dir)
    raise "diagnostic unexpectedly compiled: #{entry.id}"
  rescue SourceError => error
    raise "diagnostic code mismatch #{entry.id}: #{error.code.inspect} != #{entry.error_code.inspect}" unless error.code == entry.error_code
    token = error.token
    raise "diagnostic missing primary span: #{entry.id}" if token.nil? || token.type == :EOF || token.line <= 0 || token.column <= 0

    raise "diagnostic span class mismatch #{entry.id}: #{token.type.inspect} != #{entry.span_class.inspect}" unless token.type == entry.span_class

    DiagnosticResult.new(code: error.code, line: token.line, column: token.column, token_type: token.type).freeze
  end

  def build_entries(templates, depth_seeds:)
    entries = []
    add_template(entries, templates, :semantic_capability_matrix, :capability, :capability_access)
    add_template(entries, templates, :capability_wrap_matrix, :capability, :capability_wrap)
    add_template(entries, templates, :execution_boundary, :concurrency, :bounded_boundary_schedule)
    add_template(entries, templates, :bg_capture_transfer_matrix, :concurrency, :transfer_schedule)
    add_template(entries, templates, :infallible_signature, :effects, :fallibility_state_machine)
    add_template(entries, templates, :generic_map_protocol_matrix, :generics, :substitution_and_constraint)
    add_template(entries, templates, :generic_shared_map_capability_matrix, :generics, :shared_constraint)

    # These are intentional-invalid generic programs with registered compiler
    # codes.  They are the first generated diagnostic cells; the runner checks
    # the code instead of accepting an arbitrary failure.
    templates.fetch(:generic_map_protocol_matrix).cells.each do |cell|
      next unless cell.fetch(:expected, :pass) == :compile_error
      rendered = templates.fetch(:generic_map_protocol_matrix).renderer.call(cell.reject { |key, _| key == :expected })
      entries << entry_for(
        workstream: :diagnostics, template: :generic_map_protocol_matrix, params: cell,
        provenance: :generic_diagnostic, error_code: rendered.fetch(:error_code),
        span_class: diagnostic_span_class(:generic_map_protocol_matrix, cell)
      )
    end
    templates.fetch(:generic_shared_map_capability_matrix).cells.each do |cell|
      next unless cell.fetch(:expected, :pass) == :compile_error
      rendered = templates.fetch(:generic_shared_map_capability_matrix).renderer.call(cell.reject { |key, _| key == :expected })
      entries << entry_for(
        workstream: :diagnostics, template: :generic_shared_map_capability_matrix, params: cell,
        provenance: :shared_generic_diagnostic, error_code: rendered.fetch(:error_code),
        span_class: diagnostic_span_class(:generic_shared_map_capability_matrix, cell)
      )
    end

    deep_cases(depth_seeds).each { |item| entries << item }
    scheduled_concurrency_cases.each { |item| entries << item }
    effect_state_machine_cases.each { |item| entries << item }
    generic_monomorph_cases.each { |item| entries << item }
    entries
  end

  def add_template(entries, templates, template_name, workstream, provenance)
    templates.fetch(template_name).cells.each do |cell|
      entries << entry_for(workstream: workstream, template: template_name, params: cell, provenance: provenance)
    end
  end

  def entry_for(workstream:, template:, params:, provenance:, error_code: nil, span_class: nil)
    expected = params.fetch(:expected, :pass)
    clean_params = params.reject { |key, _| key == :expected }
    Entry.new(
      id: "advanced-#{workstream}-#{template}-#{Digest::SHA256.hexdigest(clean_params.inspect)[0, 12]}",
      workstream: workstream, expected: expected, template: template, params: clean_params,
      trace: trace_for(workstream, expected), error_code: error_code, provenance: provenance,
      span_class: span_class, termination: workstream == :diagnostics ? :halts : nil
    ).freeze
  end

  def diagnostic_span_class(template, params)
    case template
    when :generic_map_protocol_matrix
      {
        duplicate_user_protocol_requirement: :KEYWORD,
        user_protocol_conformance_mismatch: :KEYWORD,
        associated_storage_wrong_key: :CHAR,
        borrowed_value: :VAR_ID,
        non_map_argument: :KEYWORD,
        non_shared_argument: :KEYWORD,
        unknown_associated_type: :KEYWORD,
        unstable_method: :VAR_ID,
      }.fetch(params.fetch(:shape))
    when :generic_shared_map_capability_matrix
      {
        direct_index: :VAR_ID,
        direct_method: :VAR_ID,
        plain_with: :KEYWORD,
        unshared: :KEYWORD,
      }.fetch(params.fetch(:family))
    else
      raise "unmodelled diagnostic span #{template} #{params.inspect}"
    end
  end

  def trace_for(workstream, expected)
    return Trace.new(value: nil, state: :rejected, events: [:compile], outcome: :reject) if expected == :compile_error

    events = case workstream
             when :capability then %i[allocate access cleanup]
             when :concurrency then %i[spawn schedule join cleanup]
             when :effects then %i[transition observe cleanup]
             when :generics then %i[substitute constrain execute cleanup]
             else %i[execute cleanup]
             end
    Trace.new(value: :asserted, state: :clean, events: events, outcome: :return)
  end

  # A bounded, seed-addressable depth campaign avoids materialising the full
  # exponential grammar at depth 4+.  Each case is contextually typed and has
  # an ordered observation plus cleanup, so it is still a semantic program,
  # not a syntax sample.  More seeds increase breadth without changing IDs.
  def deep_cases(seed_count)
    seed_count = Integer(seed_count)
    raise 'advanced depth seeds must be positive' unless seed_count.positive?
    (4..6).flat_map do |depth|
      (0...seed_count).flat_map do |seed|
        deep_shapes.each_key.map { |shape| deep_entry(shape, depth, seed) }
      end
    end
  end

  def deep_shapes
    {
      int64: ["Int64", "#{'NIL OR_ELSE (' * 0}1_i64", 'ASSERT value == 1_i64;'],
      bool: ["Bool", 'TRUE', 'ASSERT value;'],
      string: ["String", 'COPY "deep"', 'ASSERT value.length() == 4_i64;'],
      list: ["Int64[]", '[1_i64]', 'ASSERT value.length() == 1_i64;'],
      map: ["{String}Int64", '{"key": 1_i64}', 'ASSERT value["key"] OR_ELSE 0_i64 == 1_i64;'],
      tuple: ["Tuple<Int64,String>", 'Tuple{1_i64, deep_text()}', 'ASSERT value._0 == 1_i64;',
              'FN deep_text() RETURNS String -> RETURN COPY "x"; END'],
    }.freeze
  end

  def deep_entry(shape, depth, seed)
    type, literal, assertion, prelude = deep_shapes.fetch(shape)
    expression = literal
    # Alternating COPY is meaningful only for owned values; nil fallback gives
    # all shapes the same contextual-depth route without relying on inference.
    (depth - 1).times { expression = "NIL OR_ELSE (#{expression})" }
    source = <<~CLEAR
      #{prelude}
      FN deep_#{shape}_#{depth}_#{seed}() RETURNS #{type} ->
        RETURN #{expression};
      END
      FN main() RETURNS Void ->
        value: #{type} = deep_#{shape}_#{depth}_#{seed}();
        #{assertion}
        RETURN;
      END
    CLEAR
    Entry.new(
      id: "advanced-depth-#{shape}-d#{depth}-s#{seed}", workstream: :depth,
      expected: :pass, template: :semantic_advanced_inline,
      params: { source: source }, trace: Trace.new(value: :asserted, state: :clean,
                                                    events: %i[derive observe cleanup], outcome: :return),
      error_code: nil, provenance: :bounded_depth_campaign
    ).freeze
  end

  # One source per legal interleaving of two three-step actors.  CLEAR's
  # scheduler remains free to choose an execution order; the generated program
  # makes each step an independently locked transition and asserts the model's
  # schedule-invariant final state.  The schedule is retained in provenance so
  # a failure can be reduced to the smallest interleaving witness.
  def scheduled_concurrency_cases
    Models::Schedule.enumerate([3, 3]).map.with_index do |schedule, index|
      schedule_id = schedule.join
      source = <<~CLEAR
        # semantic schedule #{schedule_id}
        STRUCT ScheduledCounter { value: Int64 }
        FN main() RETURNS !Void ->
          MUTABLE counter = ScheduledCounter{ value: 0_i64 } @shared:locked;
          left: ~Void = BG {
            WITH EXCLUSIVE counter AS state { state.value = state.value + 1_i64; }
            WITH EXCLUSIVE counter AS state { state.value = state.value + 1_i64; }
            WITH EXCLUSIVE counter AS state { state.value = state.value + 1_i64; }
          };
          right: ~Void = BG {
            WITH EXCLUSIVE counter AS state { state.value = state.value + 1_i64; }
            WITH EXCLUSIVE counter AS state { state.value = state.value + 1_i64; }
            WITH EXCLUSIVE counter AS state { state.value = state.value + 1_i64; }
          };
          NEXT left;
          NEXT right;
          WITH EXCLUSIVE counter AS observed {
            ASSERT observed.value == 6_i64, "scheduled counter";
          }
          RETURN;
        END
      CLEAR
      Entry.new(
        id: "advanced-concurrency-schedule-#{format('%02d', index)}-#{schedule_id}",
        workstream: :concurrency, expected: :pass, template: :semantic_advanced_inline,
        params: { source: source, schedule: schedule },
        trace: Trace.new(value: 6, state: { counter: 6 }, events: schedule.map { |actor| "actor_#{actor}".to_sym }, outcome: :return),
        error_code: nil, provenance: :exhaustive_two_actor_six_yield_schedule, span_class: nil
      ).freeze
    end
  end

  # A small independent commit/rollback machine.  `withdraw` either commits a
  # new balance or returns its error branch; generated CLEAR absorbs the error
  # with the pre-state, so the final assertion checks value, state and event
  # disposition together.
  def effect_state_machine_cases
    traces = [
      [[:deposit, 2]],
      [[:withdraw, 1]],
      [[:withdraw, 7]],
      [[:deposit, 3], [:withdraw, 6]],
      [[:deposit, 3], [:withdraw, 9]],
      [[:withdraw, 2], [:deposit, 4]],
      [[:withdraw, 7], [:deposit, 1]],
      [[:deposit, 2], [:withdraw, 3], [:withdraw, 9]],
    ]
    traces.map.with_index { |events, index| effect_state_machine_entry(events, index) }
  end

  def effect_state_machine_entry(events, index)
    result = effect_machine_result(events)
    state = result.fetch(:balance)
    trace = result.fetch(:events)
    render_state = 5
    statements = events.map do |kind, amount|
      case kind
      when :deposit
        render_state += amount
        "balance = balance + #{amount}_i64;"
      when :withdraw
        before = render_state
        render_state -= amount if amount <= render_state
        "balance = debit(balance, #{amount}_i64) OR_ELSE #{before}_i64;"
      end
    end
    source = <<~CLEAR
      FN debit(balance: Int64, amount: Int64) RETURNS !Int64 ->
        IF amount > balance THEN RAISE "insufficient"; END
        RETURN balance - amount;
      END
      FN main() RETURNS !Void ->
        MUTABLE balance: Int64 = 5_i64;
        #{statements.join("\n        ")}
        ASSERT balance == #{state}_i64, "effect state machine";
        RETURN;
      END
    CLEAR
    Entry.new(
      id: "advanced-effects-state-machine-#{format('%02d', index)}",
      workstream: :effects, expected: :pass, template: :semantic_advanced_inline,
      params: { source: source, events: events },
      trace: Trace.new(value: state, state: { balance: state }, events: trace, outcome: :return),
      error_code: nil, provenance: :commit_rollback_state_machine, span_class: nil
    ).freeze
  end

  def effect_machine_result(events)
    events.reduce({ balance: 5, events: [] }) do |result, (kind, amount)|
      case kind
      when :deposit
        { balance: result.fetch(:balance) + amount, events: result.fetch(:events) + [:deposit] }
      when :withdraw
        if amount <= result.fetch(:balance)
          { balance: result.fetch(:balance) - amount, events: result.fetch(:events) + [:withdraw_commit] }
        else
          { balance: result.fetch(:balance), events: result.fetch(:events) + [:withdraw_rollback] }
        end
      else
        raise "unknown effect event #{kind}"
      end
    end
  end

  # Deterministic allocation-fault cases are executed as standalone binaries:
  # a bundled Zig test cannot control each program's runtime allocator state.
  # The reference model is deliberately small: every successful allocation
  # sequence either completes its expected observation or, when the configured
  # fault lands, the OR_ELSE branch records recovery and returns cleanly.
  FaultCase = Struct.new(:id, :source, :oom_after, :expected_output, :trace, keyword_init: true)

  def allocation_fault_cases
    grow = <<~CLEAR
      FN grow(n: Int64) RETURNS Int64 ->
        MUTABLE xs: Int64[] = [];
        MUTABLE i = 0_i64;
        WHILE i < n DO
          &xs.append(i);
          i += 1_i64;
        END
        RETURN xs.length();
      END
    CLEAR
    [
      FaultCase.new(
        id: :list_growth_rollback,
        oom_after: 20,
        expected_output: 'recovered list allocation',
        trace: Trace.new(value: :recovered, state: { list: :rolled_back }, events: %i[allocate fault recover cleanup], outcome: :return),
        source: <<~CLEAR,
          #{grow}
          FN main() RETURNS Void ->
            _ = grow(100000_i64) OR_ELSE PASS;
            print("recovered list allocation\\n");
            RETURN;
          END
        CLEAR
      ),
      FaultCase.new(
        id: :list_growth_or_else_value,
        oom_after: 20,
        expected_output: 'fallback length=0',
        trace: Trace.new(value: 0, state: { list: :fallback }, events: %i[allocate fault fallback observe cleanup], outcome: :return),
        source: <<~CLEAR,
          #{grow}
          FN main() RETURNS Void ->
            size = grow(100000_i64) OR_ELSE 0_i64;
            ASSERT size == 0_i64, "fault fallback";
            print("fallback length=0\\n");
            RETURN;
          END
        CLEAR
      ),
    ].each(&:freeze).freeze
  end

  # Each generic program carries the concrete substitution separately from the
  # generic definition.  The model checks that the function boundary and the
  # concrete observer agree, so type-argument inference is not trusted as the
  # test oracle.
  def generic_monomorph_cases
    shapes = {
      int64: ['Int64', '7_i64', 'ASSERT result == 7_i64;'],
      bool: ['Bool', 'TRUE', 'ASSERT result;'],
      box: ['GenericBox', 'GenericBox{ value: 9_i64 }', 'ASSERT result.value == 9_i64;', 'STRUCT GenericBox { value: Int64 }'],
      string: ['String', 'genericText()', 'ASSERT result.length() == 1_i64;', 'FN genericText() RETURNS String -> RETURN COPY "x"; END'],
      list: ['Int64[]', 'genericList()', 'ASSERT result.length() == 1_i64;', <<~CLEAR.chomp],
        FN genericList() RETURNS Int64[] ->
          MUTABLE items: Int64[] = [];
          &items.append(1_i64);
          RETURN items;
        END
      CLEAR
      map: ['HashMap<Int64>', '{"one": 1_i64}', 'ASSERT result.length() == 1_i64;'],
      tuple: ['Tuple<Int64,String>', 'Tuple{1_i64, genericText()}', 'ASSERT result._0 == 1_i64;', 'FN genericText() RETURNS String -> RETURN COPY "x"; END'],
    }
    shapes.map.with_index do |(shape, (type, literal, assertion, prelude)), index|
      source = <<~CLEAR
        #{prelude}
        FN genericIdentity<T>(value: T) RETURNS T -> RETURN value; END
        FN main() RETURNS Void ->
          result: #{type} = genericIdentity(#{literal});
          #{assertion}
          RETURN;
        END
      CLEAR
      Entry.new(
        id: "advanced-generics-monomorph-#{shape}-#{index}", workstream: :generics,
        expected: :pass, template: :semantic_advanced_inline,
        params: { source: source, substitution: { T: type } },
        trace: Trace.new(value: :asserted, state: { substitution: type }, events: %i[substitute execute cleanup], outcome: :return),
        error_code: nil, provenance: :concrete_monomorph_oracle, span_class: nil
      ).freeze
    end
  end

end
