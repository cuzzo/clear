# typed: strict
require "sorbet-runtime"
require_relative "../../ast/ast"
# method_analysis.rb — Type-specific method resolution for Pool and HashMap.
#
# Resolves method calls on collection types using the declarative registries
# in std_lib.rb (POOL_METHODS, MAP_METHODS) instead of hard-coded case
# statements. Mixed into SemanticAnnotator.
module MethodAnalysis
    extend T::Sig

  # Attempt to resolve a method call on a collection type (Pool, Set, or HashMap).
  # Returns true if handled, false if the caller should fall through to UFCS.
  # Dispatch is driven by COLLECTION_METHOD_CONFIGS keyed on Type#dispatch_key.
  sig { params(node: AST::MethodCall).returns(T.nilable(T::Boolean)) }
  def resolve_collection_method(node)
    T.bind(self, SemanticAnnotator) rescue nil
    obj_type = node.object.full_type!(context: "collection method receiver")
    config = COLLECTION_METHOD_CONFIGS[obj_type.dispatch_key]
    return false unless config
    resolve_typed_method(node, obj_type, config[:registry], config[:tag],
                         config[:label].call(obj_type))
  end

  # Narrow a collection's element type after an intrinsic call with
  # narrows_collection: true (e.g., append). When the collection has
  # Any element type and the value arg has a concrete type, updates
  # the scope entry and the collection variable's type_info.
  #
  # @param matched_def [Hash] the STD_LIB definition that matched
  # @param args [Array] the resolved argument nodes
  sig { params(matched_def: FunctionSignature, args: T::Array[T.untyped]).returns(T.nilable(Type)) }
  def narrow_collection_type!(matched_def, args)
    T.bind(self, SemanticAnnotator) rescue nil
    return unless matched_def.intrinsic_contract.behavior.narrows_collection && args.size >= 2

    list_arg = args[0]
    return unless list_arg.is_a?(AST::Identifier)

    scope_entry = list_arg.symbol
    ti = scope_entry&.type
    return unless scope_entry
    return if ti.is_a?(Type) && ti.promise_list?
    return unless ti.is_a?(Type) && ti.collection && ti.element_type&.resolved == :Any

    val_arg = args[1]
    val_type = val_arg.resolved_type
    new_type = Type.new(:"#{val_type}[]", collection: ti.collection)
    new_type.copy_collection_shape_from!(ti)
    new_type.copy_element_capabilities_from!(ti)
    new_type.copy_placement_from!(ti, preserve_existing: false)
    scope_entry.type = new_type
    stamp_type!(list_arg, new_type)
  end

  private

  sig { params(node: AST::MethodCall, obj_type: Type, registry: T::Hash[String, T::Hash[Symbol, T.untyped]], tag_field: Symbol, type_label: String).returns(T.nilable(T::Boolean)) }
  def resolve_typed_method(node, obj_type, registry, tag_field, type_label)
    T.bind(self, SemanticAnnotator) rescue nil
    defn = FunctionSignature.unwrap(IntrinsicRegistry.lookup(registry, T.unsafe(node).name))
    unless defn
      available = registry.keys.join(", ")
      emit_typo_suggestion!(
        node.token, node.name, registry.keys,
        "Unknown method '#{node.name}' on #{type_label}. Available: #{available}",
        "method of #{type_label}",
        category: :type, cascade: true
      )
      return true
    end

    # Arity check
    arity = defn.arity
    if arity && arity >= 0 && node.args.length != arity
      if arity == 0
        error!(node, :STDLIB_METHOD_NO_ARGS, label: type_label, method: node.name, got: node.args.length)
      else
        error!(node, :STDLIB_METHOD_ARITY, label: type_label, method: node.name, expected: arity, got: node.args.length)
      end
      return true
    end

    # Type validation (optional)
    arg_validator = defn.arg_validator
    if arg_validator
      arg_validator.call(node, node.args, obj_type, method(:error!))
    end

    # Set tag and return type
    node.send(:"#{tag_field}=", node.name.to_sym)
    stamp_type!(node, defn.return_def.resolve(obj_type, [], self))
    node.container_borrow = defn.intrinsic_container_borrow?

    # Resolve zig pattern -- pick variant based on receiver type.
    # Sharded takes priority over numeric: PartitionedNumericMap shares the
    # sharded API (count/keys/values/put/get) with PartitionedStringMap.
    sharded_pattern = defn.intrinsic_template(:sharded_zig)
    numeric_pattern = defn.intrinsic_template(:numeric_zig)
    zig = if (obj_type.sharded? || obj_type.striped?) && sharded_pattern
      sharded_pattern
    elsif obj_type.plain_numeric_map? && numeric_pattern
      numeric_pattern
    else
      defn.intrinsic_pattern
    end

    # Resolve alloc variant for sharded types
    alloc = if (obj_type.sharded? || obj_type.striped?) && defn.intrinsic_alloc(:sharded_alloc)
      defn.intrinsic_alloc(:sharded_alloc)
    else
      defn.intrinsic_alloc(:alloc)
    end

    # Set zig_pattern and matched_stdlib_def so lower_intrinsic handles
    # emission. Override via FunctionSignature so the shared registry
    # signature is never mutated.
    if zig
      resolved_defn = defn.with_intrinsic_override(pattern: zig, alloc: alloc)
      node.zig_pattern = zig
      node.matched_stdlib_def = resolved_defn
      node.matched_signature = resolved_defn if node.respond_to?(:matched_signature=)
    end

    defn_allocates = defn.emits_allocating?
    node.stdlib_allocates = defn_allocates
    node.mutates_receiver = defn.mutates_receiver?

    narrow_receiver_collection!(node, obj_type, defn)

    # Ownership: mark TAKES args as moved (same as function_analysis.rb line 305-310)
    defn.intrinsic_argument_takes_indices.each do |arg_idx|
      arg_node = node.args[arg_idx]
      move_if_takes_ownership!(arg_node, action: :takes, consumer_param_type: nil)
    end

    # Methods that allocate on the heap -- record so needs_rt is computed correctly.
    current_fn_ctx&.record_heap_use! if defn_allocates
    node.can_fail = node.can_fail || defn.can_fail || defn_allocates
    node.error_kind = defn.intrinsic_error_kind
    node.error_type = defn.intrinsic_error_type

    true
  end

  sig { params(node: AST::MethodCall, obj_type: Type, defn: FunctionSignature).void }
  def narrow_receiver_collection!(node, obj_type, defn)
    T.bind(self, SemanticAnnotator) rescue nil
    return unless defn.intrinsic_receiver_collection_narrowing?
    return unless node.args.length == 1
    return unless obj_type.element_type&.resolved == :Any

    val_type = node.args[0].resolved_type
    new_type = Type.new(:"#{val_type}[]", collection: obj_type.collection)
    new_type.copy_placement_from!(obj_type, preserve_existing: false)
    new_type.copy_collection_shape_from!(obj_type)
    new_type.copy_element_capabilities_from!(obj_type)
    if node.object.is_a?(AST::Identifier)
      entry = node.object.symbol
      if entry
        entry.type = new_type
        stamp_type!(node.object, new_type)
      end
    end
  end

  # Look up the INDEX_OPS entry for a container type.
  # Returns the :get or :set sub-entry, or nil.
  # Dispatch is driven by Type#dispatch_key — add new indexable types there.
  sig { params(type_info: Type, op: Symbol).returns(T.nilable(T::Hash[T.untyped, T.untyped])) }
  def resolve_index_op(type_info, op)
    T.bind(self, SemanticAnnotator) rescue nil
    return nil if type_info.promise_list?
    INDEX_OPS.dig(type_info.dispatch_key, op)
  end
end
