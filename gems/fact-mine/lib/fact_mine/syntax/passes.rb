# frozen_string_literal: true

module FactMine
  module Syntax
    VisibilityEvent = Struct.new(:owner, :visibility, :line, :span, :target_names, keyword_init: true)

    class StatelessSyntaxPass
      STRUCTURAL_KEYS = %i[
        function_defs
        owner_defs
        call_sites
        state_declarations
        state_param_origins
        state_reads
        state_writes
      ].freeze

      def initialize(document:, profile:, walker:)
        @document = document
        @profile = profile
        @walker = walker
      end

      def structural_facts
        @structural_facts ||= begin
          out = STRUCTURAL_KEYS.to_h { |key| [key, []] }
          walk do |node, stack|
            @profile.structural_facts_for_node(@document, node, stack).each do |key, values|
              out.fetch(key).concat(values)
            end
          end
          dedupe_structural_facts!(out)
        end
      end

      def decision_sites
        @decision_sites ||= collect_node_facts { |node, stack| @profile.decision_site_facts(@document, node, stack) }
      end

      def branch_arms
        @branch_arms ||= collect_node_facts { |node, stack| @profile.branch_arm_facts(@document, node, stack) }
      end

      def predicate_defs
        @predicate_defs ||= structural_facts.fetch(:function_defs).filter_map do |function_def|
          @profile.predicate_def(@document, function_def)
        end
      end

      def comparison_sites
        @comparison_sites ||= collect_node_facts { |node, stack| @profile.comparison_site_facts(@document, node, stack) }
      end

      def local_methods
        @local_methods ||= @profile.local_methods(@document)
      end

      def path_condition_sites
        @path_condition_sites ||= @profile.path_condition_sites(@document)
      end

      private

      def collect_node_facts
        out = []
        walk { |node, stack| out.concat(yield(node, stack)) }
        out
      end

      def walk(&block)
        @walker.call(@document, @profile, &block)
      end

      def dedupe_structural_facts!(out)
        out[:function_defs].uniq! { |fn| [fn.file, fn.owner, fn.name, fn.line] }
        out[:owner_defs].uniq! { |owner| [owner.file, owner.name, owner.kind] }
        out[:call_sites].uniq! { |call| [call.file, call.owner, call.function, call.span, call.receiver, call.message] }
        out[:state_declarations].uniq! { |decl| [decl.file, decl.owner, decl.field] }
        out[:state_param_origins].uniq! { |origin| [origin.file, origin.owner, origin.function, origin.field, origin.param] }
        out[:state_reads].uniq! { |read| [read.file, read.owner, read.function, read.span, read.receiver, read.field] }
        out[:state_writes].uniq! { |write| [write.file, write.owner, write.function, write.span, write.receiver, write.field] }
        out
      end
    end

    class StatefulSyntaxPass
      def initialize(document:, profile:, stateless_pass:, walker:)
        @document = document
        @profile = profile
        @stateless_pass = stateless_pass
        @walker = walker
      end

      def structural_facts
        @structural_facts ||= begin
          out = duplicate_facts(@stateless_pass.structural_facts)
          apply_implicit_state_accesses!(out)
          apply_visibility_events!(out)
          dedupe_structural_facts!(out)
        end
      end

      def branch_decisions(immutable_readers:, immutable_reader_types:, type_aliases:)
        out = []
        walk do |node, stack|
          out.concat(@profile.branch_decision_facts(
            @document,
            node,
            stack,
            immutable_readers: immutable_readers,
            immutable_reader_types: immutable_reader_types,
            type_aliases: type_aliases
          ))
        end
        out
      end

      def immutable_struct_readers
        @immutable_struct_readers ||= @profile.immutable_struct_readers(@document)
      end

      def immutable_struct_reader_types
        @immutable_struct_reader_types ||= @profile.immutable_struct_reader_types(@document)
      end

      def type_aliases
        @type_aliases ||= @profile.type_aliases(@document)
      end

      private

      def duplicate_facts(facts)
        facts.transform_values do |values|
          values.map { |value| value.respond_to?(:dup) ? value.dup : value }
        end
      end

      def apply_implicit_state_accesses!(out)
        return unless @profile.implicit_state_accesses?

        @profile.__send__(:record_implicit_state_accesses, @document, out)
      end

      def apply_visibility_events!(out)
        events_by_owner = Array(@profile.visibility_events(@document, out)).group_by(&:owner)
        out.fetch(:function_defs).group_by(&:owner).each do |owner, functions|
          visibility = :public
          events = visibility_timeline(functions, events_by_owner.fetch(owner, []))

          events.each do |event|
            if event.is_a?(FunctionDef)
              event.visibility ||= event.name.to_s.include?(".") ? :public : visibility
            elsif event.target_names.to_a.empty?
              visibility = event.visibility
            else
              apply_targeted_visibility!(functions, event)
            end
          end
        end
      end

      def visibility_timeline(functions, visibility_events)
        (functions + visibility_events).sort_by do |event|
          [event.line, event.is_a?(VisibilityEvent) ? 0 : 1]
        end
      end

      def apply_targeted_visibility!(functions, event)
        event.target_names.to_a.each do |name|
          functions.reverse_each do |function|
            next unless function.name.to_s == name.to_s

            function.visibility = event.visibility
            break
          end
        end
      end

      def walk(&block)
        @walker.call(@document, @profile, &block)
      end

      def dedupe_structural_facts!(out)
        out[:function_defs].uniq! { |fn| [fn.file, fn.owner, fn.name, fn.line] }
        out[:owner_defs].uniq! { |owner| [owner.file, owner.name, owner.kind] }
        out[:call_sites].uniq! { |call| [call.file, call.owner, call.function, call.span, call.receiver, call.message] }
        out[:state_declarations].uniq! { |decl| [decl.file, decl.owner, decl.field] }
        out[:state_param_origins].uniq! { |origin| [origin.file, origin.owner, origin.function, origin.field, origin.param] }
        out[:state_reads].uniq! { |read| [read.file, read.owner, read.function, read.span, read.receiver, read.field] }
        out[:state_writes].uniq! { |write| [write.file, write.owner, write.function, write.span, write.receiver, write.field] }
        out
      end
    end

    class NormalizedStatefulSyntaxPass
      def self.enrich(row, language:, file:, source:, lines:)
        new(row, language: language, file: file, source: source, lines: lines).enrich
      end

      def initialize(row, language:, file:, source:, lines:)
        @row = row
        @language = language.to_sym
        @file = file
        @source = source
        @lines = lines
        @profile = Syntax.language_profile(@language)
        @behavior = Syntax::NormalizedExtractionBehavior.for(@language)
      end

      def enrich
        apply_visibility_events!
        append_effects_from_calls!
        dedupe_semantic_effects!
        append_protocol_facts!
        append_normalized_local_facts!
        append_normalized_extension_facts!
        append_profile_metadata!
        @row
      end

      private

      def apply_visibility_events!
        events_by_owner = Array(@behavior.visibility_events_from_calls(calls)).group_by do |event|
          event.fetch(:owner).to_s
        end

        functions.group_by { |function| function.fetch("owner").to_s }.each do |owner, owner_functions|
          current_visibility = "public"
          events = visibility_timeline(owner_functions, events_by_owner.fetch(owner, []))

          events.each do |event|
            if event.key?(:function)
              function = event.fetch(:function)
              if function.fetch("visibility") == "public"
                function["visibility"] = function.fetch("name").to_s.include?(".") ? "public" : current_visibility
              end
            elsif event.fetch(:target_names).empty?
              current_visibility = event.fetch(:visibility).to_s
            else
              apply_targeted_visibility!(owner_functions, event)
            end
          end
        end
      end

      def visibility_timeline(owner_functions, visibility_events)
        function_events = owner_functions.map { |function| { function: function, line: function.fetch("line"), order: 1 } }
        visibility_events.map { |event| event.merge(line: event.fetch(:line), order: 0) }
                         .concat(function_events)
                         .sort_by { |event| [event.fetch(:line).to_i, event.fetch(:order).to_i] }
      end

      def apply_targeted_visibility!(owner_functions, event)
        event.fetch(:target_names).each do |name|
          owner_functions.reverse_each do |function|
            next unless function.fetch("name").to_s == name.to_s

            function["visibility"] = event.fetch(:visibility).to_s
            break
          end
        end
      end

      def append_effects_from_calls!
        document = OpenStruct.new(
          language: @language,
          function_defs: object_rows("functions"),
          call_sites: calls.map { |call| OpenStruct.new(call.transform_keys(&:to_sym)) }
        )
        @profile.semantic_effect_sites(document).each do |effect|
          semantic_effects << effect.to_h.transform_keys(&:to_s)
        end
      end

      def dedupe_semantic_effects!
        seen = {}
        @row["semantic_effects"] = semantic_effects.select do |effect|
          key = effect.values_at("kind", "detail", "function", "line", "span")
          next false if seen[key]

          seen[key] = true
        end.sort_by { |effect| effect.values_at("kind", "detail", "function", "line", "span").map(&:to_s) }
      end

      def append_profile_metadata!
        document = OpenStruct.new(file: @file, language: @language, source: @source, lines: @lines)
        @row["immutable_struct_readers"] = @profile.immutable_struct_readers(document)
        @row["immutable_struct_reader_types"] = @profile.immutable_struct_reader_types(document)
        @row["type_aliases"] = @profile.type_aliases(document)
        @row["method_param_types"] = @profile.__send__(:method_param_types, document)
      end

      def append_protocol_facts!
        document = fact_document_view
        @row["protocol_method_effects"] = @profile.protocol_method_effects(document).map do |effect|
          effect.to_h.transform_keys(&:to_s)
        end
        @row["protocol_call_paths"] = @profile.protocol_call_paths(document).map do |path|
          row = path.to_h.transform_keys(&:to_s)
          row["calls"] = row.fetch("calls").map { |call| call.to_h.transform_keys(&:to_s) }
          row
        end
      end

      def append_normalized_extension_facts!
        if Syntax.const_defined?(:CloneSimilarityAnalyzer, false)
          @row["clone_candidates"] = Syntax::CloneSimilarityAnalyzer.scan_normalized_row(@row)
        end
        if Syntax.const_defined?(:NilGuardAnalyzer, false)
          @row["redundant_nil_guards"] = Syntax::NilGuardAnalyzer.scan_normalized_row(@row)
        end
      end

      def append_normalized_local_facts!
        return unless Syntax.const_defined?(:NormalizedLocalFactsAnalyzer, false)

        facts = Syntax::NormalizedLocalFactsAnalyzer.analyze(@row, language: @language, file: @file, lines: @lines)
        @row["local_methods"] = facts.fetch("local_methods")
        @row["path_conditions"] = facts.fetch("path_conditions")
        @row["local_complexity_scores"] = facts.fetch("local_complexity_scores")
        @row["local_contract_assignments"] = facts.fetch("local_contract_assignments")
      end

      def fact_document_view
        OpenStruct.new(
          language: @language,
          function_defs: object_rows("functions"),
          state_reads: object_rows("state_reads"),
          state_writes: object_rows("state_writes"),
          call_sites: object_rows("calls")
        )
      end

      def object_rows(key)
        @row.fetch(key).map { |row| OpenStruct.new(row.transform_keys(&:to_sym)) }
      end

      def functions
        @row.fetch("functions")
      end

      def calls
        @row.fetch("calls")
      end

      def semantic_effects
        @row.fetch("semantic_effects")
      end
    end
  end
end
