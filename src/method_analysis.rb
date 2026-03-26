# method_analysis.rb — Type-specific method resolution for Pool and HashMap.
#
# Resolves method calls on collection types using the declarative registries
# in std_lib.rb (POOL_METHODS, MAP_METHODS) instead of hard-coded case
# statements. Mixed into SemanticAnnotator.
module MethodAnalysis
  # Attempt to resolve a method call on a collection type (Pool or HashMap).
  # Returns true if handled, false if the caller should fall through to UFCS.
  def resolve_collection_method(node)
    obj_type = node.object.type_info

    if obj_type&.pool?
      resolve_typed_method(node, obj_type, POOL_METHODS, :pool_method,
        "Pool<#{obj_type.element_type.resolved}>")
    elsif obj_type&.map?
      resolve_typed_method(node, obj_type, MAP_METHODS, :map_method,
        "HashMap<#{obj_type.value_type.resolved}>")
    else
      false
    end
  end

  private

  def resolve_typed_method(node, obj_type, registry, tag_field, type_label)
    defn = registry[node.name]
    unless defn
      available = registry.keys.join(", ")
      error!(node, "Unknown method '#{node.name}' on #{type_label}. Available: #{available}")
      return true
    end

    # Arity check
    if defn[:arity] >= 0 && node.args.length != defn[:arity]
      if defn[:arity] == 0
        error!(node, "#{type_label}.#{node.name} takes no arguments, got #{node.args.length}")
      else
        error!(node, "#{type_label}.#{node.name} requires exactly #{defn[:arity]} argument#{'s' if defn[:arity] > 1}, got #{node.args.length}")
      end
      return true
    end

    # Type validation (optional)
    if defn[:validate]
      defn[:validate].call(node, node.args, obj_type, method(:error!))
    end

    # Set tag and return type
    node.send(:"#{tag_field}=", node.name.to_sym)
    node.full_type = defn[:return_type].call(obj_type)
    true
  end
end
