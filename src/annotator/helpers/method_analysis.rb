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
    return unless matched_def.emit&.narrows_collection && args.size >= 2

    list_arg = args[0]
    val_arg  = args[1]
    return unless list_arg.is_a?(AST::Identifier)

    scope_entry = list_arg.symbol
    ti = scope_entry&.type
    return if ti.is_a?(Type) && ti.promise_list?
    return unless ti.is_a?(Type) && ti.collection && ti.element_type&.resolved == :Any

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
    defn = IntrinsicRegistry.sig(registry, T.unsafe(node).name)
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
    if defn.arity && defn.arity >= 0 && node.args.length != defn.arity
      if defn.arity == 0
        error!(node, :STDLIB_METHOD_NO_ARGS, label: type_label, method: node.name, got: node.args.length)
      else
        error!(node, :STDLIB_METHOD_ARITY, label: type_label, method: node.name, expected: defn.arity, got: node.args.length)
      end
      return true
    end

    # Type validation (optional)
    if defn.arg_validator
      defn.arg_validator.call(node, node.args, obj_type, method(:error!))
    end

    # Set tag and return type
    node.send(:"#{tag_field}=", node.name.to_sym)
    stamp_type!(node, defn.return_def.resolve(obj_type, [], self))
    em = T.must(defn.emit)
    node.container_borrow = true if em.container_borrow

    # Resolve zig pattern -- pick variant based on receiver type.
    # Sharded takes priority over numeric: PartitionedNumericMap shares the
    # sharded API (count/keys/values/put/get) with PartitionedStringMap.
    zig = if (obj_type.sharded? || obj_type.striped?) && em.sharded_zig
      em.sharded_zig
    elsif obj_type.plain_numeric_map? && em.numeric_zig
      em.numeric_zig
    else
      em.zig
    end

    # Resolve alloc variant for sharded types
    alloc = if (obj_type.sharded? || obj_type.striped?) && em.sharded_alloc
      em.sharded_alloc
    else
      em.alloc
    end

    # Set zig_pattern and matched_stdlib_def so lower_intrinsic handles
    # emission. Override the zig/alloc on a dup'd FS (+ its emit) so
    # the shared registry FS is never mutated.
    if zig
      resolved_defn = defn.dup
      resolved_defn.emit = T.must(resolved_defn.emit).dup
      resolved_defn.emit.zig = zig
      resolved_defn.emit.alloc = alloc if alloc
      node.zig_pattern = zig
      node.matched_stdlib_def = resolved_defn
      node.matched_signature = resolved_defn if node.respond_to?(:matched_signature=)
    end

    node.stdlib_allocates = true if em.allocates
    node.mutates_receiver = true if em.mutates_receiver

    narrow_receiver_collection!(node, obj_type, em)

    # Ownership: mark TAKES args as moved (same as function_analysis.rb line 305-310)
    if em.takes_args
      em.takes_args.each do |arg_idx|
        arg_node = node.args[arg_idx]
        move_if_takes_ownership!(arg_node, action: :takes, consumer_param_type: nil)
      end
    end

    # Methods that allocate on the heap -- record so needs_rt is computed correctly.
    if em.allocates && current_fn_ctx
      current_fn_ctx.heap_count += 1
    end
    node.can_fail = true if defn.can_fail || em.allocates
    node.error_kind = em.error_kind
    node.error_type = em.error_type

    true
  end

  sig { params(node: AST::MethodCall, obj_type: Type, emit: IntrinsicEmit).void }
  def narrow_receiver_collection!(node, obj_type, emit)
    T.bind(self, SemanticAnnotator) rescue nil
    return unless emit.narrows_receiver_collection
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
