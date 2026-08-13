# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require_relative "../ast/ast"
require_relative "../ast/type"
require_relative "../ast/symbol_entry"

module Semantic
  # Immutable, whole-program answer to "does this type transitively contain a
  # linear resource?" Resolution and body annotation first publish the complete
  # type/schema graph; this pass then computes resource reachability once.
  #
  # Consumers must not recursively inspect schemas themselves. COPY validation
  # and lifecycle planning share this single result so cycles, generic
  # instantiations, and collection wrappers have one authoritative answer.
  class LinearResourceFacts
    extend T::Sig

    BoolMap = T.type_alias { T::Hash[String, T::Boolean] }

    sig { params(known: BoolMap, linear: BoolMap).void }
    def initialize(known:, linear:)
      @known = T.let(known.dup.freeze, BoolMap)
      @linear = T.let(linear.dup.freeze, BoolMap)
      freeze
    end

    sig { returns(LinearResourceFacts) }
    def self.empty
      new(known: {}, linear: {})
    end

    sig { params(program: AST::Program, schema_lookup: Type::SchemaLookup).returns(LinearResourceFacts) }
    def self.build(program, schema_lookup)
      inventory = LifecycleRegistry.type_inventory(program, schema_lookup)
      build_types(inventory.values, schema_lookup)
    end

    sig { params(roots: T::Array[Type], schema_lookup: Type::SchemaLookup).returns(LinearResourceFacts) }
    def self.build_types(roots, schema_lookup)
      known = T.let({}, BoolMap)
      seeds = T.let({}, BoolMap)
      edges = T.let({}, T::Hash[String, T::Array[String]])
      pending = T.let(roots.dup, T::Array[Type])
      index = T.let(0, Integer)

      while index < pending.length
        type_info = pending.fetch(index)
        index += 1
        key = fact_key(type_info)
        next if known.key?(key)

        known[key] = true
        seed, dependencies = resource_seed_and_dependencies(type_info, schema_lookup)
        seeds[key] = true if seed
        dependency_keys = T.let([], T::Array[String])
        dependencies.each do |dependency|
          dependency_key = fact_key(dependency)
          dependency_keys << dependency_key
          pending << dependency unless known.key?(dependency_key)
        end
        edges[key] = dependency_keys
      end

      reverse_edges = T.let({}, T::Hash[String, T::Array[String]])
      edges.each do |owner, dependencies|
        dependencies.each do |dependency|
          reverse_edges[dependency] ||= []
          T.must(reverse_edges[dependency]) << owner
        end
      end

      linear = T.let({}, BoolMap)
      queue = T.let(seeds.keys, T::Array[String])
      cursor = T.let(0, Integer)
      while cursor < queue.length
        key = queue.fetch(cursor)
        cursor += 1
        next if linear.key?(key)

        linear[key] = true
        (reverse_edges[key] || []).each do |owner|
          queue << owner unless linear.key?(owner)
        end
      end

      new(known: known, linear: linear)
    end

    sig { params(type_info: Type).returns(T::Boolean) }
    def contains?(type_info)
      key = LinearResourceFacts.fact_key(type_info)
      unless @known.key?(key)
        raise "missing linear-resource fact for #{key} (type absent from post-annotation inventory)"
      end

      @linear.key?(key)
    end

    sig { params(type_info: Type).returns(String) }
    def self.fact_key(type_info)
      # Storage placement cannot change structural resource reachability.
      type_info.semantic_type_key.sub(/\|loc=[^|]+/, "|loc=any")
    end

    class << self
      extend T::Sig

      private

      sig do
        params(
          type_info: Type,
          schema_lookup: Type::SchemaLookup,
        ).returns([T::Boolean, T::Array[Type]])
      end
      def resource_seed_and_dependencies(type_info, schema_lookup)
        return [true, []] if type_info.resource?

        if type_info.optional?
          wrapped = type_info.wrapped_type
          return [false, []] unless wrapped

          return [false, [wrapped]]
        end
        return [false, [type_info.success_type]] if type_info.error_union?
        return [false, type_info.generic_args] if type_info.tuple?
        return [false, [type_info.key_type, type_info.value_type]] if type_info.map?
        if type_info.array? || type_info.collection?
          element = type_info.element_type
          return [false, []] unless element

          return [false, [element]]
        end

        schema = schema_lookup.call(type_info.resolved)
        schema = schema_lookup.call(type_info.generic_base) if schema.nil? && type_info.generic_instance?
        return [true, []] if schema.is_a?(Schemas::ResourceSchema)

        dependencies = T.let([], T::Array[Type])
        if schema.is_a?(Schemas::StructSchema)
          schema.fields.each do |_name, field|
            unless field.borrowed
              dependencies << LifecycleRegistry.concrete_schema_type(type_info, field.type, schema.type_params)
            end
          end
        elsif schema.is_a?(Schemas::UnionSchema)
          schema.variants.each_value do |variant|
            if variant.is_a?(Schemas::InlineStructVariant)
              variant.fields.each_value do |field|
                dependencies << LifecycleRegistry.concrete_schema_type(type_info, field, schema.type_params)
              end
            elsif variant
              dependencies << LifecycleRegistry.concrete_schema_type(type_info, variant, schema.type_params)
            end
          end
        end
        [false, dependencies]
      end

    end
  end

  # A semantic type's paired destruction and duplication contract. Copy and
  # drop deliberately live in the same value object: an owning type may never
  # acquire cleanup without the compiler simultaneously deciding whether a
  # duplicate is a bit-copy, retain, deep clone, or forbidden.
  class LifecyclePlan < T::Struct
    extend T::Sig

    const :type_key, String
    const :drop_strategy, Symbol
    const :copy_strategy, Symbol
    const :resource_close_plan, T.nilable(Schemas::ResourceClosePlan), default: nil

    sig { returns(T::Boolean) }
    def needs_drop?
      drop_strategy != :none
    end

    sig { returns(T::Boolean) }
    def copyable?
      copy_strategy != :forbidden
    end
  end

  # The only semantic-to-lifecycle classifier. Consumers receive an immutable
  # LifecyclePlan; they must not reconstruct copy/drop behavior independently
  # from Zig shapes or from the presence of an emitted cleanup method.
  class LifecyclePlanner
    extend T::Sig

    sig { params(type_info: Type, schema_lookup: Type::SchemaLookup, linear_resource_facts: T.nilable(LinearResourceFacts)).returns(LifecyclePlan) }
    # ruby-to-clear: fallible
    def self.plan(type_info, schema_lookup, linear_resource_facts = nil)
      resource_facts = linear_resource_facts || LinearResourceFacts.build_types([type_info], schema_lookup)
      type_key = type_info.lifecycle_type_key

      if type_info.symbol? || type_info.id_handle? || type_info.c_array_view?
        return LifecyclePlan.new(type_key: type_key, drop_strategy: :none, copy_strategy: :bit_copy)
      end

      # An Rc/Arc CARRIER is itself the owned thing: a handle is released by
      # decrementing its refcount, and where its payload came from does not
      # change that. Only the payload can be a borrow.
      if type_info.any_rc? && !type_info.rodata?
        return LifecyclePlan.new(type_key: type_key, drop_strategy: :release, copy_strategy: :retain)
      end

      if type_info.borrowed_reference? || type_info.rodata?
        copy = if resource_facts.contains?(type_info)
          :forbidden
        elsif type_info.any_rc?
          :retain
        elsif type_info.string? || type_info.recursive_cleanup_shape?(schema_lookup, nil, ignore_borrow: true)
          # COPY through a borrow duplicates what the POINTEE owns. A bit copy
          # here aliases the pointee's heap fields into a second value that is
          # then cleaned up independently.
          :deep_clone
        else
          :bit_copy
        end
        return LifecyclePlan.new(type_key: type_key, drop_strategy: :none, copy_strategy: copy)
      end

      # Ownership wrappers define the outer lifecycle contract even when the
      # wrapped payload is a closeable resource. The last release runs the
      # statically generated payload destructor exactly once.
      if type_info.any_rc?
        return LifecyclePlan.new(type_key: type_key, drop_strategy: :release, copy_strategy: :retain)
      end
      if type_info.split_open_stream?
        return LifecyclePlan.new(type_key: type_key, drop_strategy: :semantic, copy_strategy: :retain)
      end

      close = type_info.resolve_resource_close(schema_lookup)
      if close.is_resource
        return LifecyclePlan.new(
          type_key: type_key,
          drop_strategy: :resource_close,
          copy_strategy: :forbidden,
          resource_close_plan: T.cast(close.close_plan, T.nilable(Schemas::ResourceClosePlan)),
        )
      end

      if resource_facts.contains?(type_info)
        return LifecyclePlan.new(type_key: type_key, drop_strategy: :semantic, copy_strategy: :forbidden)
      end

      if type_info.any_sync? || type_info.frozen? || type_info.link?
        return LifecyclePlan.new(type_key: type_key, drop_strategy: :semantic, copy_strategy: :deep_clone)
      end

      if generic_parameter?(type_info, schema_lookup)
        return LifecyclePlan.new(type_key: type_key, drop_strategy: :generic, copy_strategy: :generic)
      end

      if type_info.string? || type_info.recursive_cleanup_shape?(schema_lookup)
        return LifecyclePlan.new(type_key: type_key, drop_strategy: :semantic, copy_strategy: :deep_clone)
      end

      LifecyclePlan.new(type_key: type_key, drop_strategy: :none, copy_strategy: :bit_copy)
    end

    # A MONOMORPHIC TAKES param is emitted `anytype` and threads the caller's
    # actual carrier (plain / Rc / Arc). Its lifecycle is the carrier's, not the
    # bare payload's: release the handle if it is refcounted, no-op if plain --
    # exactly the `any_rc?` contract above, resolved at Zig comptime by
    # CheatLib.cleanup(@TypeOf). The contract is payload-independent, so it is
    # keyed distinctly from the payload type's own plan. Owned here (the single
    # lifecycle classifier) so consumers fetch it instead of reconstructing it.
    sig { params(type_info: Type).returns(String) }
    def self.monomorphic_carrier_key(type_info)
      "MONOMORPHIC #{type_info.resolved}"
    end

    sig { params(type_info: Type).returns(LifecyclePlan) }
    def self.monomorphic_carrier_plan(type_info)
      LifecyclePlan.new(
        type_key: monomorphic_carrier_key(type_info),
        drop_strategy: :release,
        copy_strategy: :retain,
      )
    end

    sig { params(type_info: Type, node: AST::Node, schema_lookup: Type::SchemaLookup, linear_resource_facts: T.nilable(LinearResourceFacts)).returns(LifecyclePlan) }
    def self.plan_binding(type_info, node, schema_lookup, linear_resource_facts = nil)
      base = plan(type_info, schema_lookup, linear_resource_facts)
      return base unless mutable_owned_string_binding?(type_info, node)

      LifecyclePlan.new(
        type_key: "#{type_info.lifecycle_type_key}|binding=mutable-owned",
        drop_strategy: :semantic,
        copy_strategy: :deep_clone,
      )
    end

    sig { params(type_info: Type, schema_lookup: Type::SchemaLookup).returns(T::Boolean) }
  def self.generic_parameter?(type_info, schema_lookup)
      return true if type_info.projection?

      if type_info.generic_instance?
        return type_info.generic_args.any? { |argument| generic_parameter?(argument, schema_lookup) }
      end

      wrapped = type_info.wrapped_type
      return generic_parameter?(wrapped, schema_lookup) if wrapped

      name = type_info.resolved.to_s
      name.match?(/\A[A-Z]\z/) && schema_lookup.call(type_info.resolved).nil?
    end
    private_class_method :generic_parameter?

    sig { params(type_info: Type, node: AST::Node).returns(T::Boolean) }
    def self.mutable_owned_string_binding?(type_info, node)
      return false unless type_info.string?
      return false unless node.var_mutated == true
      return false if AST.container_borrow?(node)

      symbol = T.unsafe(node).respond_to?(:symbol) ? T.unsafe(node).symbol : nil
      !symbol&.borrow_provenance?
    end
    private_class_method :mutable_owned_string_binding?
  end

  # Frozen annotation product indexed by canonical semantic type identity.
  # Missing entries fail closed; MIR is not permitted to silently derive a
  # replacement lifecycle contract after annotation.
  class LifecycleRegistry
    extend T::Sig

    PlanMap = T.type_alias { T::Hash[String, LifecyclePlan] }
    BindingPlanMap = T.type_alias { T::Hash[Integer, LifecyclePlan] }
    BindingNode = T.type_alias { T.any(AST::VarDecl, AST::BindExpr, AST::DestructureTarget) }

    sig { returns(LifecycleRegistry) }
    def self.empty
      new({}, {})
    end

    # The concrete schema object is not part of the substitution contract.
    # Passing the common `type_params` data avoids materializing a synthetic
    # union of schema implementation classes in generated CLEAR.
    sig { params(owner: Type, raw_type: Type::TypeInput, type_params: T::Array[Symbol]).returns(Type) }
    def self.concrete_schema_type(owner, raw_type, type_params)
      subst = T.let({}, T::Hash[Symbol, Type])
      type_params.zip(owner.generic_args).each do |param, argument|
        subst[param.to_sym] = Type.new(argument) if param && argument
      end
      substitute_schema_type(raw_type, subst)
    end

    sig { params(program: AST::Program, schema_lookup: Type::SchemaLookup).returns(T::Hash[String, Type]) }
    def self.type_inventory(program, schema_lookup)
      types = T.let({}, T::Hash[String, Type])

      AST.each_locatable(program, descend_functions: true) do |node|
        add_type!(types, node.full_type!(context: "lifecycle inventory")) if node.typed?
      end
      add_declaration_types!(types, program)
      add_instantiated_schema_types!(types, schema_lookup)
      types
    end

    sig { params(program: AST::Program, schema_lookup: Type::SchemaLookup, binding_nodes: T::Array[BindingNode], linear_resource_facts: T.nilable(LinearResourceFacts), inventory: T.nilable(T::Hash[String, Type])).returns(LifecycleRegistry) }
    def self.build(program, schema_lookup, binding_nodes: [], linear_resource_facts: nil, inventory: nil)
      types = inventory || type_inventory(program, schema_lookup)
      resource_facts = linear_resource_facts || LinearResourceFacts.build_types(types.values, schema_lookup)

      plans = T.let({}, PlanMap)
      types.each do |key, type_info|
        plans[key] = LifecyclePlanner.plan(type_info, schema_lookup, resource_facts)
      end
      add_monomorphic_carrier_plans!(plans, program)
      binding_plans = T.let({}, BindingPlanMap)
      inventoried_bindings = T.let(binding_nodes.dup, T::Array[BindingNode])
      AST.each_locatable(program, descend_functions: true) do |node|
        next unless node.is_a?(AST::VarDecl) || node.is_a?(AST::BindExpr) || node.is_a?(AST::DestructureTarget)
        next if node.is_a?(AST::BindExpr) && node.mode == :assign
        next unless node.typed?

        inventoried_bindings << node
      end
      inventoried_bindings.each do |node|
        symbol = T.unsafe(node).respond_to?(:symbol) ? T.unsafe(node).symbol : nil
        declaration = symbol.is_a?(SymbolEntry) ? symbol.reg : nil
        if declaration.is_a?(AST::VarDecl) || declaration.is_a?(AST::BindExpr) || declaration.is_a?(AST::DestructureTarget)
          node = declaration
        end
        next if node.is_a?(AST::BindExpr) && node.mode == :assign
        next unless node.typed?
        place_id = binding_place_id(node)
        next unless place_id

        plan = LifecyclePlanner.plan_binding(
          node.full_type!(context: "binding lifecycle inventory"),
          node,
          schema_lookup,
          resource_facts,
        )
        existing = binding_plans[place_id]
        existing_close = existing&.resource_close_plan&.actions&.map do |action|
          [action.call_kind.serialize, action.name, action.field_path, action.runtime_heap_alloc_args]
        end
        planned_close = plan.resource_close_plan&.actions&.map do |action|
          [action.call_kind.serialize, action.name, action.field_path, action.runtime_heap_alloc_args]
        end
        same_contract = existing &&
          existing.type_key == plan.type_key &&
          existing.drop_strategy == plan.drop_strategy &&
          existing.copy_strategy == plan.copy_strategy &&
          existing_close == planned_close
        if existing && !same_contract
          raise "conflicting annotation binding lifecycle plans for place #{place_id}: " \
            "#{existing.type_key}/#{existing.drop_strategy} vs #{plan.type_key}/#{plan.drop_strategy} " \
            "at #{node.class} line #{node.token.line}"
        end
        binding_plans[place_id] = plan
      end
      new(plans, binding_plans)
    end

    # A MONOMORPHIC carrier param's lifecycle is not derivable from its payload
    # type (the payload alone needs no drop), so the type-keyed inventory above
    # misses it. Register the carrier-release plan at the point the param is
    # introduced -- via the single lifecycle classifier -- so cleanup
    # classification fetches it instead of fabricating one at the use site.
    sig { params(plans: PlanMap, program: AST::Program).void }
    def self.add_monomorphic_carrier_plans!(plans, program)
      AST.each_locatable(program, descend_functions: true) do |node|
        next unless node.is_a?(AST::FunctionDef)

        node.params.each do |p|
          next unless p.takes && p.carrier_contract == :monomorphic

          plan = LifecyclePlanner.monomorphic_carrier_plan(p.type)
          plans[plan.type_key] = plan
        end
      end
    end

    sig { params(plans: PlanMap, binding_plans: BindingPlanMap).void }
    def initialize(plans, binding_plans)
      @plans = T.let(plans.dup.freeze, PlanMap)
      @binding_plans = T.let(binding_plans.dup.freeze, BindingPlanMap)
      freeze
    end

    sig { params(type_info: Type).returns(LifecyclePlan) }
    def fetch(type_info)
      key = type_info.lifecycle_type_key
      @plans.fetch(key) do
        # Fail CLOSED. A type absent from the annotation inventory is only safe
        # to treat as no-drop if it is provably no-drop WITHOUT a schema -- i.e.
        # a primitive scalar (Number / Bool / numeric). For any other type a
        # missing plan is a real inventory bug, NOT a bit-copy default:
        # needs_cleanup?(nil) is schema-blind and cannot see a named struct's
        # cleanup-bearing fields, so defaulting such a type to no-drop would
        # silently leak. Post-annotation synthetic bindings that legitimately
        # reach here (e.g. a desugared pipeline fold's Bool found-flag) are
        # primitive; anything else must be registered during build.
        unless type_info.primitive?
          raise "missing annotation lifecycle plan for #{key} (non-primitive type absent from inventory; refusing to default to no-drop)"
        end
        LifecyclePlan.new(type_key: key, drop_strategy: :none, copy_strategy: :bit_copy)
      end
    end

    # The carrier-release plan for a MONOMORPHIC TAKES param, registered during
    # build. Falls back to the single classifier if this registry predates the
    # param (build always registers it, so the fallback is defensive only).
    sig { params(type_info: Type).returns(LifecyclePlan) }
    def fetch_monomorphic(type_info)
      @plans.fetch(LifecyclePlanner.monomorphic_carrier_key(type_info)) do
        LifecyclePlanner.monomorphic_carrier_plan(type_info)
      end
    end

    sig { params(node: AST::Node, type_info: Type).returns(LifecyclePlan) }
    def fetch_binding(node, type_info)
      place_id = binding_place_id(node)
      return fetch(type_info) unless place_id

      @binding_plans.fetch(place_id) do
        raise "missing annotation binding lifecycle plan for place #{place_id}"
      end
    end

    private

    sig { params(node: AST::Node).returns(T.nilable(Integer)) }
    def binding_place_id(node)
      symbol = T.unsafe(node).respond_to?(:symbol) ? T.unsafe(node).symbol : nil
      symbol.is_a?(SymbolEntry) ? symbol.semantic_place_id : nil
    end

    class << self
      private

      extend T::Sig

      sig { params(types: T::Hash[String, Type], type_info: Type).void }
      def add_type!(types, type_info)
        key = type_info.lifecycle_type_key
        return if types.key?(key)

        types[key] = type_info
        # Inventory the parsed structure itself so intermediate tense wrappers
        # are never skipped. In particular, the cleanup binding synthesized
        # for `!?T` has type `?T`, which is neither `wrapped_type` nor
        # `payload_type` of the outer value when discovered through the old
        # projection-only list below.
        TypeExpressionTree.direct_children(type_info.shape.expression).each do |expression|
          add_type!(types, Type.from_child_expression(expression))
        end

        # Keep semantic projections as well: they intentionally propagate
        # outer capability/placement contracts in cases where the raw syntax
        # child does not.
        type_info.generic_args.each { |argument| add_type!(types, argument) }
        wrapped = type_info.wrapped_type
        add_type!(types, wrapped) if wrapped
        element = type_info.element_type
        add_type!(types, element) if element
        add_type!(types, type_info.key_type) if type_info.map?
        add_type!(types, type_info.value_type) if type_info.map?
      end

      sig { params(node: AST::Node).returns(T.nilable(Integer)) }
      def binding_place_id(node)
        symbol = T.unsafe(node).respond_to?(:symbol) ? T.unsafe(node).symbol : nil
        symbol.is_a?(SymbolEntry) ? symbol.semantic_place_id : nil
      end

      sig { params(types: T::Hash[String, Type], program: AST::Program).void }
      def add_declaration_types!(types, program)
        AST.each_locatable(program, descend_functions: true) do |statement|
          case statement
          when AST::StructDef, AST::ExternStructDecl
            statement.field_decls.each_value { |field| add_type!(types, field.type) }
          when AST::UnionDef
            statement.variants.each_value do |variant|
              if variant.is_a?(Schemas::InlineStructVariant)
                variant.fields.each_value { |field| add_type!(types, Type.from_input(field)) }
              elsif variant
                add_type!(types, Type.from_variant_input(variant))
              end
            end
          when AST::FunctionDef
            statement.params.each { |param| add_type!(types, param.type) }
            add_type!(types, Type.new(statement.return_type)) if statement.return_type
          end
        end
      end

      # Generic declaration fields are inventoried in their symbolic form
      # (for example `?V`), but MIR lowers a concrete literal using the
      # instantiated field type (`?String`).  Inventory that concrete closure
      # during annotation so lowering never has to invent lifecycle policy.
      sig { params(types: T::Hash[String, Type], schema_lookup: Type::SchemaLookup).void }
      def add_instantiated_schema_types!(types, schema_lookup)
        pending = T.let(types.values.dup, T::Array[Type])
        index = T.let(0, Integer)
        while index < pending.length
          type_info = pending.fetch(index)
          index += 1
          next unless type_info.generic_instance?

          schema = schema_lookup.call(type_info.resolved)
          schema = schema_lookup.call(type_info.generic_base) if schema.nil?
          next unless schema.is_a?(Schemas::StructSchema) || schema.is_a?(Schemas::ResourceSchema)
          fields = schema.fields.values.map(&:type)

          fields.each do |field_type|
            concrete = concrete_schema_type(type_info, field_type, schema.type_params)
            before = types.length
            add_type!(types, concrete)
            pending.concat(types.values.drop(before)) if types.length > before
          end
        end
        nil
      end

      sig { params(raw_type: Type::TypeInput, subst: T::Hash[Symbol, Type]).returns(Type) }
      def substitute_schema_type(raw_type, subst)
        type_info = Type.from_input(raw_type)
        replacement = if type_info.projection?
          owner = T.must(type_info.projection_owner)
          concrete_input = subst[owner]
          if concrete_input
            concrete = Type.new(concrete_input)
            projected = T.let(nil, T.nilable(Type))
            member = type_info.projection_member
            if concrete.map?
              if member == :Key
                projected = concrete.key_type
              elsif member == :Value
                projected = concrete.value_type
              end
            end
            projected || Type.new(TypeExpression.of(TypeProjectionExpression.new(
              owner: concrete.resolved,
              member: T.must(type_info.projection_member),
              protocol: type_info.projection_protocol,
            )))
          else
            type_info
          end
        elsif type_info.optional?
          Type.optional_of(substitute_schema_type(T.must(type_info.wrapped_type), subst))
        elsif type_info.error_union?
          Type.error_union_of(substitute_schema_type(T.must(type_info.payload_type), subst))
        elsif type_info.array?
          Type.array_of(substitute_schema_type(T.must(type_info.element_type), subst), capacity: type_info.capacity)
        elsif type_info.map?
          wrapper = type_info.shape.expression
          expression = T.cast(wrapper.kind, MapTypeExpression)
          key = substitute_schema_type(type_info.key_type, subst)
          value = substitute_schema_type(type_info.value_type, subst)
          Type.new(TypeExpression.new(kind: MapTypeExpression.new(
            key: key.shape.expression,
            value: value.shape.expression,
            key_implicit: expression.key_implicit,
            legacy_separator: expression.legacy_separator,
          ), capabilities: wrapper.capabilities))
        elsif type_info.generic_instance?
          Type.generic_instance_of(
            type_info.generic_base,
            type_info.generic_args.map { |argument| substitute_schema_type(argument, subst) },
          )
        elsif type_info.tense?
          Type.tense_of(substitute_schema_type(type_info.tense_type, subst))
        else
          subst[type_info.resolved] || type_info
        end
        replacement.merge_capabilities_from!(type_info)
        replacement.copy_placement_from!(type_info)
        replacement
      end
    end
  end
end
