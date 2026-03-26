# capabilities.rb — Capability validation for CLEAR's type system.
#
# Capabilities are orthogonal modifiers on types: ownership, sync,
# layout, topology.  This module validates that a given combination
# is legal and produces clear error messages for conflicts.
#
# Usage:
#   Capabilities.validate!(node_or_token, type_obj)
#
# Future: will also centralize capability parsing (v0.2).

module Capabilities
  # Capability groups — at most one from each group is allowed.
  GROUPS = {
    ownership: %i[multiowned shared],
    sync:      %i[locked write_locked local],
    layout:    %i[soa],
  }.freeze

  # Capabilities that are mutually exclusive with each other.
  CONFLICTS = [
    [[:soa],     [:shared, :multiowned], "SOA layout is incompatible with reference-counted ownership"],
    [[:arena],   [:parallel],            "@arena cannot be combined with @parallel — arena memory is thread-local"],
    [[:local],   [:parallel],            "@local requires single-scheduler affinity, incompatible with @parallel"],
  ].freeze

  # Validate a Type object's capability combination.
  # Raises a compile error (via the block) if invalid.
  #
  # @param type [Type] the type to validate
  # @return [Array<String>] list of error messages (empty if valid)
  def self.errors_for(type)
    return [] unless type.is_a?(Type)

    errors = []
    caps = active_capabilities(type)

    # Check for duplicates within groups
    GROUPS.each do |group_name, members|
      active = members.select { |c| caps.include?(c) }
      if active.size > 1
        errors << "Conflicting #{group_name} capabilities: #{active.map { |c| "@#{c}" }.join(' and ')}. Only one #{group_name} capability is allowed."
      end
    end

    # Check explicit conflicts
    CONFLICTS.each do |set_a, set_b, message|
      has_a = set_a.any? { |c| caps.include?(c) }
      has_b = set_b.any? { |c| caps.include?(c) }
      errors << message if has_a && has_b
    end

    errors
  end

  # Validate and raise on first error.
  # Requires a node/token for error location and an error! method.
  def self.validate!(node, type, &error_handler)
    errs = errors_for(type)
    return if errs.empty?
    error_handler.call(node, errs.first) if error_handler
  end

  # Extract active capabilities from a Type as a Set of symbols.
  def self.active_capabilities(type)
    caps = Set.new
    caps << type.ownership if type.ownership && type.ownership != :affine
    caps << type.sync if type.sync
    caps << :soa if type.respond_to?(:soa?) && type.soa?
    caps << :sharded if type.respond_to?(:sharded?) && type.sharded?
    caps << :pool if type.respond_to?(:pool?) && type.pool?
    caps << :list if type.respond_to?(:list_collection?) && type.list_collection?
    caps
  end
end
