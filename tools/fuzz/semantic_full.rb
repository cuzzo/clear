# frozen_string_literal: true

require 'digest'
require_relative 'semantic_equivalence'

# The completion lane crosses recursive expression derivations with bounded
# whole-program topology.  This is deliberately separate from the small
# default matrix: CI can run a deterministic shard while campaigns can execute
# all 7,000 required cases without changing their identities.
module SemanticFull
  TARGET_PER_FAMILY = 1_000
  DEFAULT_DEPTH = 3

  Topology = Struct.new(:id, :scope, :carrier, keyword_init: true)
  ProgramCase = Struct.new(
    :id,
    :family,
    :topology,
    :fragment,
    :source,
    keyword_init: true
  ) do
    def fingerprint = Digest::SHA256.hexdigest(id)[0, 16]
  end

  SCOPES = %i[direct if_true while_once foreach_once helper_function].freeze
  CARRIERS = %i[local mutable_or_copy struct_field list_element give_to_takes].freeze
  TOPOLOGIES = SCOPES.product(CARRIERS).map do |scope, carrier|
    Topology.new(id: :"#{scope}_#{carrier}", scope: scope, carrier: carrier).freeze
  end.freeze

  # Declarative manifest for the advanced depth campaign.  It keeps the
  # expensive 10-seed depth-5/6 work out of ordinary PR template loading while
  # making the complete required run inspectable and shardable.
  AdvancedCampaignConfig = Struct.new(:depth, :seed, :target_per_family, keyword_init: true) do
    def id = "depth#{depth}-seed#{seed}-#{target_per_family}perfamily"
  end

  module AdvancedCampaign
    DEPTH4 = AdvancedCampaignConfig.new(depth: 4, seed: 1, target_per_family: TARGET_PER_FAMILY).freeze
    DEEP = (1..10).flat_map do |seed|
      [5, 6].map { |depth| AdvancedCampaignConfig.new(depth: depth, seed: seed, target_per_family: TARGET_PER_FAMILY).freeze }
    end.freeze
    ALL = ([DEPTH4] + DEEP).freeze

    module_function

    def report
      {
        depth4: DEPTH4.id,
        deep_campaigns: DEEP.length,
        deep_seeds: DEEP.map(&:seed).uniq,
        target_per_family: TARGET_PER_FAMILY,
        cases_per_deep_campaign: TARGET_PER_FAMILY * SemanticEquivalence::VALUES.goals.length,
      }
    end

    def build(config, parser_path:)
      Suite.new(parser_path: parser_path, depth: config.depth, seed: config.seed, target_per_family: config.target_per_family)
    end
  end

  class Suite
    attr_reader :expression_suite, :all_cases, :cases, :seed, :target_per_family

    def initialize(parser_path:, depth: DEFAULT_DEPTH, seed: 1, target_per_family: TARGET_PER_FAMILY)
      @seed = Integer(seed)
      @target_per_family = Integer(target_per_family)
      @expression_suite = SemanticEquivalence::Suite.mvp(
        parser_path: parser_path,
        max_depth: depth,
        seed: seed
      )
      @all_cases = build_cases.freeze
      @cases = select_family_targets.freeze
      validate!
    end

    def report
      {
        target_per_family: target_per_family,
        cases: cases.length,
        family_cases: cases.group_by(&:family).transform_values(&:length).sort.to_h,
        topologies: TOPOLOGIES.length,
        scopes: SCOPES.length,
        carriers: CARRIERS.length,
        copy_cases: cases.count { |item| item.topology.carrier == :mutable_or_copy && managed?(item.fragment) },
        give_takes_cases: cases.count { |item| item.topology.carrier == :give_to_takes && managed?(item.fragment) },
        fixed_language_gaps: SemanticEquivalence::FIXED_LANGUAGE_GAPS.keys,
        fixed_expansion_gaps: SemanticEquivalence::FIXED_EXPANSION_GAPS.keys,
        outstanding_language_gaps: SemanticEquivalence::KNOWN_GAPS.keys,
      }
    end

    private

    def build_cases
      blocked_fingerprints = expression_suite.blocked_obligations.map { |item| item.derivation.fingerprint }.to_h { |id| [id, true] }
      expression_suite.fragments.flat_map do |fragment|
        next [] if blocked_fingerprints.key?(fragment.fingerprint)
        TOPOLOGIES.filter_map do |topology|
          next unless supported_composition?(fragment, topology)
          id = "full-#{fragment.goal.type}-#{fragment.fingerprint}-#{topology.id}"
          ProgramCase.new(
            id: id,
            family: fragment.goal.type,
            topology: topology,
            fragment: fragment,
            source: render_program(fragment, topology)
          ).freeze
        end
      end
    end

    def supported_composition?(fragment, topology)
      true
    end

    def select_family_targets
      SemanticEquivalence::VALUES.goals.flat_map do |goal|
        family = all_cases.select { |item| item.family == goal.type }
        # Select every topology evenly before applying the seeded order.  A
        # single global hash sample made COPY/GIVE coverage probabilistic even
        # though the full population contains those carriers uniformly.
        quotient, remainder = target_per_family.divmod(TOPOLOGIES.length)
        selected = TOPOLOGIES.each_with_index.flat_map do |topology, index|
          quota = quotient + (index < remainder ? 1 : 0)
          family
            .select { |item| item.topology.id == topology.id }
            .sort_by { |item| Digest::SHA256.hexdigest("#{seed}:#{item.id}") }
            .first(quota)
        end
        selected.sort_by { |item| Digest::SHA256.hexdigest("#{seed}:selected:#{item.id}") }
      end
    end

    def validate!
      counts = cases.group_by(&:family).transform_values(&:length)
      missing = SemanticEquivalence::VALUES.goals.filter_map do |goal|
        actual = counts.fetch(goal.type, 0)
        [goal.type, actual] if actual < target_per_family
      end
      raise "semantic full target shortfall: #{missing.inspect}" unless missing.empty?
      raise "semantic topology registry must contain 25 combinations" unless TOPOLOGIES.length == 25
      raise "duplicate semantic full case ids" unless cases.map(&:id).uniq.length == cases.length
      topology_counts = cases.group_by { |item| item.topology.id }.transform_values(&:length)
      raise "semantic full selection omitted a topology" unless TOPOLOGIES.all? { |topology| topology_counts.fetch(topology.id, 0).positive? }
    end

    def render_program(fragment, topology)
      value = SemanticEquivalence::VALUES.fetch(fragment.goal.type)
      extra_setups, statements = carrier(value, fragment, topology.carrier)
      definitions = (fragment.setups + extra_setups).uniq.join("\n\n")
      scoped_definitions, main_body = scope(statements, topology.scope)
      [definitions, scoped_definitions, main_body].reject(&:empty?).join("\n\n") + "\n"
    end

    def carrier(value, fragment, carrier)
      assertion = ->(name) { value.assertion(name) }
      stem = value.id.to_s.split('_').map(&:capitalize).join
      case carrier
      when :local
        [[], "value: #{value.clear_type} = #{fragment.source};\n#{assertion.call('value')}"]
      when :mutable_or_copy
        if managed?(fragment)
          [[], <<~CLEAR.strip]
            original: #{value.clear_type} = #{fragment.source};
            value: #{value.clear_type} = COPY original;
            #{assertion.call('value')}
            #{assertion.call('original')}
          CLEAR
        else
          [[], "MUTABLE value: #{value.clear_type} = #{fragment.source};\n#{assertion.call('value')}"]
        end
      when :struct_field
        definition = "STRUCT SemanticWhole#{stem} { value: #{value.clear_type} }"
        [[definition], "box = SemanticWhole#{stem}{ value: #{fragment.source} };\n#{assertion.call('box.value')}"]
      when :list_element
        [[], "values: #{value.clear_type}[] = [#{fragment.source}];\n#{assertion.call('values[0_i64]')}"]
      when :give_to_takes
        if managed?(fragment)
          helper = <<~CLEAR.strip
            FN semanticWholeTake#{stem}(TAKES input: #{value.clear_type}) RETURNS Void ->
              #{assertion.call('input')}
              RETURN;
            END
          CLEAR
          [[helper], "original: #{value.clear_type} = #{fragment.source};\nsemanticWholeTake#{stem}(GIVE original);"]
        else
          helper = "FN semanticWholeArg#{stem}(input: #{value.clear_type}) RETURNS #{value.clear_type} -> RETURN input; END"
          [[helper], "value = semanticWholeArg#{stem}(#{fragment.source});\n#{assertion.call('value')}"]
        end
      else
        raise "unknown semantic carrier #{carrier}"
      end
    end

    def scope(statements, scope)
      indented = statements.lines.map { |line| "    #{line}" }.join.rstrip
      case scope
      when :direct
        ['', main_function(indented)]
      when :if_true
        body = "    IF TRUE THEN\n#{indent(indented, 4)}\n    END"
        ['', main_function(body)]
      when :while_once
        body = <<~CLEAR.rstrip
              MUTABLE semantic_i: Int64 = 0_i64;
              WHILE semantic_i < 1_i64 DO
            #{indent(indented, 4)}
                  semantic_i = semantic_i + 1_i64;
              END
        CLEAR
        ['', main_function(body)]
      when :foreach_once
        body = "    FOR semantic_unused IN [0_i64] DO\n#{indent(indented, 4)}\n    END"
        ['', main_function(body)]
      when :helper_function
        helper = <<~CLEAR
          FN semanticWholeScenario() RETURNS Void ->
          #{indented}
              RETURN;
          END
        CLEAR
        main = <<~CLEAR
          FN main() RETURNS Void ->
              semanticWholeScenario();
              RETURN;
          END
        CLEAR
        [helper.rstrip, main.rstrip]
      else
        raise "unknown semantic scope #{scope}"
      end
    end

    def main_function(body)
      <<~CLEAR.rstrip
        FN main() RETURNS Void ->
        #{body}
            RETURN;
        END
      CLEAR
    end

    def indent(text, spaces)
      prefix = ' ' * spaces
      text.lines.map { |line| prefix + line }.join.rstrip
    end

    def managed?(fragment)
      fragment.attributes.ownership != :copy
    end
  end
end
