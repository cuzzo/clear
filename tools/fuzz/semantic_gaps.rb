# frozen_string_literal: true

require_relative 'semantic_equivalence'

# Executable ledger of compiler defects exposed by semantic generation.  A
# witness remains positive CLEAR source: these are never weakened into
# expected-compilation-failure cells.
module SemanticGaps
  Gap = Struct.new(:id, :status, :phase, :summary, :witness, keyword_init: true)

  FIXED = [
    Gap.new(
      id: :contextual_nil_or_else,
      status: :fixed,
      phase: :original,
      summary: SemanticEquivalence::FIXED_LANGUAGE_GAPS.fetch(:contextual_nil_or_else),
      witness: <<~CLEAR
        FN main() RETURNS Void ->
          value: Int64 = NIL OR_ELSE 1_i64;
          ASSERT value == 1_i64;
          RETURN;
        END
      CLEAR
    ),
    Gap.new(
      id: :direct_struct_literal_field,
      status: :fixed,
      phase: :original,
      summary: SemanticEquivalence::FIXED_LANGUAGE_GAPS.fetch(:direct_struct_literal_field),
      witness: <<~CLEAR
        STRUCT Box { value: Int64 }
        FN main() RETURNS Void ->
          value = Box{ value: 1_i64 }.value;
          ASSERT value == 1_i64;
          RETURN;
        END
      CLEAR
    ),
    Gap.new(
      id: :unused_pipeline_capture,
      status: :fixed,
      phase: :original,
      summary: SemanticEquivalence::FIXED_LANGUAGE_GAPS.fetch(:unused_pipeline_capture),
      witness: <<~CLEAR
        FN main() RETURNS Void ->
          value = [7_i64] |> SELECT 1_i64 |> SUM _;
          ASSERT value == 1_i64;
          RETURN;
        END
      CLEAR
    ),
    Gap.new(
      id: :int_min_max_projection,
      status: :fixed,
      phase: :original,
      summary: SemanticEquivalence::FIXED_LANGUAGE_GAPS.fetch(:int_min_max_projection),
      witness: <<~CLEAR
        FN main() RETURNS Void ->
          smallest: Int64 = [7_i64, 1_i64] |> MIN _;
          largest: Int64 = [1_i64, 7_i64] |> MAX _;
          ASSERT smallest == 1_i64;
          ASSERT largest == 7_i64;
          RETURN;
        END
      CLEAR
    ),
    Gap.new(
      id: :nested_pipeline_expression,
      status: :fixed,
      phase: :original,
      summary: SemanticEquivalence::FIXED_LANGUAGE_GAPS.fetch(:nested_pipeline_expression),
      witness: <<~CLEAR
        FN main() RETURNS Void ->
          value = [7_i64] |> SELECT ([1_i64] |> SUM _) |> SUM _;
          ASSERT value == 1_i64;
          RETURN;
        END
      CLEAR
    ),
    Gap.new(
      id: :nested_owned_map,
      status: :fixed,
      phase: :original,
      summary: SemanticEquivalence::FIXED_LANGUAGE_GAPS.fetch(:nested_owned_map),
      witness: <<~CLEAR
        FN main() RETURNS Void ->
          values: HashMap<Int64>[] = [{"one": 1_i64}];
          ASSERT values[0_i64].count() == 1_i64;
          ASSERT (values[0_i64]["one"] OR_ELSE 0_i64) == 1_i64;
          RETURN;
        END
      CLEAR
    ),
  ].map(&:freeze).freeze

  capability_cases = SemanticEquivalence::CapabilitySuite.new.cases.to_h do |item|
    [item.id, item]
  end
  capability_witnesses = {
    string_refcount_observer: 'capability-string-multiowned',
    list_refcount_observer: 'capability-list-multiowned',
    map_refcount_wrap: 'capability-map-shared',
    tuple_refcount_observer: 'capability-tuple-shared',
  }.freeze
  FIXED_CAPABILITIES = SemanticEquivalence::FIXED_CAPABILITY_GAPS.map do |id|
    item = capability_cases.fetch(capability_witnesses.fetch(id))
    Gap.new(
      id: id,
      status: :fixed,
      phase: :capability_expansion,
      summary: id.to_s.tr('_', ' '),
      witness: item.source
    ).freeze
  end.freeze

  FIXED_EXPANSION = [
    Gap.new(
      id: :takes_direct_list_literal,
      status: :fixed,
      phase: :ownership_expansion,
      summary: SemanticEquivalence::FIXED_EXPANSION_GAPS.fetch(:takes_direct_list_literal),
      witness: <<~CLEAR
        FN consume(TAKES input: Int64[]) RETURNS Void -> RETURN; END
        FN main() RETURNS Void -> consume([1_i64]); RETURN; END
      CLEAR
    ),
    Gap.new(
      id: :tuple_nil_or_else_transfer,
      status: :fixed,
      phase: :managed_recursion,
      summary: SemanticEquivalence::FIXED_EXPANSION_GAPS.fetch(:tuple_nil_or_else_transfer),
      witness: <<~CLEAR
        FN text() RETURNS String -> RETURN COPY "one"; END
        FN main() RETURNS Void ->
          value: Tuple<Int64,String> = NIL OR_ELSE Tuple{1_i64, text()};
          ASSERT value._1 == "one";
          RETURN;
        END
      CLEAR
    ),
    Gap.new(
      id: :tuple_temporary_copy_leak,
      status: :fixed,
      phase: :ownership_expansion,
      summary: SemanticEquivalence::FIXED_EXPANSION_GAPS.fetch(:tuple_temporary_copy_leak),
      witness: <<~CLEAR
        FN text() RETURNS String -> RETURN COPY "one"; END
        FN main() RETURNS Void ->
          value: Tuple<Int64,String> = COPY (Tuple{1_i64, text()});
          ASSERT value._1 == "one";
          RETURN;
        END
      CLEAR
    ),
    Gap.new(
      id: :list_or_else_loop_field_coercion,
      status: :fixed,
      phase: :whole_program,
      summary: SemanticEquivalence::FIXED_EXPANSION_GAPS.fetch(:list_or_else_loop_field_coercion),
      witness: <<~CLEAR
        STRUCT Box { value: Int64[] }
        FN main() RETURNS Void ->
          MUTABLE i: Int64 = 0_i64;
          WHILE i < 1_i64 DO
            box = Box{ value: NIL OR_ELSE [1_i64] };
            ASSERT box.value.length() == 1_i64;
            i = i + 1_i64;
          END
          RETURN;
        END
      CLEAR
    ),
    Gap.new(
      id: :nested_owned_sink_allocator_transport,
      status: :fixed,
      phase: :whole_program,
      summary: SemanticEquivalence::FIXED_EXPANSION_GAPS.fetch(:nested_owned_sink_allocator_transport),
      witness: <<~CLEAR
        STRUCT Item { value: Int64 }
        STRUCT Holder { items: Item[] }
        FN main() RETURNS Void ->
          items: Item[] = [Item{ value: 1_i64 }];
          holders: Holder[] = [Holder{ items: items }];
          ASSERT holders[0_i64].items[0_i64].value == 1_i64;
          RETURN;
        END
      CLEAR
    ),
    Gap.new(
      id: :nested_list_contextual_shape,
      status: :fixed,
      phase: :whole_program,
      summary: SemanticEquivalence::FIXED_EXPANSION_GAPS.fetch(:nested_list_contextual_shape),
      witness: <<~CLEAR
        FN main() RETURNS Void ->
          values: Int64[][] = [NIL OR_ELSE COPY (NIL OR_ELSE [1_i64])];
          ASSERT values[0_i64][0_i64] == 1_i64;
          RETURN;
        END
      CLEAR
    ),
    Gap.new(
      id: :owned_optional_fallback_copy_lifetime,
      status: :fixed,
      phase: :whole_program,
      summary: SemanticEquivalence::FIXED_EXPANSION_GAPS.fetch(:owned_optional_fallback_copy_lifetime),
      witness: <<~CLEAR
        FN main() RETURNS Void ->
          original: String = COPY (NIL OR_ELSE COPY (COPY "one"));
          value: String = COPY original;
          ASSERT value == "one";
          RETURN;
        END
      CLEAR
    ),
    Gap.new(
      id: :tuple_collection_constructor_context,
      status: :fixed,
      phase: :migration_completion,
      summary: SemanticEquivalence::FIXED_EXPANSION_GAPS.fetch(:tuple_collection_constructor_context),
      witness: <<~CLEAR
        FN main() RETURNS Void ->
          value: Tuple<[List]Int64, Bool> = Tuple{List[], TRUE};
          ASSERT value._0.length() == 0_i64;
          RETURN;
        END
      CLEAR
    ),
    Gap.new(
      id: :collection_literal_child_allocator_transport,
      status: :fixed,
      phase: :migration_completion,
      summary: SemanticEquivalence::FIXED_EXPANSION_GAPS.fetch(:collection_literal_child_allocator_transport),
      witness: <<~CLEAR
        FN inner() RETURNS !Int64[]@list ->
          MUTABLE value: Int64[]@list = [];
          &value.append(1_i64);
          RETURN value;
        END
        FN run() RETURNS !Void ->
          MUTABLE items: Int64[][]@list = [inner() OR_ELSE PASS];
          RETURN;
        END
        FN main() RETURNS Void ->
          run() OR_ELSE PASS;
          RETURN;
        END
      CLEAR
    ),
    Gap.new(
      id: :optional_owned_branch_allocator_convergence,
      status: :fixed,
      phase: :migration_completion,
      summary: SemanticEquivalence::FIXED_EXPANSION_GAPS.fetch(:optional_owned_branch_allocator_convergence),
      witness: <<~CLEAR
        STRUCT Box { label: String }
        FN main() RETURNS Void ->
          maybe: ?Box = Box{ label: COPY "abc" };
          value: ?String = maybe?.label;
          ASSERT (value OR_ELSE COPY "").length() == 3_i64;
          RETURN;
        END
      CLEAR
    ),
    Gap.new(
      id: :tuple_temporary_allocator_convergence,
      status: :fixed,
      phase: :whole_program,
      summary: SemanticEquivalence::FIXED_EXPANSION_GAPS.fetch(:tuple_temporary_allocator_convergence),
      witness: <<~CLEAR
        FN text() RETURNS String -> RETURN COPY "one"; END
        FN main() RETURNS Void ->
          FOR unused IN [0_i64] DO
            values: Tuple<Int64,String>[] = [Tuple{1_i64, text()}];
            ASSERT values[0_i64]._1 == "one";
          END
          RETURN;
        END
      CLEAR
    ),
  ].freeze

  OUTSTANDING = [].freeze

  ALL = (FIXED + FIXED_CAPABILITIES + FIXED_EXPANSION + OUTSTANDING).freeze

  module_function

  def report
    {
      discovered: ALL.length,
      fixed: ALL.count { |gap| gap.status == :fixed },
      outstanding: OUTSTANDING.length,
      outstanding_ids: OUTSTANDING.map(&:id),
      by_phase: ALL.group_by(&:phase).transform_values(&:length),
    }
  end

  def validate!
    raise 'duplicate semantic gap ids' unless ALL.map(&:id).uniq.length == ALL.length
    raise 'outstanding gap ledger differs from generator exclusions' unless OUTSTANDING.map(&:id).sort == SemanticEquivalence::KNOWN_GAPS.keys.sort
    raise 'fixed expansion gap ledger differs from generator registry' unless FIXED_EXPANSION.map(&:id).sort == SemanticEquivalence::FIXED_EXPANSION_GAPS.keys.sort
    raise 'fixed gap missing raw witness' if (FIXED + FIXED_CAPABILITIES + FIXED_EXPANSION).any? { |gap| gap.witness.to_s.strip.empty? }
    raise 'outstanding gap missing raw witness' if OUTSTANDING.any? { |gap| gap.witness.to_s.strip.empty? }
    true
  end
end
