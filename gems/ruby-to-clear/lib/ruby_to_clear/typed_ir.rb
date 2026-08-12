# frozen_string_literal: true

require_relative "cfg_facts"

module RubyToClear
  # Semantic facts shared by resolution, flow typing, closure analysis, and
  # emission. The first migration slice records facts for calls and fields;
  # later slices can replace the legacy expression nodes without changing the
  # contract consumed by the emitter.
  module TypedIR
    class ValidationError < StandardError; end

    SymbolId = Struct.new(:owner, :kind, :name, keyword_init: true) do
      def initialize(owner:, kind:, name:)
        super(owner: owner.to_s, kind: kind.to_sym, name: name.to_s)
        freeze
      end

      def to_s
        [owner, kind, name].join(":")
      end
    end

    TypeRef = Struct.new(:name, :optional, :capability, keyword_init: true) do
      def self.parse(value)
        text = value.to_s
        optional = text.start_with?("?")
        text = text.delete_prefix("?")
        base, capability = text.split("@", 2)
        new(name: base.to_s, optional: optional, capability: capability)
      end

      def initialize(name:, optional: false, capability: nil)
        super(name: name.to_s, optional: !!optional, capability: capability&.to_s)
        freeze
      end

      def unknown?
        name.empty? || name == "Unknown"
      end

      def dynamic?
        %w[Any Auto].include?(name)
      end

      def unresolved?
        unknown? || dynamic?
      end

      def implicitly_copyable?
        return false if optional
        return true if to_clear == "String@symbol"

        name.match?(/\A(?:Bool|U?Int\d*|Float\d*|Byte\d*|Void|Nil)\z/)
      end

      def requires_statement_result_lowering?
        !unresolved? && !implicitly_copyable?
      end

      def narrow_non_nil
        self.class.new(name: name, optional: false, capability: capability)
      end

      def to_clear
        prefix = optional ? "?" : ""
        suffix = capability ? "@#{capability}" : ""
        "#{prefix}#{name}#{suffix}"
      end
    end

    ValueInfo = Struct.new(
      :type, :category, :access, :copyable, :source_location,
      keyword_init: true
    ) do
      def initialize(type:, category: :value, access: :owned, copyable: false, source_location: nil)
        super(
          type: type.is_a?(TypeRef) ? type : TypeRef.parse(type),
          category: category.to_sym,
          access: access.to_sym,
          copyable: !!copyable,
          source_location: source_location
        )
        freeze
      end
    end

    OwnershipEdge = Struct.new(:mode, :source, :destination, keyword_init: true) do
      MODES = %i[borrow borrow_mut copy retain move].freeze

      def initialize(mode:, source:, destination:)
        normalized = mode.to_sym
        raise ValidationError, "unknown ownership mode #{mode.inspect}" unless MODES.include?(normalized)

        super(mode: normalized, source: source, destination: destination)
        freeze
      end
    end

    ResolvedCall = Struct.new(
      :target, :dispatch, :receiver_type, :return_type, :receiver_ownership,
      :argument_ownership, :result_type_identity,
      keyword_init: true
    ) do
      def initialize(target:, dispatch:, receiver_type: nil, return_type: nil,
                     receiver_ownership: :borrow, argument_ownership: [], result_type_identity: nil)
        super(
          target: target,
          dispatch: dispatch.to_sym,
          receiver_type: receiver_type && (receiver_type.is_a?(TypeRef) ? receiver_type : TypeRef.parse(receiver_type)),
          return_type: return_type && (return_type.is_a?(TypeRef) ? return_type : TypeRef.parse(return_type)),
          receiver_ownership: receiver_ownership.to_sym,
          argument_ownership: argument_ownership.freeze,
          result_type_identity: result_type_identity&.to_s
        )
        freeze
      end
    end

    FieldAccess = Struct.new(:field, :receiver_type, :field_type, :write, keyword_init: true) do
      def initialize(field:, receiver_type:, field_type:, write: false)
        super(
          field: field,
          receiver_type: receiver_type.is_a?(TypeRef) ? receiver_type : TypeRef.parse(receiver_type),
          field_type: field_type.is_a?(TypeRef) ? field_type : TypeRef.parse(field_type),
          write: !!write
        )
        freeze
      end
    end

    ClosureInfo = Struct.new(:parameters, :captures, :result_type, keyword_init: true) do
      def initialize(parameters:, captures:, result_type: nil)
        super(parameters: parameters.freeze, captures: captures.freeze, result_type: result_type)
        freeze
      end
    end

    Function = Struct.new(:symbol, :parameters, :return_type, :facts, keyword_init: true)

    class Program
      attr_reader :functions, :calls, :fields, :values, :closures, :storage_ownership,
                  :contextual_types

      def initialize(cfg_bundle: nil)
        @functions = {}
        @calls = {}
        @fields = {}
        @values = {}
        @closures = {}
        @storage_ownership = {}
        @contextual_types = {}
        @cfg_consumption = Hash.new(0)
        @cfg_bundle = cfg_bundle || CfgFacts::Bundle.new(reason: "CFG facts were not supplied")
      end

      def analyze_function(host, node, owner:, parameter_types:, local_types:)
        analyzer = FunctionAnalyzer.new(
          host,
          self,
          owner: owner,
          parameter_types: parameter_types,
          local_types: local_types
        )
        admission = @cfg_bundle.admit_function(node, owner: owner)
        function = analyzer.analyze(node, admission: admission)
        @functions[node.object_id] = function
        function
      end

      def call_for(node)
        @calls[node.object_id]
      end

      def field_for(node)
        @fields[node.object_id]
      end

      def value_for(node)
        @values[node.object_id]
      end

      def closure_for(node)
        @closures[node.object_id]
      end

      def storage_ownership_for(node)
        @storage_ownership[node.object_id]
      end

      def contextual_type_for(node)
        @contextual_types[node.object_id]
      end

      def record_cfg_consumption(kind)
        @cfg_consumption[kind.to_s] += 1
      end

      def analysis_report
        function_rows = @functions.values.map do |function|
          admission = function.facts
          mapped_cfg_nodes = admission.node_by_prism_id.values.flatten.map { |node| node["id"] }.uniq
          {
            "owner" => function.symbol.owner,
            "name" => function.symbol.name,
            "kind" => function.symbol.kind.to_s,
            "admitted" => admission.complete,
            "reason" => admission.reason,
            "cfg_nodes" => admission.nodes.length,
            "mapped_cfg_nodes" => mapped_cfg_nodes.length
          }
        end.sort_by { |row| [row["owner"], row["name"], row["kind"]] }
        {
          "schema_version" => 1,
          "functions" => function_rows,
          "aggregate" => {
            "functions" => function_rows.length,
            "admitted_functions" => function_rows.count { |row| row["admitted"] },
            "rejected_functions" => function_rows.count { |row| !row["admitted"] },
            "resolved_calls" => @calls.length,
            "field_facts" => @fields.length,
            "ownership_edges" => @storage_ownership.length,
            "ownership_modes" => @storage_ownership.values.map(&:mode).tally.transform_keys(&:to_s),
            "cfg_consumption" => @cfg_consumption.sort.to_h
          }
        }
      end

      def validate!
        @calls.each_value do |call|
          raise ValidationError, "resolved call is missing a target" unless call.target.is_a?(SymbolId)
          raise ValidationError, "resolved call has an unknown receiver" if call.receiver_type&.unknown?
        end
        @fields.each_value do |field|
          raise ValidationError, "field access is missing a target" unless field.field.is_a?(SymbolId)
          raise ValidationError, "field access has an unknown receiver" if field.receiver_type.unknown?
        end
        true
      end
    end

    class FunctionAnalyzer
      PRIMITIVE_TYPES = %w[Bool Int64 Float64 Byte String@symbol Void].freeze

      def initialize(host, program, owner:, parameter_types:, local_types:)
        @host = host
        @program = program
        @owner = owner.to_s
        @initial_env = {}
        @owned_locals = Set.new
        @definition_types = {}
        @definition_access = {}
        parameter_types.merge(local_types).each do |name, type|
          record_env_type(@initial_env, name, type)
        end
      end

      def analyze(node, admission:)
        @admission = admission
        @local_read_offsets = collect_local_read_offsets(node.body)
        @instance_method = node.receiver.nil? && @owner != "Object"
        symbol = SymbolId.new(owner: @owner, kind: function_kind(node), name: node.name)
        analyze_node(node.parameters, @initial_env.dup, Set.new)
        analyze_node(node.body, @initial_env.dup, Set.new)
        Function.new(
          symbol: symbol,
          parameters: @initial_env.dup.freeze,
          return_type: method_return_type(node.name.to_s, @owner),
          facts: admission
        ).freeze
      end

      private

      def analyze_node(node, env, closure_scope)
        return TypeRef.new(name: "Void") unless node
        return TypeRef.new(name: "Unknown") if node.is_a?(Prism::DefNode)

        result = case node
        when Prism::StatementsNode
          analyze_statements(node, env, closure_scope)
        when Prism::LocalVariableWriteNode
          type = infer_type(node.value, env)
          analyze_node(node.value, env, closure_scope)
          value_info = @program.value_for(node.value)
          record_local_storage_ownership(node, value_info)
          materializes_owned = value_info&.access == :owned ||
            (value_info&.access == :borrowed &&
              host_call(:copyable_storage_type?, type.to_clear))
          if materializes_owned
            @owned_locals << node.name.to_s
          else
            @owned_locals.delete(node.name.to_s)
          end
          env[node.name.to_s] = type unless type.unknown?
          # A borrowed aggregate assignment is emitted with COPY and therefore
          # defines an owned local even though its source expression is a
          # borrow. Preserve that post-materialization access on the CFG
          # definition so later reads can move it instead of copying again.
          definition_access = materializes_owned ? :owned : value_info&.access
          record_definition(node, type, definition_access)
          type
        when Prism::LocalVariableReadNode
          local_read_type(node, env)
        when Prism::InstanceVariableReadNode
          record_instance_field(node, write: false)
        when Prism::InstanceVariableWriteNode
          analyze_node(node.value, env, closure_scope)
          record_instance_field(node, write: true)
        when Prism::IfNode
          analyze_if(node, env, closure_scope)
        when Prism::CallNode
          analyze_call(node, env, closure_scope)
        when Prism::BlockNode, Prism::LambdaNode
          analyze_closure(node, env)
          TypeRef.new(name: "Any")
        else
          node.child_nodes.each { |child| analyze_node(child, env, closure_scope) if child }
          infer_type(node, env)
        end
        record_value(node, result)
        result
      end

      def collect_local_read_offsets(node)
        offsets = Hash.new { |hash, name| hash[name] = [] }
        walk = lambda do |current|
          return unless current
          return if current.is_a?(Prism::DefNode)

          if current.is_a?(Prism::LocalVariableReadNode)
            offsets[current.name.to_s] << current.location.start_offset
          end
          current.child_nodes.each { |child| walk.call(child) if child }
        end
        walk.call(node)
        offsets
      end

      def record_local_storage_ownership(node, value_info)
        source_node = node.value
        return unless source_node.is_a?(Prism::LocalVariableReadNode)
        return unless value_info
        retains_identity = host_call(:retainable_ruby_identity_type?, value_info.type.to_clear)
        return unless value_info.access == :owned || retains_identity

        source_name = source_node.name.to_s
        cfg_node = @admission&.complete && @admission.cfg_node_for(node)
        used_later = if cfg_node
          @program.record_cfg_consumption(:liveness_ownership)
          @admission.live_out_at?(node, source_name)
        else
          @local_read_offsets[source_name].any? do |offset|
            offset > source_node.location.start_offset
          end
        end
        @program.storage_ownership[node.object_id] = OwnershipEdge.new(
          # A borrowed/external Ruby object is never ours to move merely
          # because this callee has reached its last local read. Owned locals
          # may move at last use; every other aliasing edge retains identity.
          mode: if retains_identity
            value_info.access == :owned && !used_later ? :move : :retain
          else
            used_later ? :copy : :move
          end,
          source: source_node.object_id,
          destination: SymbolId.new(owner: @owner, kind: :local, name: node.name)
        )
      end

      def record_instance_field(node, write:)
        field_name = node.name.to_s.delete_prefix("@")
        field_type = host_call(:class_instance_field_type, @owner, field_name) || "Any"
        fact = FieldAccess.new(
          field: SymbolId.new(owner: @owner, kind: :field, name: field_name),
          receiver_type: @owner,
          field_type: field_type,
          write: write
        )
        @program.fields[node.object_id] = fact
        fact.field_type
      end

      def analyze_statements(node, env, closure_scope)
        result = TypeRef.new(name: "Void")
        node.body.each { |statement| result = analyze_node(statement, env, closure_scope) }
        result
      end

      def analyze_if(node, env, closure_scope)
        analyze_node(node.predicate, env, closure_scope)
        true_env = env.dup
        false_env = env.dup
        apply_predicate_constraint(node.predicate, true_env, false_env)
        then_type = analyze_node(node.statements, true_env, closure_scope)
        else_type = analyze_node(node.consequent, false_env, closure_scope)
        merge_environments!(env, true_env, false_env)
        merge_types(then_type, else_type)
      end

      def analyze_call(node, env, closure_scope)
        analyze_node(node.receiver, env, closure_scope) if node.receiver
        (node.arguments&.arguments || []).each { |argument| analyze_node(argument, env, closure_scope) }

        if sorbet_cast?(node)
          arguments = node.arguments&.arguments || []
          if arguments.length >= 2
            target_type = host_call(:convert_sorbet_type, arguments[1])
            @program.contextual_types[arguments[0].object_id] = TypeRef.parse(target_type)
          end
        end

        receiver_type = infer_type(node.receiver, env)
        record_storage_ownership(node, receiver_type)
        fact = resolve_call(node, receiver_type)
        if fact.is_a?(FieldAccess)
          @program.fields[node.object_id] = fact
        elsif fact
          @program.calls[node.object_id] = fact
        end

        if node.block.is_a?(Prism::BlockNode)
          analyze_closure(node.block, env, receiver_type: receiver_type, method_name: node.name.to_s)
        elsif node.block
          analyze_node(node.block, env, closure_scope)
        end
        if fact.is_a?(FieldAccess)
          fact.field_type
        elsif fact&.return_type
          fact.return_type
        else
          infer_call_type(node, receiver_type)
        end
      end

      def record_storage_ownership(node, receiver_type)
        return unless %w[<< []=].include?(node.name.to_s)

        arguments = node.arguments&.arguments || []
        return unless node.name.to_s == "<<" ? arguments.length == 1 : arguments.length >= 2

        destination = @program.field_for(node.receiver)
        return unless destination

        container_type = receiver_type.to_clear.delete_prefix("?")
        element_type = host_call(:container_element_clear_type, container_type)
        element_type ||= host_call(:map_value_clear_type, container_type)
        element_type ||= container_type.delete_suffix("[]") if container_type.end_with?("[]")
        return unless element_type

        source_node = node.name.to_s == "<<" ? arguments.first : arguments.last
        source = @program.value_for(source_node)
        retained_element = host_call(:direct_retained_carrier_type?, element_type)
        source_name = source_node.name.to_s if source_node.is_a?(Prism::LocalVariableReadNode)
        source_live = if source_name && @admission&.complete && @admission.cfg_node_for(node)
          @program.record_cfg_consumption(:liveness_ownership)
          @admission.live_out_at?(node, source_name)
        elsif source_name
          @local_read_offsets[source_name].any? { |offset| offset > source_node.location.start_offset }
        else
          false
        end
        mode = if retained_element
          source&.access == :owned && !source_live ? :move : :retain
        elsif source&.access == :borrowed || host_call(:aggregate_storage_copy_required?, element_type)
          :copy
        else
          :move
        end
        @program.storage_ownership[node.object_id] = OwnershipEdge.new(
          mode: mode,
          source: source_node.object_id,
          destination: destination.field
        )
      end

      def analyze_closure(block, outer_env, receiver_type: nil, method_name: nil)
        params = block_parameter_names(block)
        block_env = outer_env.dup
        block_types = block_parameter_types(receiver_type, params.length, method_name: method_name)
        block_types = params.each_with_index.map do |name, index|
          type = block_types[index]
          if !type || type.unresolved?
            structural_block_parameter_type(block.body, name) || type
          else
            type
          end
        end
        params.each_with_index do |name, index|
          block_env[name] = block_types[index] || TypeRef.new(name: "Unknown")
        end

        reads = Set.new
        writes = Set.new
        collect_closure_uses(block.body, params.to_set, reads, writes)
        captures = reads.filter_map do |name|
          next unless outer_env.key?(name)

          mode = writes.include?(name) ? :borrow_mut : :borrow
          [name, mode]
        end.to_h
        uses_self, mutates_self = closure_instance_context(block.body)
        captures["self"] = mutates_self ? :borrow_mut : :borrow if @instance_method && uses_self
        result = analyze_node(block.body, block_env, params.to_set)
        @program.closures[block.object_id] = ClosureInfo.new(
          parameters: params.zip(block_types).to_h,
          captures: captures,
          result_type: result
        )
      end

      # A closure stored in a registry/hash often has no call-site receiver from
      # which to recover its parameter contract. Preserve the constraints that
      # are explicit in its body instead of asking CLEAR to rediscover them.
      # Numeric `param[index]` use proves a sequential collection, even when the
      # element type remains dynamic.
      def structural_block_parameter_type(body, parameter_name)
        indexed = false
        walk = lambda do |node|
          return unless node
          return if node != body && (node.is_a?(Prism::DefNode) || node.is_a?(Prism::BlockNode) || node.is_a?(Prism::LambdaNode))

          if node.is_a?(Prism::CallNode) && node.name.to_s == "[]" &&
             node.receiver.is_a?(Prism::LocalVariableReadNode) &&
             node.receiver.name.to_s == parameter_name
            arguments = node.arguments&.arguments || []
            indexed = true if arguments.length == 1 && arguments.first.is_a?(Prism::IntegerNode)
          end
          node.child_nodes.each { |child| walk.call(child) if child }
        end
        walk.call(body)
        indexed ? TypeRef.new(name: "Any[]") : nil
      end

      def collect_closure_uses(node, scope, reads, writes)
        return unless node
        return if node.is_a?(Prism::DefNode)

        if node.is_a?(Prism::LocalVariableReadNode)
          reads << node.name.to_s unless scope.include?(node.name.to_s)
        elsif node.is_a?(Prism::LocalVariableWriteNode)
          writes << node.name.to_s unless scope.include?(node.name.to_s)
        elsif node.is_a?(Prism::CallNode)
          if node.receiver.is_a?(Prism::LocalVariableReadNode) &&
             host_call(:ruby_mutating_receiver_call?, node)
            name = node.receiver.name.to_s
            reads << name unless scope.include?(name)
            writes << name unless scope.include?(name)
          end
          host_call(:mutable_call_argument_local_names, node).each do |name|
            reads << name unless scope.include?(name)
            writes << name unless scope.include?(name)
          end
        end
        node.child_nodes.each { |child| collect_closure_uses(child, scope, reads, writes) if child }
      end

      def closure_instance_context(node)
        return [false, false] unless node
        return [false, false] if node.is_a?(Prism::DefNode)

        used = node.is_a?(Prism::SelfNode) ||
          node.is_a?(Prism::InstanceVariableReadNode) ||
          node.is_a?(Prism::InstanceVariableWriteNode)
        mutated = node.is_a?(Prism::InstanceVariableWriteNode)

        if node.is_a?(Prism::CallNode)
          name = node.name.to_s
          if node.receiver.nil?
            field = host_call(:struct_field_reader?, @owner, name.delete_suffix("="))
            method = host_call(:instance_method_owner_type, @owner, host_call(:clear_function_name, name))
            used ||= field || method
            mutated ||= name.end_with?("=") ||
              @host.instance_variable_get(:@class_mutating_instance_method_names)[@owner].include?(host_call(:clear_function_name, name))
          elsif name == "[]=" || name.end_with?("=")
            receiver_used, = closure_instance_context(node.receiver)
            used ||= receiver_used
            mutated ||= receiver_used
          end
        end

        node.child_nodes.each do |child|
          next unless child

          child_used, child_mutated = closure_instance_context(child)
          used ||= child_used
          mutated ||= child_mutated
        end
        [used, mutated]
      end

      def resolve_call(node, receiver_type)
        name = node.name.to_s
        args = node.arguments&.arguments || []
        write = name.end_with?("=") && args.length == 1
        field_name = write ? name.delete_suffix("=") : name

        if name == "new" && node.receiver &&
           (params = host_call(:typed_ir_constructor_parameter_info, node.receiver))
          owner = node.receiver.location.slice.strip.delete_prefix("::")
          edges = args.each_with_index.map do |argument, index|
            required = params[index] && params[index][:type]
            OwnershipEdge.new(
              mode: ownership_mode(argument, required),
              source: argument.object_id,
              destination: "#{owner}#new:#{index}"
            )
          end
          return ResolvedCall.new(
            target: SymbolId.new(owner: owner, kind: :constructor, name: name),
            dispatch: :constructor,
            return_type: TypeRef.parse(host_call(:clear_type_expr, owner)),
            receiver_ownership: :borrow,
            argument_ownership: edges,
            result_type_identity: owner
          )
        end

        if name == "[]" && args.length == 1 && args.first.is_a?(Prism::SymbolNode) &&
           node.receiver && !receiver_type.unresolved?
          indexed_field_name = args.first.value.to_s
          if host_call(:struct_field_reader?, receiver_type.to_clear, indexed_field_name)
            field_type = host_call(
              :class_instance_field_type,
              receiver_type.to_clear,
              indexed_field_name
            ) || "Any"
            return FieldAccess.new(
              field: SymbolId.new(
                owner: concrete_owner(receiver_type),
                kind: :field,
                name: indexed_field_name
              ),
              receiver_type: receiver_type.narrow_non_nil,
              field_type: field_type,
              write: false
            )
          end
        end

        # A same-named method whose own sig narrows away the field's
        # nilability must win over struct_field_reader? (real corpus case:
        # FunctionSignature#intrinsic_contract, a `sig { returns(
        # IntrinsicContract) }` memoizing getter - `@intrinsic_contract ||=
        # ...` - backed by a `T.nilable(IntrinsicContract)` ivar of the same
        # stripped name; every call site was resolving through the field
        # branch and using the ivar's nilable type instead of the getter's
        # own non-nilable sig). Narrowed to genuinely narrowing sigs only -
        # NOT every same-named method - because a Struct.new-style thin
        # reader (`def name = self[:name].to_s`) is intentionally optimized
        # to a direct field access even though it's technically also a
        # method match (transpiler_spec.rb's "uses prefixed calls for
        # duplicate imported Struct.new methods" / "resolves a unique typed
        # target across an explicit dynamic field boundary" both depend on
        # that optimization staying in place for non-narrowing methods).
        # (An implicit-self call can never be `&.` - Ruby's safe-navigation
        # operator requires an explicit receiver - so no safe-nav exclusion
        # is needed here; see the explicit-receiver branch below for that.)
        if node.receiver.nil? && @instance_method &&
           host_call(:struct_field_reader?, @owner, field_name)
          field_type = host_call(:class_instance_field_type, @owner, field_name) || "Any"
          clear_name = host_call(:clear_function_name, name)
          method_type = (owner = host_call(:instance_method_owner_type, @owner, clear_name)) &&
            host_call(:method_return_type_for, clear_name, owner).to_s
          if owner && field_type.to_s.start_with?("?") && method_type && !method_type.empty? &&
             !method_type.start_with?("?")
            return resolved_method(owner, :instance, name, TypeRef.parse(@owner), node)
          end

          return FieldAccess.new(
            field: SymbolId.new(owner: @owner, kind: :field, name: field_name),
            receiver_type: @owner,
            field_type: field_type,
            write: write
          )
        end

        if node.receiver.nil? && @instance_method
          clear_name = host_call(:clear_function_name, name)
          if (owner = host_call(:instance_method_owner_type, @owner, clear_name))
            return resolved_method(owner, :instance, name, TypeRef.parse(@owner), node)
          end
        end

        # Constants are namespaces, not runtime receiver values. Resolve their
        # class/module target before consulting instance methods inferred from
        # the receiver expression; otherwise a same-named enclosing instance
        # method can capture `OtherClass.method(...)` and turn it into a
        # recursive self-call with the wrong arity.
        if self_class_receiver?(node.receiver)
          clear_name = host_call(:clear_function_name, name)
          class_methods = @host.instance_variable_get(:@class_class_method_names)
          if class_methods[@owner].include?(clear_name)
            return resolved_method(@owner, :class, name, nil, node)
          end
        end

        if node.receiver && (owner = host_call(:constant_receiver_name, node.receiver))
          clear_name = host_call(:clear_function_name, name)
          class_methods = @host.instance_variable_get(:@class_class_method_names)
          if class_methods[owner].include?(clear_name)
            return resolved_method(owner, :class, name, nil, node)
          end
        end

        if node.receiver && (owner = host_call(:module_function_receiver_name, node.receiver))
          clear_name = host_call(:clear_function_name, name)
          module_methods = @host.instance_variable_get(:@module_function_names)
          if module_methods[owner].include?(clear_name)
            return resolved_method(owner, :module, name, nil, node)
          end
        end

        # Same nilability-narrowing exception as the implicit-self branch
        # above, for an external receiver (`other.intrinsic_contract`) - see
        # that branch's comment for the full rationale and the tests this
        # must not disturb. Excluded for `&.` call sites (real corpus
        # regression: `fs&.intrinsic_contract&.behavior&.is_method` -
        # preferring the method here forced the getter's dispatch into the
        # safe-nav chain's nil-check lowering, which is built around
        # FieldAccess and produced a malformed nested IF/value-block the
        # CLEAR frontend couldn't type-check). Safe navigation already
        # handles the field's own nilability correctly on its own -
        # `fs&.intrinsic_contract` degrades gracefully to nil exactly like
        # the plain nilable field would, so the narrowing exception (which
        # only matters for *unguarded* access) has nothing to fix there.
        if node.receiver && !receiver_type.unresolved? &&
           host_call(:struct_field_reader?, receiver_type.to_clear, field_name)
          field_type = host_call(:class_instance_field_type, receiver_type.to_clear, field_name) || "Any"
          clear_name = host_call(:clear_function_name, name)
          method_type = (owner = host_call(:instance_method_owner_type, receiver_type.to_clear, clear_name)) &&
            host_call(:method_return_type_for, clear_name, owner).to_s
          if !node.safe_navigation? && owner && field_type.to_s.start_with?("?") &&
             method_type && !method_type.empty? && !method_type.start_with?("?")
            return resolved_method(owner, :instance, name, receiver_type, node)
          end

          return FieldAccess.new(
            field: SymbolId.new(owner: concrete_owner(receiver_type), kind: :field, name: field_name),
            receiver_type: receiver_type.narrow_non_nil,
            field_type: field_type,
            write: write
          )
        end

        if node.receiver && !receiver_type.unresolved?
          clear_name = host_call(:clear_function_name, name)
          if (owner = host_call(:instance_method_owner_type, receiver_type.to_clear, clear_name))
            return resolved_method(owner, :instance, name, receiver_type, node)
          end
        end

        if node.receiver && receiver_type.unresolved? && !MethodRegistry.registered_name?(name)
          clear_name = host_call(:clear_function_name, name)
          if (owner = host_call(:unique_instance_method_owner, clear_name))
            return resolved_method(owner, :instance, name, TypeRef.parse(owner), node)
          end
        end

        if self_class_receiver?(node.receiver)
          clear_name = host_call(:clear_function_name, name)
          class_methods = @host.instance_variable_get(:@class_class_method_names)
          if class_methods[@owner].include?(clear_name)
            return resolved_method(@owner, :class, name, nil, node)
          end
        end

        if node.receiver && (owner = host_call(:constant_receiver_name, node.receiver))
          clear_name = host_call(:clear_function_name, name)
          class_methods = @host.instance_variable_get(:@class_class_method_names)
          if class_methods[owner].include?(clear_name)
            return resolved_method(owner, :class, name, nil, node)
          end
        end

        if node.receiver && (owner = host_call(:module_function_receiver_name, node.receiver))
          clear_name = host_call(:clear_function_name, name)
          module_methods = @host.instance_variable_get(:@module_function_names)
          if module_methods[owner].include?(clear_name)
            return resolved_method(owner, :module, name, nil, node)
          end
        end

        nil
      end

      def resolved_method(owner, dispatch, name, receiver_type, node)
        params = host_call(:method_params_for, name, owner) || []
        edges = (node.arguments&.arguments || []).each_with_index.map do |argument, index|
          required = params[index] && params[index][:type]
          mode = ownership_mode(argument, required)
          OwnershipEdge.new(mode: mode, source: argument.object_id, destination: "#{owner}##{name}:#{index}")
        end
        ResolvedCall.new(
          target: SymbolId.new(owner: owner, kind: "#{dispatch}_method", name: name),
          dispatch: dispatch,
          receiver_type: receiver_type&.narrow_non_nil,
          return_type: method_return_type(name, owner),
          receiver_ownership: dispatch == :instance && host_call(:mutating_instance_method?, owner, name) ? :borrow_mut : :borrow,
          argument_ownership: edges,
          result_type_identity: host_call(:method_return_type_identity_for, name, owner)
        )
      end

      def ownership_mode(argument, required_type)
        type = required_type.to_s
        return :borrow if type.empty? || type.start_with?("?") || type.include?("@")

        argument_type = infer_type(argument, @initial_env)
        return :copy if !argument_type.unresolved? && !primitive?(argument_type)

        :move
      end

      def infer_type(node, env)
        return TypeRef.new(name: "Unknown") unless node
        recorded = @program.value_for(node)
        return recorded.type if recorded && !recorded.type.unknown?

        case node
        when Prism::LocalVariableReadNode
          local_read_type(node, env)
        when Prism::SelfNode
          TypeRef.parse(@owner)
        when Prism::NilNode
          TypeRef.new(name: "Void", optional: true)
        when Prism::TrueNode, Prism::FalseNode
          TypeRef.new(name: "Bool")
        when Prism::IntegerNode
          TypeRef.new(name: "Int64")
        when Prism::FloatNode
          TypeRef.new(name: "Float64")
        when Prism::StringNode, Prism::InterpolatedStringNode
          TypeRef.new(name: "String")
        when Prism::SymbolNode, Prism::InterpolatedSymbolNode
          TypeRef.new(name: "String", capability: "symbol")
        when Prism::ArrayNode
          member = node.elements.empty? ? TypeRef.new(name: "Any") : infer_type(node.elements.first, env)
          TypeRef.new(name: "#{member.to_clear}[]")
        when Prism::CallNode
          infer_call_type(node, infer_type(node.receiver, env))
        else
          inferred = host_call(:inferred_clear_type_for_node, node)
          TypeRef.parse(inferred)
        end
      rescue StandardError
        TypeRef.new(name: "Unknown")
      end

      def infer_call_type(node, receiver_type)
        if node.name.to_s == "find" && node.block.is_a?(Prism::BlockNode)
          body = node.block.body
          expression = body.body.last if body.is_a?(Prism::StatementsNode)
          if expression.is_a?(Prism::CallNode) && expression.name.to_s == "is_a?"
            expected = expression.arguments&.arguments&.first
            return TypeRef.parse("?#{host_call(:clear_type_expr, expected.location.slice)}") if expected
          end
        end
        if sorbet_cast?(node)
          type_node = node.arguments&.arguments&.at(1)
          return TypeRef.parse(host_call(:convert_sorbet_type, type_node)) if type_node
        end
        if node.name.to_s == "must" && sorbet_receiver?(node)
          value = node.arguments&.arguments&.first
          return infer_type(value, @initial_env).narrow_non_nil
        end

        if node.receiver && !receiver_type.unresolved?
          field_type = host_call(:class_instance_field_type, receiver_type.to_clear, node.name.to_s)
          return TypeRef.parse(field_type) if field_type
          return_type = method_return_type(node.name.to_s, concrete_owner(receiver_type))
          return return_type if return_type && !return_type.unresolved?
        end
        if node.receiver.nil? && @instance_method
          field_type = host_call(:class_instance_field_type, @owner, node.name.to_s.delete_suffix("="))
          return TypeRef.parse(field_type) if field_type && !%w[Any Auto].include?(field_type.to_s)
          return_type = method_return_type(node.name.to_s, @owner)
          return return_type if return_type && !return_type.unresolved?
        end
        TypeRef.parse(host_call(:inferred_clear_type_for_node, node))
      rescue StandardError
        TypeRef.new(name: "Unknown")
      end

      def apply_predicate_constraint(predicate, true_env, _false_env)
        if predicate.is_a?(Prism::CallNode) && predicate.name.to_s == "is_a?" &&
           predicate.receiver.is_a?(Prism::LocalVariableReadNode)
          expected = predicate.arguments&.arguments&.first
          if expected
            type = host_call(:clear_type_expr, expected)
            true_env[predicate.receiver.name.to_s] = TypeRef.parse(type)
          end
        elsif predicate.is_a?(Prism::LocalVariableReadNode)
          current = true_env[predicate.name.to_s]
          true_env[predicate.name.to_s] = current.narrow_non_nil if current&.optional
        end
      end

      def merge_environments!(target, left, right)
        (left.keys & right.keys).each do |name|
          target[name] = merge_types(left[name], right[name])
        end
      end

      def merge_types(left, right)
        return right unless left
        return left unless right
        return left if left == right
        if left.name == right.name && left.capability == right.capability
          return TypeRef.new(name: left.name, optional: left.optional || right.optional, capability: left.capability)
        end
        TypeRef.new(name: "Unknown")
      end

      def block_parameter_names(block)
        requireds = block.parameters&.parameters&.requireds || []
        requireds.filter_map { |parameter| parameter.name.to_s if parameter.respond_to?(:name) }
      end

      # Most Hash enumerable methods (each, each_pair, select, map, ...) yield
      # a [key, value] pair to the block. transform_values/each_value and
      # transform_keys/each_key are the exceptions - they yield a single,
      # bare value or key, never a pair. Getting this wrong emits a Tuple-
      # typed block parameter for a plain value, which then fails downstream
      # (SELECT_NEEDS_LIST) the moment that parameter is iterated/mapped
      # over as if it held the value's own (e.g. array) shape.
      VALUE_ONLY_HASH_BLOCK_METHODS = %w[transform_values each_value].freeze
      KEY_ONLY_HASH_BLOCK_METHODS = %w[transform_keys each_key].freeze

      def block_parameter_types(receiver_type, count, method_name: nil)
        return Array.new(count) if !receiver_type || receiver_type.unresolved?
        type = receiver_type.to_clear.delete_prefix("?")
        element = if type.end_with?("[]")
          TypeRef.parse(type.delete_suffix("[]"))
        elsif type.start_with?("HashMap<")
          members = host_call(:split_top_level_clear_list, type.delete_prefix("HashMap<").delete_suffix(">"))
          if VALUE_ONLY_HASH_BLOCK_METHODS.include?(method_name)
            TypeRef.parse(members.last)
          elsif KEY_ONLY_HASH_BLOCK_METHODS.include?(method_name)
            TypeRef.parse(members.first)
          else
            TypeRef.new(name: "Tuple<#{members.join(',')}>")
          end
        end
        [element, *Array.new([count - 1, 0].max)]
      end

      def record_value(node, type)
        field_place = @program.fields.key?(node.object_id)
        owned_local = node.is_a?(Prism::LocalVariableReadNode) && owned_local_at?(node, type)
        # Sorbet's type-only wrappers preserve the wrapped value's ownership.
        # Treating `T.must(raw.fetch(i))` as a fresh call result loses the
        # borrowed projection fact even though emission simply removes the
        # wrapper and produces `UNWRAP (raw[i])`.
        transparent_source = if node.is_a?(Prism::CallNode) && sorbet_receiver?(node) &&
            %w[must let cast unsafe].include?(node.name.to_s)
          node.arguments&.arguments&.first
        end
        transparent_access = transparent_source && @program.value_for(transparent_source)&.access
        indexed_receiver_type = if node.is_a?(Prism::CallNode) && node.name.to_s == "[]" &&
            node.receiver
          @program.value_for(node.receiver)&.type&.to_clear.to_s
        end
        indexed_string = indexed_receiver_type && !indexed_receiver_type.empty? &&
          host_call(:string_like_clear_type?, indexed_receiver_type.delete_prefix("?"))
        borrowed_result = field_place ||
          (node.is_a?(Prism::CallNode) && node.receiver &&
            %w[to_s [] fetch first last].include?(node.name.to_s) && !indexed_string)
        @program.values[node.object_id] = ValueInfo.new(
          type: type,
          category: place_node?(node) || field_place ? :place : :value,
          access: transparent_access ||
            (owned_local ? :owned : (place_node?(node) || borrowed_result ? :borrowed : :owned)),
          copyable: primitive?(type),
          source_location: node.location&.start_line
        )
      end

      def record_env_type(env, name, type)
        parsed = TypeRef.parse(type)
        env[name.to_s] = parsed unless parsed.unknown?
      end

      def record_definition(node, type, access)
        return unless @admission&.complete

        @admission.cfg_nodes_for(node).each do |cfg_node|
          @definition_types[cfg_node["id"]] = type
          @definition_access[cfg_node["id"]] = access if access
        end
      end

      def local_read_type(node, env)
        current = env.fetch(node.name.to_s, TypeRef.new(name: "Unknown"))
        return current unless current.unresolved?
        return current unless @admission&.complete

        definitions = @admission.reaching_definition_ids_at(node, node.name.to_s)
        definition_types = definitions.filter_map { |definition| @definition_types[definition] }.uniq
        if !definitions.empty? && definition_types.one? && definition_types.first &&
           definitions.all? { |definition| @admission.dominates?(definition, node) }
          @program.record_cfg_consumption(:reaching_definition_type)
          return definition_types.first
        end

        flow_type = type_from_flow_facts(@admission.flow_types_at(node, node.name.to_s))
        if flow_type
          @program.record_cfg_consumption(:flow_type)
          return flow_type
        end
        current
      end

      def owned_local_at?(node, type = nil)
        return @owned_locals.include?(node.name.to_s) unless @admission&.complete
        return @owned_locals.include?(node.name.to_s) if type && primitive?(type)

        # Escape facts describe the destination edge independently of which
        # ownership source (definition or identity origin) proves the value's
        # current access mode. Account for the escape before either proof can
        # return so the analysis does not silently discard this CFG evidence.
        unless @admission.escape_sinks_at(node, node.name.to_s).empty?
          @program.record_cfg_consumption(:escape_ownership)
        end

        # The ownership stamped on a reaching definition is more precise than
        # an identity-origin fact for the local name. In particular, binding a
        # projection from a freshly allocated container (`item = raw.fetch(i)`)
        # creates a borrowed place even though FactMine can correctly describe
        # `raw` itself as fresh. Treating the derived local as fresh/owned lets
        # that borrow flow bare into a TAKES container operation.
        definitions = @admission.reaching_definition_ids_at(node, node.name.to_s)
        accesses = definitions.filter_map { |definition| @definition_access[definition] }.uniq
        if !definitions.empty? && accesses.length == 1 &&
           definitions.all? { |definition| @definition_access.key?(definition) }
          @program.record_cfg_consumption(:reaching_definition_ownership)
          return accesses.first == :owned
        end

        identity_origin = @admission.identity_origin_at(node, node.name.to_s)
        if %i[fresh external].include?(identity_origin)
          @program.record_cfg_consumption(:alias_ownership)
          return identity_origin == :fresh
        end

        @owned_locals.include?(node.name.to_s)
      end

      def type_from_flow_facts(types)
        normalized = Array(types).map(&:to_s).uniq
        optional = normalized.delete("nil")
        return nil unless normalized.one?

        clear = {
          "boolean" => "Bool",
          "float" => "Float64",
          "integer" => "Int64",
          "string" => "String",
          "symbol" => "String@symbol"
        }[normalized.first]
        return nil unless clear

        parsed = TypeRef.parse(clear)
        TypeRef.new(name: parsed.name, optional: optional, capability: parsed.capability)
      end

      def method_return_type(name, owner)
        value = host_call(:method_return_type_for, name, owner)
        value ? TypeRef.parse(value) : nil
      end

      def concrete_owner(type)
        host_call(:resolve_qualified_class_name, type.name) || type.name
      end

      def primitive?(type)
        PRIMITIVE_TYPES.include?(type.to_clear) || type.to_clear.match?(/\A(?:U?Int\d*|Float\d*|Byte\d*)\z/)
      end

      def place_node?(node)
        node.is_a?(Prism::LocalVariableReadNode) || node.is_a?(Prism::InstanceVariableReadNode)
      end

      def function_kind(node)
        node.receiver ? :class_method : :instance_method
      end

      def sorbet_receiver?(node)
        node.receiver&.location&.slice == "T"
      end

      def sorbet_cast?(node)
        sorbet_receiver?(node) && node.name.to_s == "cast"
      end

      def self_class_receiver?(node)
        node.is_a?(Prism::CallNode) && node.name.to_s == "class" &&
          node.receiver.is_a?(Prism::SelfNode) &&
          (!node.arguments || node.arguments.arguments.empty?)
      end

      def host_call(name, *args)
        @host.__send__(name, *args)
      end
    end
  end
end
