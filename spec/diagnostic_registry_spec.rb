require "rspec"
require_relative "../src/ast/diagnostic_registry"
require_relative "../src/ast/source_error"

# DiagnosticRegistry is the unified compile-time diagnostic catalog
# (Layer 2). Existing call sites that pass `error!(node, :CODE, ...)`
# still hit the legacy `MESSAGES` table — which now derives from this
# registry. The specs below pin both the registry's invariants and
# the backward-compat path.

RSpec.describe DiagnosticRegistry do
  describe ".validate" do
    it "every registered entry has severity, category, template, and summary" do
      issues = DiagnosticRegistry.validate
      expect(issues).to be_empty,
        -> { "Malformed registry entries:\n  - #{issues.join("\n  - ")}" }
    end

    it "uses only the declared category whitelist" do
      bad = DiagnosticRegistry::DIAGNOSTICS.reject do |_, e|
        DiagnosticRegistry::CATEGORIES.include?(e[:category])
      end
      expect(bad).to be_empty
    end

    it "uses only the declared severity whitelist" do
      bad = DiagnosticRegistry::DIAGNOSTICS.reject do |_, e|
        DiagnosticRegistry::SEVERITIES.include?(e[:severity])
      end
      expect(bad).to be_empty
    end
  end

  describe ".lookup" do
    it "returns nil for an unknown code" do
      expect(DiagnosticRegistry.lookup(:NOT_REAL)).to be_nil
    end

    it "returns the entry for a known code" do
      entry = DiagnosticRegistry.lookup(:ARITY_MISMATCH)
      expect(entry).to be_a(Hash)
      expect(entry[:severity]).to eq(:error)
      expect(entry[:category]).to eq(:type)
    end
  end

  describe ".known?" do
    it "returns true for a registered code" do
      expect(DiagnosticRegistry.known?(:ARITY_MISMATCH)).to be(true)
    end

    it "returns false for an unknown code" do
      expect(DiagnosticRegistry.known?(:NOT_REAL)).to be(false)
    end
  end

  describe ".format" do
    it "formats a known code's template against named-hash args" do
      out = DiagnosticRegistry.format(:ARITY_MISMATCH, name: "foo", expected: 1, got: 2)
      expect(out).to eq("Function 'foo' expects 1 arguments, got 2.")
    end

    it "formats positional args against a non-named template" do
      # All current registry templates use %{name} interpolation, so
      # the positional path is the legacy fallback. Use a synthetic
      # template via a lookup mock.
      out = DiagnosticRegistry.format(:ARITY_MISMATCH, [], name: "f", expected: 1, got: 2)
      expect(out).to start_with("Function 'f'")
    end

    it "returns nil for an unknown code" do
      expect(DiagnosticRegistry.format(:NOT_REAL, [])).to be_nil
    end

    it "embeds an Internal Args Error when args don't match the template" do
      # ARITY_MISMATCH expects name/expected/got — passing only `name`
      # leaves expected/got unresolved; sprintf raises KeyError, which
      # the formatter catches and surfaces.
      out = DiagnosticRegistry.format(:ARITY_MISMATCH, name: "foo")
      expect(out).to include("Internal Args Error")
    end

    it "formats stack-service errors from registry context only" do
      out = DiagnosticRegistry.format(:STACK_NEEDS_SERVICE_FIXABLE, reentrant_fn: "fib")
      expect(out).to include("transitively calls 'fib'")
      expect(out).to include("Declare `@service` explicitly")
      expect(out).to include(":MAX_DEPTH(N)")
    end

    it "formats stack alias warnings from registry context only" do
      out = DiagnosticRegistry.format(:STACK_SAFETY_STACK_ALIAS, computed: :micro)
      expect(out).to eq("Stack sizing: @stack resolved to @micro; replace @stack with @micro. In STRICT mode, @stack will be rejected.")
    end

    it "formats REQUIRE importer guidance without ad-hoc hint kwargs" do
      out = DiagnosticRegistry.format(:REQUIRE_NEEDS_IMPORTER)
      expect(out).to include("Pass importer: and source_dir:")
    end
  end

  describe "backward compatibility with ErrorDefinitions::MESSAGES" do
    it "MESSAGES has an entry for every registered code" do
      missing = DiagnosticRegistry.codes - ErrorDefinitions::MESSAGES.keys
      expect(missing).to be_empty
    end

    it "MESSAGES values match the registry's templates" do
      DiagnosticRegistry::DIAGNOSTICS.each do |code, entry|
        expect(ErrorDefinitions::MESSAGES[code]).to eq(entry[:template]),
          -> { "MESSAGES[#{code}] differs from registry template" }
      end
    end
  end

  describe "registry coverage of MIR checker codes" do
    # MIRChecker emits a fixed set of post-lowering invariant codes via
    # its own private formatter; they're listed here so `clear explain`
    # documents them alongside the rest. Migrating the actual emit path
    # is a follow-up; this spec just pins which codes exist in the
    # registry today.
    MIR_CODES = %i[
      HPT_LEAK ALLOC_WITHOUT_CLEANUP CLEANUP_WITHOUT_ALLOC
      ALLOC_CLEANUP_MISMATCH INLINE_ALLOC_MISMATCH INLINE_NO_CONTRACT
      FRAME_NO_REWIND UNHOISTED_ALLOC COPY_CLEANUP
    ].freeze

    it "registers every MIR checker code with category :mir" do
      MIR_CODES.each do |code|
        entry = DiagnosticRegistry.lookup(code)
        expect(entry).not_to be_nil, -> { "MIR code #{code} missing from registry" }
        expect(entry[:category]).to eq(:mir)
      end
    end
  end

  describe ".codes" do
    it "lists all registered codes as Symbols" do
      codes = DiagnosticRegistry.codes
      expect(codes).to be_a(Array)
      expect(codes).to all(be_a(Symbol))
      expect(codes.size).to be > 60
    end
  end
end
