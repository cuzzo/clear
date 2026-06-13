# frozen_string_literal: true

require "prism"
require "set"

begin
  require "decomplex/syntax"
rescue LoadError
  require_relative "../../../decomplex/lib/decomplex/syntax"
end

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
      return TreeSitterStructuralExtractor.new(file_path).extract if tree_sitter_source?

      result = Prism.parse_file(file_path)
      return [] unless result.success?

      visitor = StructuralVisitor.new(file_path)
      result.value.accept(visitor)
      visitor.modules
    end

    private

    def tree_sitter_source?
      parser = ENV.fetch("ESPALIER_PARSER", ENV.fetch("DECOMPLEX_PARSER", "")).to_s.tr("-", "_")
      return true if %w[tree_sitter treesitter].include?(parser)
      return false if File.extname(file_path).downcase == ".rb"

      Decomplex::Syntax.supported_source?(file_path, parser: "tree_sitter")
    end

    class TreeSitterStructuralExtractor
      STATE_RECEIVER_PATTERN = /\A@[A-Za-z_]\w*(?:\.|\z)/

      def initialize(file_path)
        @file_path = file_path
      end

      def extract
        doc = Decomplex::Syntax.parse(@file_path, parser: "tree_sitter")
        facts = doc.adapter.structural_facts(doc)
        modules = build_modules(doc, facts)
        modules.values.sort_by { |mod| [mod[:file].to_s, mod[:name].to_s] }
      end

      private

      def build_modules(doc, facts)
        modules = {}
        owner_kinds = facts[:owner_defs].to_h { |owner| [owner.name.to_s, owner.kind] }
        method_names = facts[:function_defs].each_with_object(Hash.new { |h, k| h[k] = Set.new }) do |fn, index|
          index[owner_name(doc, fn.owner)].add(fn.name.to_s)
        end
        declared_states = facts[:state_declarations].each_with_object(Hash.new { |h, k| h[k] = Set.new }) do |state, index|
          index[state.owner.to_s].add(state.field.to_s)
        end

        facts[:function_defs].each do |fn|
          owner = owner_name(doc, fn.owner)
          mod = module_for(modules, owner, doc, owner_kinds[owner])
          method = {
            name: fn.name.to_s,
            signature: fn.signature.to_s.empty? ? fn.name.to_s : fn.signature.to_s,
            parameters: Array(fn.params).map(&:to_s),
            visibility: fn.visibility || :public,
            line: fn.line,
            span: fn.span,
            effects: { reads: Set.new, writes: Set.new },
            delegations: []
          }
          mod[:methods] << method
        end

        facts[:state_declarations].each do |state|
          mod = module_for(modules, state.owner.to_s, doc, owner_kinds[state.owner.to_s])
          mod[:states] << state.field.to_s
          mod[:ivar_types][state.field.to_s] = state.type.to_s unless state.type.to_s.empty?
        end

        methods_by_owner_name = modules.transform_values do |mod|
          mod[:methods].to_h { |method| [method[:name].to_s, method] }
        end

        facts[:state_reads].each do |read|
          owner = owner_name(doc, read.owner)
          next unless state_fact?(read, declared_states[owner])
          next if method_names[owner].include?(read.field.to_s) && receiver_self_like?(read.receiver)

          mod = module_for(modules, owner, doc, owner_kinds[owner])
          method = methods_by_owner_name.dig(owner, read.function.to_s)
          next unless method

          mod[:states] << read.field.to_s
          method[:effects][:reads] << read.field.to_s
        end

        facts[:state_writes].each do |write|
          owner = owner_name(doc, write.owner)
          next unless state_fact?(write, declared_states[owner])

          mod = module_for(modules, owner, doc, owner_kinds[owner])
          method = methods_by_owner_name.dig(owner, write.function.to_s)
          next unless method

          mod[:states] << write.field.to_s
          method[:effects][:writes] << write.field.to_s
        end

        facts[:call_sites].each do |call|
          owner = owner_name(doc, call.owner)
          method = methods_by_owner_name.dig(owner, call.function.to_s)
          next unless method

          method[:delegations] << {
            receiver: delegation_receiver(call.receiver),
            message: call.message.to_s,
            type: call.conditional ? :conditional : :always
          }
        end

        modules.each_value do |mod|
          mod[:states] = mod[:states].to_set
          mod[:methods].each do |method|
            method[:delegations].uniq!
          end
        end
        modules
      end

      def module_for(modules, owner, doc, kind)
        modules[owner] ||= {
          type: module_type(kind, owner, doc),
          name: owner,
          file: @file_path,
          language: doc.language,
          states: Set.new,
          ivar_types: {},
          methods: []
        }
      end

      def owner_name(doc, owner)
        text = owner.to_s
        text.empty? ? File.basename(doc.file, File.extname(doc.file)) : text
      end

      def module_type(kind, owner, doc)
        return kind if kind && kind != :owner
        return :file if owner == File.basename(doc.file, File.extname(doc.file))

        :container
      end

      def state_fact?(fact, declared)
        receiver = fact.receiver.to_s
        return declared.include?(fact.field.to_s) if receiver == ".literal"
        return true if receiver_self_like?(receiver)
        return true if receiver.match?(STATE_RECEIVER_PATTERN)
        return false if receiver.start_with?("self.", "this.")

        false
      end

      def receiver_self_like?(receiver)
        %w[self this].include?(receiver.to_s)
      end

      def delegation_receiver(receiver)
        text = receiver.to_s.sub(/\A\*/, "")
        return "self" if text == "this"

        text.empty? ? "self" : text
      end
    end

    class StructuralVisitor < Prism::Visitor
      attr_reader :modules

      def initialize(file_path)
        @file_path = file_path
        @modules = []
        @namespace_stack = []
        @current_class = nil
        @current_method = nil
        @current_visibility = :public
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
        outer_visibility = @current_visibility
        @current_visibility = :public
        super
        @current_visibility = outer_visibility
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
        outer_visibility = @current_visibility
        @current_visibility = :public
        super
        @current_visibility = outer_visibility
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
          visibility: node.receiver ? :public : @current_visibility,
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
        if @current_class && @current_method.nil? && visibility_directive?(node)
          handle_visibility_directive(node)
          return
        end

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

      def visibility_directive?(node)
        node.receiver.nil? && %i[private protected public].include?(node.name)
      end

      def handle_visibility_directive(node)
        visibility = node.name.to_sym
        args = node.arguments&.arguments || []
        if args.empty?
          @current_visibility = visibility
          return
        end

        args.each do |arg|
          if arg.is_a?(Prism::DefNode)
            with_visibility(visibility) { arg.accept(self) }
          elsif (name = literal_method_name(arg))
            set_existing_method_visibility(name, visibility)
          else
            arg.accept(self)
          end
        end
      end

      def with_visibility(visibility)
        old_visibility = @current_visibility
        @current_visibility = visibility
        yield
      ensure
        @current_visibility = old_visibility
      end

      def literal_method_name(node)
        return node.value.to_s if node.is_a?(Prism::SymbolNode)
        return node.value.to_s if node.is_a?(Prism::StringNode)

        nil
      end

      def set_existing_method_visibility(method_name, visibility)
        return unless @current_class

        method = @current_class[:methods].reverse.find { |m| m[:name] == method_name }
        method[:visibility] = visibility if method
      end

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
