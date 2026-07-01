# typed: strict

require "sorbet-runtime"

module FsmTransform
  # Marker for the MIR-lowering collaborator used by the FSM splitter and
  # emitter. Production MIRLowering reaches this by including FsmLowering;
  # specs include it on small doubles that implement only the method subset
  # exercised by a given test.
  module LoweringProtocol
  end
end
