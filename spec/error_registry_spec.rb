require "rspec"

require_relative "../src/ast/error_registry"

# Unit tests for AST::ERROR_TYPES and the lookup helpers. The registry is
# the single source of truth for error-kind / error-type classification
# used by the parser, the annotator's handler-reachability check, and the
# mir-lowering runtime emission. A regression here silently miscategorizes
# runtime errors, so direct coverage matters.
RSpec.describe AST do
  describe "ERROR_KINDS" do
    it "contains exactly the 6 documented kinds" do
      expect(AST::ERROR_KINDS).to eq(%i[Transient Input System NotFound Permission Canceled])
    end

    it "does not include legacy names that were removed during the Timeout-kind revert" do
      expect(AST::ERROR_KINDS).not_to include(:Timeout)
    end

    it "is frozen" do
      expect(AST::ERROR_KINDS).to be_frozen
    end
  end

  describe "ERROR_TYPES" do
    it "registers LockTimeout as Transient with Zig spelling 'LockTimeout'" do
      expect(AST::ERROR_TYPES[:LockTimeout]).to eq(kind: :Transient, zig_name: "LockTimeout")
    end

    it "registers LockCycle as Transient with Zig spelling 'LockCycle'" do
      expect(AST::ERROR_TYPES[:LockCycle]).to eq(kind: :Transient, zig_name: "LockCycle")
    end

    it "registers Deadlock as System with Zig spelling 'Deadlock'" do
      expect(AST::ERROR_TYPES[:Deadlock]).to eq(kind: :System, zig_name: "Deadlock")
    end

    it "is frozen" do
      expect(AST::ERROR_TYPES).to be_frozen
    end
  end

  describe ".error_kind?" do
    it "accepts every registered kind" do
      AST::ERROR_KINDS.each { |k| expect(AST.error_kind?(k)).to be true }
    end

    it "rejects unregistered symbols" do
      expect(AST.error_kind?(:LockTimeout)).to be false  # type, not kind
      expect(AST.error_kind?(:Nonsense)).to be false
      expect(AST.error_kind?(nil)).to be false
    end
  end

  describe ".error_type?" do
    it "accepts every registered type" do
      AST::ERROR_TYPES.each_key { |t| expect(AST.error_type?(t)).to be true }
    end

    it "rejects unregistered symbols" do
      expect(AST.error_type?(:Transient)).to be false  # kind, not type
      expect(AST.error_type?(:Imaginary)).to be false
      expect(AST.error_type?(nil)).to be false
    end
  end

  describe ".kind_of_type" do
    it "returns the kind for registered types" do
      expect(AST.kind_of_type(:LockTimeout)).to eq(:Transient)
      expect(AST.kind_of_type(:LockCycle)).to eq(:Transient)
      expect(AST.kind_of_type(:Deadlock)).to eq(:System)
    end

    it "returns nil for unregistered symbols" do
      expect(AST.kind_of_type(:Nonsense)).to be_nil
      expect(AST.kind_of_type(:Transient)).to be_nil  # kind passed as type
    end
  end

  describe ".zig_name_of_type" do
    it "returns the Zig error name used in the runtime" do
      expect(AST.zig_name_of_type(:LockTimeout)).to eq("LockTimeout")
      expect(AST.zig_name_of_type(:LockCycle)).to eq("LockCycle")
      expect(AST.zig_name_of_type(:Deadlock)).to eq("Deadlock")
    end

    it "returns nil for unregistered symbols" do
      expect(AST.zig_name_of_type(:Nonsense)).to be_nil
    end
  end

  describe ".types_for_kind" do
    it "expands :Transient to the two retryable lock types" do
      expect(AST.types_for_kind(:Transient).to_set).to eq(Set[:LockTimeout, :LockCycle])
    end

    it "expands :System to include Deadlock" do
      expect(AST.types_for_kind(:System)).to include(:Deadlock)
    end

    it "returns an empty array for kinds with no registered types" do
      expect(AST.types_for_kind(:Input)).to eq([])
      expect(AST.types_for_kind(:NotFound)).to eq([])
      expect(AST.types_for_kind(:Permission)).to eq([])
      expect(AST.types_for_kind(:Canceled)).to eq([])
    end

    it "returns [] for an unregistered kind rather than raising" do
      expect(AST.types_for_kind(:Nonsense)).to eq([])
    end
  end

  describe "consistency between kinds and types" do
    it "every type's kind is a registered ErrorKind" do
      AST::ERROR_TYPES.each do |type_sym, meta|
        expect(AST.error_kind?(meta[:kind])).to(be(true),
          "type #{type_sym.inspect} has unregistered kind #{meta[:kind].inspect}")
      end
    end

    it "types_for_kind is the inverse of kind_of_type" do
      AST::ERROR_TYPES.each_key do |type_sym|
        kind = AST.kind_of_type(type_sym)
        expect(AST.types_for_kind(kind)).to include(type_sym)
      end
    end

    it "zig_name is non-empty for every registered type" do
      AST::ERROR_TYPES.each do |type_sym, meta|
        expect(meta[:zig_name]).to(be_a(String).and(satisfy { |s| !s.empty? }),
          "type #{type_sym.inspect} has missing or empty zig_name")
      end
    end
  end
end
