# typed: strict
require "sorbet-runtime"

require_relative "../ast/ast"

module Semantic
  class DefId < T::Struct
    const :value, Integer
  end

  class BodyId < T::Struct
    const :value, Integer
  end

  class ScopeId < T::Struct
    const :value, Integer
  end

  class LocalId < T::Struct
    const :value, Integer
  end

  class PlaceId < T::Struct
    const :value, Integer
  end

  class CallSiteId < T::Struct
    const :value, Integer
  end

  class SuspendPointId < T::Struct
    const :value, Integer
  end

  class PredicateId < T::Struct
    const :value, Integer
  end

  class CapabilityId < T::Struct
    const :value, Integer
  end

  class SyntheticLocalId < T::Struct
    const :value, Integer
  end

  UNASSIGNED_DEF_ID = T.let(DefId.new(value: 0), DefId)
  UNASSIGNED_BODY_ID = T.let(BodyId.new(value: 0), BodyId)
  UNASSIGNED_SCOPE_ID = T.let(ScopeId.new(value: 0), ScopeId)
  UNASSIGNED_LOCAL_ID = T.let(LocalId.new(value: 0), LocalId)
  UNASSIGNED_PLACE_ID = T.let(PlaceId.new(value: 0), PlaceId)
  UNASSIGNED_CALL_SITE_ID = T.let(CallSiteId.new(value: 0), CallSiteId)
  UNASSIGNED_SUSPEND_POINT_ID = T.let(SuspendPointId.new(value: 0), SuspendPointId)
  UNASSIGNED_PREDICATE_ID = T.let(PredicateId.new(value: 0), PredicateId)
  UNASSIGNED_CAPABILITY_ID = T.let(CapabilityId.new(value: 0), CapabilityId)
  UNASSIGNED_SYNTHETIC_LOCAL_ID = T.let(SyntheticLocalId.new(value: 0), SyntheticLocalId)
  BODY_ID_STRIDE = 1_000_000

  class BodyIdentity < T::Struct
    extend T::Sig

    const :definition_id, DefId
    const :body_id, BodyId

    sig { returns(BodyIdentity) }
    def self.unassigned
      new(definition_id: UNASSIGNED_DEF_ID, body_id: UNASSIGNED_BODY_ID)
    end

    sig { params(ordinal: Integer).returns(BodyIdentity) }
    def self.for_ordinal(ordinal)
      new(definition_id: DefId.new(value: ordinal), body_id: BodyId.new(value: ordinal))
    end
  end

  class CallSiteFact < T::Struct
    const :id, CallSiteId
    const :node, AST::FuncCall
    const :callee_name, String
    const :args, T::Array[AST::Node]
    const :fn_var_call, T::Boolean
    const :propagates_failure, T::Boolean
  end

  class LocalFact < T::Struct
    const :id, LocalId
    const :place_id, PlaceId
    const :name, String
  end

  class SuspendPointFact < T::Struct
    const :id, SuspendPointId
    const :kind, Symbol
    const :node, AST::Locatable
  end

  class SemanticIdIndex < T::Struct
    extend T::Sig

    const :definitions, T::Hash[String, DefId], factory: -> { {} }
    const :bodies, T::Hash[String, BodyId], factory: -> { {} }

    sig { params(name: String).returns(T.nilable(DefId)) }
    def definition_id_for(name)
      definitions[name]
    end

    sig { params(name: String).returns(T.nilable(BodyId)) }
    def body_id_for(name)
      bodies[name]
    end
  end
end
