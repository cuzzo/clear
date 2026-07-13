module MIRLoweringControlFlow
  extend T::Sig

  sig do
    params(
      node: AST::MatchStatement,
      facts: MatchLoweringFacts,
      arms: T::Array[UnionMatchArmPlan],
    ).returns(T.untyped)
  end
  def union_match_default_body(node, facts, arms)
    T.bind(self, MIRLowering) rescue nil
    schema = union_schemas[facts.expr_type_sym]
    all_variants = schema&.variants&.keys&.map(&:to_s)&.sort || []
    all_variants
  end

  sig { params(required: String).returns(T::Boolean) }
  def missing?(required)
    required.nil?
  end
end
