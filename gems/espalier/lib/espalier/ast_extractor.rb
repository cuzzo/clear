# frozen_string_literal: true

require "prism"

module Espalier
  # Extracts the structural skeleton, state instance variables, and call delegation
  # nodes from Ruby source files, using modern compiler-grade Prism AST.
  class AstExtractor
    attr_reader :file_path

    def initialize(file_path)
      @file_path = file_path
    end

    # Return structure: List of classes/modules with states & methods.
    def extract
      result = Prism.parse_file(file_path)
      return [] unless result.success?

      visitor = StructuralVisitor.new(file_path)
      result.value.accept(visitor)
      visitor.modules
    end

    class StructuralVisitor < Prism::Visitor
      attr_reader :modules

      def initialize(file_path)
        @file_path = file_path
        @modules = []
        @namespace_stack = []
        @current_class = nil
        @current_method = nil
        @context_stack = [] # Stack of :conditional, :iterates, etc.
      end

      # Scope Trackers
      def visit_class_node(node)
        name = node.constant_path.slice
        full_name = (@namespace_stack + [name]).join("::")
        
        outer_class = @current_class
        @current_class = {
          type: :class,
          name: full_name,
          file: @file_path,
          states: Set.new,
          ivar_types: {}, # Maps @ivar => type_string extracted statically or dynamically
          methods: []
        }
        @modules << @current_class

        @namespace_stack.push(name)
        super
        @namespace_stack.pop

        @current_class = outer_class
      end

      def visit_module_node(node)
        name = node.constant_path.slice
        full_name = (@namespace_stack + [name]).join("::")

        outer_class = @current_class
        @current_class = {
          type: :module,
          name: full_name,
          file: @file_path,
          states: Set.new,
          ivar_types: {}, # Maps @ivar => type_string extracted statically or dynamically
          methods: []
        }
        @modules << @current_class

        @namespace_stack.push(name)
        super
        @namespace_stack.pop

        @current_class = outer_class
      end

      # Context Node overrides to track control structures
      def visit_if_node(node)
        @context_stack.push(:conditional)
        # We need to custom visit children because some nodes in the condition (like item.valid?) shouldn't be conditional
        node.predicate.accept(self)
        
        # Then, block nodes inside statements are conditional
        @context_stack.push(:conditional)
        node.statements&.accept(self)
        @context_stack.pop
        
        node.subsequent&.accept(self)
        @context_stack.pop
      end

      # We can also intercept BlockNode/Blockpass/IterArg to push iterates context
      def visit_block_node(node)
        @context_stack.push(:iterates)
        super
        @context_stack.pop
      end

      def visit_unless_node(node)
        @context_stack.push(:conditional)
        super
        @context_stack.pop
      end

      def visit_ternary_node(node)
        @context_stack.push(:conditional)
        super
        @context_stack.pop
      end

      def visit_while_node(node)
        @context_stack.push(:iterates)
        super
        @context_stack.pop
      end

      def visit_until_node(node)
        @context_stack.push(:iterates)
        super
        @context_stack.pop
      end

      def visit_for_node(node)
        @context_stack.push(:iterates)
        super
        @context_stack.pop
      end

      # Method Trackers
      def visit_def_node(node)
        # Handle top-level or class defs
        mtd_name = node.name.to_s
        mtd_name = "self.#{mtd_name}" if node.receiver

        # Safe fallback signature
        sig = "def #{mtd_name}"
        params = []
        if node.parameters
          params_str = node.parameters.slice
          sig += "(#{params_str})" unless params_str.empty?
          params = parse_params(node.parameters)
        end

        outer_method = @current_method
        @current_method = {
          name: mtd_name,
          signature: sig,
          parameters: params,
          effects: { reads: Set.new, writes: Set.new },
          delegations: []
        }

        # Let child nodes populate the state and delegation fields
        super

        if @current_class
          # Move instance variables up to the class state list
          all_mutated = @current_method[:effects][:writes] + @current_method[:effects][:reads]
          @current_class[:states].merge(all_mutated)
          @current_class[:methods] << @current_method
        end

        @current_method = outer_method
      end

      # Instance variable writes (writes to state)
      def visit_instance_variable_write_node(node)
        var_name = node.name.to_s
        if @current_method
          @current_method[:effects][:writes] << var_name
          
          # If we capture a T.let layout statically on assignment
          # example: @flag = T.let(false, T::Boolean)
          # We can extract the class signature info directly from the right-hand value
          if node.value.is_a?(Prism::CallNode) && node.value.name == :let && node.value.receiver&.slice == "T"
            args = node.value.arguments&.arguments
            if args && args.size >= 2
              type_slice = args[1].slice
              @current_class[:ivar_types] ||= {}
              @current_class[:ivar_types][var_name] = type_slice
            end
          end
        end
        super
      end

      def visit_instance_variable_operator_write_node(node)
        var_name = node.name.to_s
        if @current_method
          @current_method[:effects][:writes] << var_name
        end
        super
      end

      def visit_instance_variable_and_write_node(node)
        var_name = node.name.to_s
        if @current_method
          @current_method[:effects][:writes] << var_name
        end
        super
      end

      def visit_instance_variable_or_write_node(node)
        var_name = node.name.to_s
        if @current_method
          @current_method[:effects][:writes] << var_name
        end
        super
      end

      # Instance variable reads (reads from state)
      def visit_instance_variable_read_node(node)
        var_name = node.name.to_s
        if @current_method
          # Prevent registering as read if it is also a write inside operator assigns
          unless @current_method[:effects][:writes].include?(var_name)
            @current_method[:effects][:reads] << var_name
          end
        end
        super
      end

      # Call delegation collections
      def visit_call_node(node)
        return super unless @current_method

        msg = node.name.to_s
        recv = node.receiver ? node.receiver.slice : "self"

        # 1. Cleanly ignore complete block structures or long multi-line lambda text blocks
        # if the receiver or arguments contain complex multiline slices, we do not want to record
        # them as single raw-string calls.
        if msg.include?("\n") || recv.include?("\n")
          return super
        end

        # 2. Check if this is a Sorbet-runtime signature or utility namespace reference
        # Eliminates "T.any", "T::Hash", "T.nilable", "T.must", "T.unsafe", etc.
        # Clean logical check: if receiver starts with T/T:: or is a generic T type helper
        if recv == "T" || recv.start_with?("T::") || recv == "Sorbet"
          return super
        end

        # 3. Filter logging, core collection primitives, and standard language operator names
        ignored_selectors = %w[
          to_s to_i class hash inspect nil? present? empty? == != === < > <= >= + - * / && ||
          last first sort compact uniq map flat_map size length each keys values any? all? none?
          select find find_all map! map_with_index each_with_index reject reject! include? include
          keys values fetch dig puts raise p warn print tap block_given? respond_to? is_a?
          let must unsafe cast bind type_as zip flatten compact! index find_index
        ]

        unless ignored_selectors.include?(msg)
          delegation = determine_delegation_context(node, recv, msg)
          @current_method[:delegations] << delegation
        end
        super
      end

      private

      def parse_params(node)
        # Extracts simple names of params
        names = []
        node.requireds.each { |r| names << r.name.to_s } if node.respond_to?(:requireds)
        node.optionateds.each { |o| names << o.name.to_s } if node.respond_to?(:optionateds)
        node.keywords.each { |k| names << k.name.to_s } if node.respond_to?(:keywords)
        names
      end

      def determine_delegation_context(node, receiver, message)
        # Determine if call layout is conditional or interactive
        context = @context_stack.last || :always

        {
          receiver: receiver,
          message: message,
          type: context
        }
      end
    end
  end
end
