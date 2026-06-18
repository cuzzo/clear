# typed: false
# frozen_string_literal: true

module NilKill
  class SourceIndex
    def inspect_branch_guard(node, inverted:)
      predicate = node.respond_to?(:predicate) ? node.predicate : nil
      return unless predicate
      result = deterministic_predicate_result(predicate)
      return unless result

      truth = result["truth_value"]
      taken = inverted ? !truth : truth
      @deterministic_guards << TypedRecords::DeterministicGuardRecord.new(
        path: @rel,
        line: predicate.location.start_line,
        owner: @current_class_name,
        method_name: @current_method_name,
        code: predicate.slice.split("\n").first.to_s.strip[0, 160],
        branch_kind: inverted ? "unless" : "if",
        truth_value: truth,
        taken_branch: taken ? "body" : "else",
        proof_tier: result["proof_tier"],
        predicate_kind: result["predicate_kind"],
        reason: result["reason"],
        origin_kind: result["origin_kind"],
        origin_name: result["origin_name"],
      ).to_source_index_hash
    end

    def deterministic_predicate_result(node)
      node = implicit_return_expression(node) if node.is_a?(Syntax::ParenthesesNode)
      literal = literal_truth_value(node)
      return deterministic_guard_result(literal, "literal", "#{node.slice} is a boolean literal") unless literal.nil?

      if node.is_a?(Syntax::CallNode)
        nil_result = deterministic_nil_predicate_result(node)
        return nil_result if nil_result
        class_result = deterministic_class_predicate_result(node)
        return class_result if class_result
        return deterministic_literal_comparison_result(node)
      end
      nil
    end

    def deterministic_guard_result(truth_value, predicate_kind, reason, origin_kind: nil, origin_name: nil)
      TypedRecords::DeterministicGuardResultRecord.new(
        truth_value: truth_value,
        predicate_kind: predicate_kind,
        reason: reason,
        origin_kind: origin_kind,
        origin_name: origin_name,
      )
    end

    def literal_truth_value(node)
      case node
      when Syntax::TrueNode then true
      when Syntax::FalseNode then false
      else nil
      end
    end

    def deterministic_nil_predicate_result(node)
      return nil unless node.name == :nil? && node.receiver
      receiver = node.receiver
      origin_kind, origin_name = predicate_origin(receiver)
      receiver_type = deterministic_guard_subject_type(receiver)
      if receiver_type && receiver_type != "NilClass" && !receiver_type.to_s.start_with?("T.nilable(")
        return deterministic_guard_result(false, "nil_check",
          "#{receiver.slice} has static type #{receiver_type}; .nil? is always false",
          origin_kind: origin_kind, origin_name: origin_name)
      end
      if receiver_type == "NilClass"
        return deterministic_guard_result(true, "nil_check",
          "#{receiver.slice} has static type NilClass; .nil? is always true",
          origin_kind: origin_kind, origin_name: origin_name)
      end
      nil
    end

    def deterministic_class_predicate_result(node)
      return nil unless %i[is_a? kind_of? instance_of?].include?(node.name) && node.receiver
      args = node.arguments&.arguments || []
      return nil unless args.size == 1
      class_name = const_name(args.first)
      return nil if class_name.to_s.empty?
      receiver_type = deterministic_guard_subject_type(node.receiver)
      truth = class_guard_truth(receiver_type, class_name, exact: node.name == :instance_of?)
      return nil if truth.nil?

      origin_kind, origin_name = predicate_origin(node.receiver)
      deterministic_guard_result(truth, "class_guard",
        "#{node.receiver.slice} has static type #{receiver_type}; #{node.name}(#{class_name}) is always #{truth}",
        origin_kind: origin_kind, origin_name: origin_name)
    end

    def class_guard_truth(receiver_type, class_name, exact:)
      raw = receiver_type.to_s
      return nil if raw.empty? || raw == "T.untyped" || raw.include?("T.any(")
      return nil if raw.start_with?("T.nilable(")
      normalized = NilKill.strip_nilable_type(raw)
      return nil if normalized.nil? || normalized.empty?
      bare = bare_class_name(normalized)
      wanted = bare_class_name(class_name.to_s)
      return false if exact && known_disjoint_guard_classes?(bare, wanted)
      return nil if exact
      return true if bare == wanted || known_guard_subclass?(bare, wanted)
      return false if known_disjoint_guard_classes?(bare, wanted)
      nil
    end

    def bare_class_name(type)
      raw = type.to_s
      case raw
      when /\AT::Array\b/, /\AArray\b/ then "Array"
      when /\AT::Hash\b/, /\AHash\b/ then "Hash"
      when /\AT::Set\b/, /\ASet\b/ then "Set"
      when "T::Boolean" then "T::Boolean"
      else raw.delete_prefix("::").split("::").last
      end
    end

    CORE_RUNTIME_GUARD_CLASSES = %w[
      Array Hash Set String Symbol Integer Float NilClass TrueClass FalseClass
      Numeric Range Regexp Time
    ].freeze

    NUMERIC_GUARD_SUBCLASSES = %w[Integer Float].freeze
    BOOLEAN_GUARD_SUBCLASSES = %w[TrueClass FalseClass].freeze

    def known_guard_subclass?(bare, wanted)
      return true if wanted == "Numeric" && NUMERIC_GUARD_SUBCLASSES.include?(bare)
      return true if wanted == "T::Boolean" && BOOLEAN_GUARD_SUBCLASSES.include?(bare)
      false
    end

    def known_disjoint_guard_classes?(bare, wanted)
      return false if bare == wanted
      return false if known_guard_subclass?(bare, wanted) || known_guard_subclass?(wanted, bare)
      return false if bare == "T::Boolean" && BOOLEAN_GUARD_SUBCLASSES.include?(wanted)
      return false if wanted == "T::Boolean" && BOOLEAN_GUARD_SUBCLASSES.include?(bare)
      return true if bare == "T::Boolean" && CORE_RUNTIME_GUARD_CLASSES.include?(wanted)
      return true if wanted == "T::Boolean" && CORE_RUNTIME_GUARD_CLASSES.include?(bare)
      CORE_RUNTIME_GUARD_CLASSES.include?(bare) && CORE_RUNTIME_GUARD_CLASSES.include?(wanted)
    end

    def deterministic_literal_comparison_result(node)
      return nil unless %i[== != > >= < <=].include?(node.name) && node.receiver
      args = node.arguments&.arguments || []
      return nil unless args.size == 1
      left = literal_static_value(node.receiver)
      right = literal_static_value(args.first)
      return nil if left == :__nil_kill_unknown || right == :__nil_kill_unknown
      truth = compare_literal_values(left, right, node.name)
      return nil if truth.nil?
      deterministic_guard_result(truth, "literal_comparison",
        "#{node.receiver.slice} #{node.name} #{args.first.slice} is always #{truth}")
    end

    # Deterministic branch rewrites need a stronger subject type than general
    # return-origin inference. In particular, a call receiver like `node.value`
    # may resolve by method name only (`value`) and collide across unrelated
    # classes. Limit this detector to local/param/ivar/literal subjects whose
    # type is already in the current source-index environment.
    def deterministic_guard_subject_type(node)
      case node
      when Syntax::LocalVariableReadNode
        name = node.name.to_s
        @current_param_types[name] || @current_local_types[name]
      when Syntax::InstanceVariableReadNode
        ivar_expression_type(node.name.to_s)
      else
        static_expression_type(node)
      end
    end

    def literal_static_value(node)
      case node
      when Syntax::StringNode then node.respond_to?(:unescaped) ? node.unescaped : node.slice.delete_prefix("\"").delete_prefix("'").delete_suffix("\"").delete_suffix("'")
      when Syntax::SymbolNode then node.value.to_sym
      when Syntax::IntegerNode then node.value
      when Syntax::FloatNode then node.value
      when Syntax::TrueNode then true
      when Syntax::FalseNode then false
      when Syntax::NilNode then nil
      else :__nil_kill_unknown
      end
    end

    def compare_literal_values(left, right, op)
      case op
      when :== then left == right
      when :!= then left != right
      when :>, :>=, :<, :<=
        return nil unless left.is_a?(Numeric) && right.is_a?(Numeric)
        left.public_send(op, right)
      end
    end

    def predicate_origin(node)
      case node
      when Syntax::LocalVariableReadNode
        name = node.name.to_s
        return ["param", name] if @current_param_types.key?(name)
        return ["local", name] if @current_local_types.key?(name)
      when Syntax::InstanceVariableReadNode
        return ["ivar", node.name.to_s]
      when Syntax::CallNode
        return ["attr", node.name.to_s] if node.receiver && ((node.arguments&.arguments) || []).empty?
        return ["call", node.name.to_s]
      end
      [nil, nil]
    end

    def provably_non_nil?(node)
      case node
      when Syntax::LocalVariableReadNode
        name = node.name.to_s
        @non_nil_locals.include?(name) && !@maybe_nil_locals.include?(name)
      when Syntax::CallNode
        !node.safe_navigation? && @non_nil_method_returns.include?(node.name.to_s)
      when Syntax::SelfNode
        true
      else
        !!non_nil_literal?(node)
      end
    end

  end
end
