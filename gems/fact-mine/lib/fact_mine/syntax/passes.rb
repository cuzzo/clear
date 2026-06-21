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
  end
end
