# frozen_string_literal: true

# High-volume capability campaign.  Unlike the small capability smoke suite,
# this crosses each approved capability/value pair with independently derived
# typed payload expressions.  The capability legality table remains closed in
# SemanticEquivalence::CAPABILITIES; this suite only varies the payload
# derivation and therefore cannot invent an unreviewed wrapper/access pair.
require 'digest'
require_relative 'semantic_equivalence'

module SemanticCapabilityExpansion
  DEFAULT_DEPTH = 4
  TARGET_PER_PAIR = 100

  Case = Struct.new(:id, :value_id, :capability_id, :fragment, :source, keyword_init: true) do
    def fingerprint = Digest::SHA256.hexdigest(id)[0, 16]
  end

  class Suite
    attr_reader :cases, :seed, :target_per_pair, :depth

    def initialize(parser_path:, depth: DEFAULT_DEPTH, seed: 1, target_per_pair: TARGET_PER_PAIR)
      @seed = Integer(seed)
      @depth = Integer(depth)
      @target_per_pair = Integer(target_per_pair)
      @expression_suite = SemanticEquivalence::Suite.mvp(parser_path: parser_path, max_depth: depth, seed: seed)
      @values = SemanticEquivalence::VALUES.values.to_h { |value| [value.id, value] }
      @capabilities = SemanticEquivalence::CAPABILITIES
      @cases = build_cases.freeze
      validate!
    end

    def report
      {
        depth: depth,
        seed: seed,
        target_per_pair: target_per_pair,
        cases: cases.length,
        pairs: cases.group_by { |item| [item.value_id, item.capability_id] }.transform_values(&:length).sort.to_h,
        families: cases.group_by(&:value_id).transform_values(&:length).sort.to_h,
      }
    end

    private

    def build_cases
      capabilities.flat_map do |capability|
        capability.value_ids.flat_map do |value_id|
          value = values.fetch(value_id)
          fragments = @expression_suite.fragments.select { |fragment| fragment.goal.key == value.goal.key }
          selected = fragments
            .uniq { |fragment| [fragment.source, fragment.setups] }
            .sort_by { |fragment| Digest::SHA256.hexdigest("#{seed}:#{value_id}:#{capability.id}:#{fragment.fingerprint}") }
            .first(target_per_pair)
          selected.map { |fragment| build_case(value, capability, fragment) }
        end
      end
    end

    def build_case(value, capability, fragment)
      setup = (value.setups + fragment.setups).uniq.join("\n\n")
      observation = value.assertion(capability.access == :direct ? 'value' : 'observed')
      access = case capability.access
               when :direct then observation
               when :exclusive then "WITH EXCLUSIVE value AS observed {\n        #{observation}\n    }"
               when :snapshot then "WITH SNAPSHOT value AS observed {\n        #{observation}\n    }"
               else raise "unknown capability access #{capability.access}"
               end
      id = "capexp-#{value.id}-#{capability.id}-#{fragment.fingerprint}"
      source = <<~CLEAR
        #{setup}
        FN main() RETURNS Void ->
          MUTABLE value = #{fragment.source} #{capability.suffix};
          #{access}
          RETURN;
        END
      CLEAR
      Case.new(id: id, value_id: value.id, capability_id: capability.id, fragment: fragment, source: source).freeze
    end

    def values = @values
    def capabilities = @capabilities

    def validate!
      expected_pairs = capabilities.flat_map { |capability| capability.value_ids.map { |value_id| [value_id, capability.id] } }.sort
      actual = cases.group_by { |item| [item.value_id, item.capability_id] }.transform_values(&:length)
      raise 'duplicate capability expansion ids' unless cases.map(&:id).uniq.length == cases.length
      short = expected_pairs.filter_map do |pair|
        actual_count = actual.fetch(pair, 0)
        pair if actual_count < target_per_pair
      end
      raise "capability expansion target shortfall: #{short.inspect}" unless short.empty?
    end
  end

  TransportCase = Struct.new(:id, :value_id, :capability_id, :carrier, :source, keyword_init: true)

  # Explicit COPY/GIVE/TAKES transport forms.  These are separate from payload
  # expansion because the legality model distinguishes an identifier transfer
  # from a field projection: a field must first be COPY'd into a binding before
  # it may be GIVEN to a TAKES sink.
  class TransportSuite
    attr_reader :cases

    def initialize
      values = SemanticEquivalence::VALUES.values.to_h { |value| [value.id, value] }
      capabilities = SemanticEquivalence::CAPABILITIES.select { |capability| capability.access == :direct }
      @cases = capabilities.flat_map do |capability|
        capability.value_ids.reject { |value_id| value_id == :int64 }.flat_map do |value_id|
          value = values.fetch(value_id)
          %i[direct nested_field].map { |carrier| build_case(value, capability, carrier) }
        end
      end.freeze
      validate!
    end

    def report
      {
        cases: cases.length,
        pairs: cases.group_by { |item| [item.value_id, item.capability_id] }.transform_values(&:length).sort.to_h,
        carriers: cases.map(&:carrier).uniq.sort,
      }
    end

    private

    def build_case(value, capability, carrier)
      setup = value.setups.join("\n\n")
      # A bracket literal initially has fixed-array shape.  Construct the
      # managed list through an owned List-returning helper so its capability
      # wrapper receives the ArrayList payload required by COPY/GIVE/TAKES.
      # This exercises the transport boundary rather than the unrelated fixed
      # array contextual-literal path.
      if value.id == :list
        setup = [setup, <<~CLEAR.chomp].reject(&:empty?).join("\n\n")
          FN semanticManagedList() RETURNS Int64[] ->
            MUTABLE items: Int64[] = [];
            &items.append(1_i64);
            RETURN items;
          END
        CLEAR
      end
      literal = value.id == :list ? 'semanticManagedList()' : value.render_literal
      consume = <<~CLEAR
        FN capabilityConsume(TAKES input: #{value.clear_type}) RETURNS Void ->
          #{value.assertion('input')}
          RETURN;
        END
      CLEAR
      transport = case carrier
                  when :direct
                    "copied = COPY value;\n  capabilityConsume(GIVE copied);"
                  when :nested_field
                    <<~CLEAR.chomp
                      holder = CapabilityTransportHolder{ value: COPY value };
                      extracted = COPY holder.value;
                      capabilityConsume(GIVE extracted);
                    CLEAR
                  else
                    raise "unknown transport carrier #{carrier}"
                  end
      # The field must retain the same managed-handle surface as `value`.
      # Declaring it as the raw payload type would ask Zig to place Rc/Arc in
      # a value-shaped field and masks the transport behavior we mean to test.
      holder = carrier == :nested_field ? "STRUCT CapabilityTransportHolder { value: #{value.clear_type}#{capability.suffix} }\n" : ""
      source = <<~CLEAR
        #{setup}
        #{holder}#{consume}
        FN main() RETURNS Void ->
          MUTABLE value = #{literal} #{capability.suffix};
          #{transport}
          RETURN;
        END
      CLEAR
      TransportCase.new(
        id: "captransport-#{value.id}-#{capability.id}-#{carrier}", value_id: value.id,
        capability_id: capability.id, carrier: carrier, source: source
      ).freeze
    end

    def validate!
      raise 'duplicate capability transport ids' unless cases.map(&:id).uniq.length == cases.length
      raise 'transport suite must cover direct and nested carriers' unless report.fetch(:carriers) == %i[direct nested_field]
      raise 'transport suite lost a COPY/GIVE pair' unless report.fetch(:pairs).values.all? { |count| count == 2 }
    end
  end
end
