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
    it "seeds LockTimeout as Transient with stable id 1" do
      entry = AST::ERROR_TYPES[:LockTimeout]
      expect(entry[:kind]).to eq(:Transient)
      expect(entry[:zig_name]).to eq("LockTimeout")
      expect(entry[:id]).to eq(AST::ERROR_NAME_LOCK_TIMEOUT)
    end

    it "seeds LockCycle as Transient with stable id 2" do
      entry = AST::ERROR_TYPES[:LockCycle]
      expect(entry[:kind]).to eq(:Transient)
      expect(entry[:id]).to eq(AST::ERROR_NAME_LOCK_CYCLE)
    end

    it "seeds Deadlock as System with stable id 3" do
      entry = AST::ERROR_TYPES[:Deadlock]
      expect(entry[:kind]).to eq(:System)
      expect(entry[:id]).to eq(AST::ERROR_NAME_DEADLOCK)
    end

    it "seeds UnexpectedRecursion as System with stable id 4" do
      entry = AST::ERROR_TYPES[:UnexpectedRecursion]
      expect(entry[:kind]).to eq(:System)
      expect(entry[:id]).to eq(AST::ERROR_NAME_UNEXPECTED_RECURSION)
    end

    it "seeds MaxDepthExceeded as System with stable id 5" do
      entry = AST::ERROR_TYPES[:MaxDepthExceeded]
      expect(entry[:kind]).to eq(:System)
      expect(entry[:id]).to eq(AST::ERROR_NAME_MAX_DEPTH_EXCEEDED)
    end

    it "seeds MvccConflict as Transient with stable id 6 (MVCC optimistic-write retry exhausted)" do
      entry = AST::ERROR_TYPES[:MvccConflict]
      expect(entry[:kind]).to eq(:Transient)
      expect(entry[:zig_name]).to eq("MvccConflict")
      expect(entry[:id]).to eq(AST::ERROR_NAME_MVCC_CONFLICT)
    end

    it "seeds AtomicConflict as Transient with stable id 7 (atomic CAS retry exhausted; bound lands in #330)" do
      entry = AST::ERROR_TYPES[:AtomicConflict]
      expect(entry[:kind]).to eq(:Transient)
      expect(entry[:zig_name]).to eq("AtomicConflict")
      expect(entry[:id]).to eq(AST::ERROR_NAME_ATOMIC_CONFLICT)
    end

    it "the legacy Conflict symbol is no longer registered (split into MvccConflict + AtomicConflict)" do
      expect(AST::ERROR_TYPES.key?(:Conflict)).to be false
    end

    it "user types start at id 11 (after the stdlib/control-flow types, incl. OutOfMemory=10)" do
      expect(AST::ERROR_NAME_USER_FIRST).to eq(11)
    end
  end

  describe ".register_type!" do
    around do |example|
      AST.reset_user_types!
      example.run
      AST.reset_user_types!
    end

    it "registers a new user type and assigns the next user id" do
      existed, conflict = AST.register_type!(:ParseError, :Input)
      expect(existed).to be false
      expect(conflict).to be_nil
      expect(AST.kind_of_type(:ParseError)).to eq(:Input)
      expect(AST.id_of_type(:ParseError)).to eq(AST::ERROR_NAME_USER_FIRST)
    end

    it "returns existed=true with no conflict on a matching second registration" do
      AST.register_type!(:ParseError, :Input)
      existed, conflict = AST.register_type!(:ParseError, :Input)
      expect(existed).to be true
      expect(conflict).to be_nil
    end

    it "reports a collision with the existing kind when the second kind differs" do
      AST.register_type!(:ParseError, :Input)
      _, conflict = AST.register_type!(:ParseError, :NotFound)
      expect(conflict).not_to be_nil
      expect(conflict[:existing_kind]).to eq(:Input)
      expect(conflict[:given_kind]).to eq(:NotFound)
      expect(conflict[:is_stdlib]).to be false
    end

    it "flags an attempt to shadow a stdlib type as is_stdlib" do
      _, conflict = AST.register_type!(:LockTimeout, :Input)
      expect(conflict).not_to be_nil
      expect(conflict[:existing_kind]).to eq(:Transient)
      expect(conflict[:is_stdlib]).to be true
    end

    it "accepts re-registering a stdlib type with its own kind" do
      _, conflict = AST.register_type!(:LockTimeout, :Transient)
      expect(conflict).to be_nil
    end

    it "records the first_site token on first registration" do
      tok = Object.new
      AST.register_type!(:ParseError, :Input, site_token: tok)
      expect(AST::ERROR_TYPES[:ParseError][:first_site]).to equal(tok)
    end

    it "assigns distinct ids to different user types in order of registration" do
      AST.register_type!(:A, :Input)
      AST.register_type!(:B, :Input)
      expect(AST.id_of_type(:A)).to eq(AST::ERROR_NAME_USER_FIRST)
      expect(AST.id_of_type(:B)).to eq(AST::ERROR_NAME_USER_FIRST + 1)
    end
  end

  describe ".reset_user_types!" do
    it "removes user types but preserves stdlib entries" do
      AST.register_type!(:UserA, :Input)
      AST.reset_user_types!
      expect(AST.error_type?(:UserA)).to be false
      expect(AST.error_type?(:LockTimeout)).to be true
    end

    it "rewinds the next user id so subsequent user types start at 8" do
      AST.register_type!(:UserA, :Input)
      AST.reset_user_types!
      AST.register_type!(:UserB, :Input)
      expect(AST.id_of_type(:UserB)).to eq(AST::ERROR_NAME_USER_FIRST)
    end
  end

  describe ".enum_entries" do
    around do |example|
      AST.reset_user_types!
      example.run
      AST.reset_user_types!
    end

    it "produces (:Name, id) pairs including the None=0 sentinel and stdlib at 1..3" do
      entries = AST.enum_entries
      expect(entries.first).to eq([:None, 0])
      expect(entries).to include([:LockTimeout, 1])
      expect(entries).to include([:LockCycle, 2])
      expect(entries).to include([:Deadlock, 3])
    end

    it "includes user types at >=11 sorted by id (OutOfMemory=10 is stdlib)" do
      AST.register_type!(:UserA, :Input)
      AST.register_type!(:UserB, :Input)
      entries = AST.enum_entries
      ids = entries.map(&:last)
      expect(ids).to eq(ids.sort)
      expect(entries).to include([:GuardFail, 8])
      expect(entries).to include([:PreconditionFail, 9])
      expect(entries).to include([:OutOfMemory, 10])
      expect(entries).to include([:UserA, 11])
      expect(entries).to include([:UserB, 12])
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
    it "expands :Transient to retryable synchronization and guard-control types" do
      expect(AST.types_for_kind(:Transient).to_set).to eq(Set[:LockTimeout, :LockCycle, :MvccConflict, :AtomicConflict, :GuardFail])
    end

    it "expands :System to include Deadlock" do
      expect(AST.types_for_kind(:System)).to include(:Deadlock)
    end

    it "returns an empty array for kinds with no registered types" do
      AST.reset_user_types!
      # :Input now contains the stdlib PreconditionFail type, so it's
      # no longer empty after a reset.
      expect(AST.types_for_kind(:Input)).to eq([:PreconditionFail])
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
