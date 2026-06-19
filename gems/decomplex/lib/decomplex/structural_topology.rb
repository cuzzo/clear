# frozen_string_literal: true

require_relative "syntax"

module Decomplex
  # StructuralTopology is Decomplex's conservative static model of method
  # ownership and direct internal calls over Syntax structural facts. It
  # deliberately resolves only same-owner bare/self calls; dynamic dispatch
  # belongs to higher-recall detectors.
  class StructuralTopology
    Method = Struct.new(:id, :owner, :name, :file, :line, :span, :visibility, keyword_init: true)
    Edge = Struct.new(
      :caller, :callee, :caller_name, :callee_name, :file, :line, :span, :type, :kind, :confidence,
      keyword_init: true
    )

    def self.scan(files)
      documents = files.to_h do |file|
        [file, Syntax.parse(file, parser: "tree_sitter")]
      end

      methods = documents.flat_map do |file, document|
        MethodFacts.new(file, document).methods
      end
      edges = documents.flat_map do |file, document|
        EdgeFacts.new(file, document, methods).edges
      end
      edges.uniq! { |edge| [edge.caller, edge.callee, edge.type] }

      Graph.new(methods, edges)
    end

    class Graph
      attr_reader :methods, :edges

      def initialize(methods, edges)
        @methods = methods
        @edges = edges
        @method_by_id = methods.to_h { |method| [method.id, method] }
        @methods_by_owner = methods.group_by(&:owner)
        @edges_by_caller = edges.group_by(&:caller)
        @edges_by_callee = edges.group_by(&:callee)
        @edges_by_owner = edges.group_by { |edge| method(edge.caller)&.owner }
      end

      def method(id)
        @method_by_id[id]
      end

      def method_id(owner, name)
        "#{owner}##{name}"
      end

      def method_for(owner, name)
        method(method_id(owner, name))
      end

      def methods_for_owner(owner)
        Array(@methods_by_owner[owner])
      end

      def edges_for_owner(owner)
        Array(@edges_by_owner[owner])
      end

      def internal_calls(id)
        Array(@edges_by_caller[id])
      end

      def internal_callers(id)
        Array(@edges_by_callee[id])
      end

      def single_internal_caller?(id)
        internal_callers(id).map(&:caller).uniq.size == 1
      end

      def visibility(id)
        method(id)&.visibility
      end

      def owner(id)
        method(id)&.owner
      end

      def span(id)
        method(id)&.span
      end

      def call_sites(id)
        internal_calls(id).map do |edge|
          "#{edge.file}:#{edge.caller_name}:#{edge.line}"
        end
      end
    end

    class MethodFacts
      def initialize(file, document)
        @file = file
        @document = document
      end

      def methods
        @document.function_defs.map do |function|
          owner = owner_for_fact(function)
          Method.new(
            id: "#{owner}##{function.name}",
            owner: owner,
            name: function.name,
            file: @file,
            line: function.line,
            span: function.span,
            visibility: function.visibility || :public
          )
        end
      end

      private

      def owner_for_fact(fact)
        TopLevelOwner.new(@file, @document).owner_for(fact)
      end
    end

    class EdgeFacts
      def initialize(file, document, methods)
        @file = file
        @document = document
        @method_by_id = methods.to_h { |method| [method.id, method] }
        @owner_mapper = TopLevelOwner.new(file, document)
      end

      def edges
        @document.call_sites.filter_map do |call|
          edge_for_call(call)
        end
      end

      private

      def edge_for_call(call)
        return nil unless call.receiver.to_s == "self"

        owner = @owner_mapper.owner_for(call)
        caller = @method_by_id["#{owner}##{call.function}"]
        return nil unless caller

        callee_name = scoped_name(caller, call.message)
        callee = @method_by_id["#{owner}##{callee_name}"]
        return nil unless callee
        return nil if caller.id == callee.id

        Edge.new(
          caller: caller.id,
          callee: callee.id,
          caller_name: caller.name,
          callee_name: callee.name,
          file: @file,
          line: call.line,
          span: call.span,
          type: edge_type(call.control),
          kind: call_kind(call),
          confidence: :high
        )
      end

      def scoped_name(caller, message)
        caller.name.to_s.start_with?("self.") ? "self.#{message}" : message.to_s
      end

      def edge_type(control)
        %i[conditional iterates].include?(control) ? control : :always
      end

      def call_kind(call)
        source_text(call.span).lstrip.start_with?("self.") ? :direct_self : :bare_internal
      end

      def source_text(span)
        return "" unless span

        first_line, first_column, last_line, last_column = span
        if first_line == last_line
          return @document.lines[first_line - 1].to_s[first_column...last_column].to_s
        end

        parts = []
        parts << @document.lines[first_line - 1].to_s[first_column..].to_s
        parts.concat(@document.lines[first_line...(last_line - 1)] || [])
        parts << @document.lines[last_line - 1].to_s[0...last_column].to_s
        parts.join
      end
    end

    class TopLevelOwner
      def initialize(file, document)
        @file = file
        @document = document
      end

      def owner_for(fact)
        owner = fact.owner.to_s
        return owner unless owner == file_owner
        return owner if enclosed_by_matching_owner?(fact)

        top_level_owner
      end

      private

      def enclosed_by_matching_owner?(fact)
        @document.owner_defs.any? do |owner|
          owner.name.to_s == fact.owner.to_s && encloses?(owner.span, fact.span)
        end
      end

      def encloses?(outer, inner)
        return false unless outer && inner

        starts_before = outer[0] < inner[0] || (outer[0] == inner[0] && outer[1] <= inner[1])
        ends_after = outer[2] > inner[2] || (outer[2] == inner[2] && outer[3] >= inner[3])
        starts_before && ends_after
      end

      def file_owner
        File.basename(@file.to_s, File.extname(@file.to_s))
      end

      def top_level_owner
        "(top-level:#{@file})"
      end
    end
  end
end
