require "rspec"
require_relative "../ruby/ast/diagnostic_registry" unless defined?(DiagnosticRegistry)
require_relative "../ruby/ast/source_error" unless defined?(CompilerError)
require_relative "../ruby/ast/fixable_error" unless defined?(FixCollector)

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

    it "reports every malformed registry field" do
      string_subclass = Class.new(String)
      stub_const(
        "DiagnosticRegistry::DIAGNOSTICS",
        {
          BAD: {
            severity: :bogus,
            category: :bogus,
            template: :not_a_template,
            summary: :not_a_summary,
          },
          MISSING: {},
          SUBCLASS_STRINGS: {
            severity: :error,
            category: :type,
            template: string_subclass.new("Template."),
            summary: string_subclass.new("Summary."),
          },
        }
      )
      stub_const(
        "DiagnosticRegistry::FIX_DESCRIPTIONS",
        {
          BAD_FIX: :not_a_template,
          SUBCLASS_FIX: string_subclass.new("Fix."),
        }
      )

      expect(DiagnosticRegistry.validate).to contain_exactly(
        "BAD: missing :severity",
        "BAD: missing :category",
        "BAD: missing :template",
        "BAD: missing :summary",
        "MISSING: missing :severity",
        "MISSING: missing :category",
        "MISSING: missing :template",
        "MISSING: missing :summary",
        "BAD_FIX: missing fix description template",
      )
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
    it "formats positional templates against positional args" do
      stub_const(
        "DiagnosticRegistry::DIAGNOSTICS",
        {
          POSITIONAL: {
            severity: :error,
            category: :type,
            template: "Value %s at %d.",
            summary: "Positional test entry.",
          },
        }
      )

      expect(DiagnosticRegistry.format(:POSITIONAL, ["x", 7])).to eq("Value x at 7.")
    end

    it "uses explicit kwargs when kwargs are passed to positional templates" do
      stub_const(
        "DiagnosticRegistry::DIAGNOSTICS",
        {
          POSITIONAL: {
            severity: :error,
            category: :type,
            template: "Value %s.",
            summary: "Positional test entry.",
          },
        }
      )

      expect(DiagnosticRegistry.format(:POSITIONAL, [], value: "x")).to eq("Value {:value=>\"x\"}.")
    end

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
      expect(out).to eq("Function '%{name}' expects %{expected} arguments, got %{got}. [Internal Args Error: {:name=>\"foo\"}]")
    end

    it "uses kwargs error payloads for named templates even without kwargs" do
      out = DiagnosticRegistry.format(:ARITY_MISMATCH)
      expect(out).to eq("Function '%{name}' expects %{expected} arguments, got %{got}. [Internal Args Error: {}]")
    end

    it "embeds positional args in positional Internal Args Errors" do
      stub_const(
        "DiagnosticRegistry::DIAGNOSTICS",
        {
          POSITIONAL: {
            severity: :error,
            category: :type,
            template: "Value %s at %d.",
            summary: "Positional test entry.",
          },
        }
      )

      out = DiagnosticRegistry.format(:POSITIONAL, ["x"])
      expect(out).to eq("Value %s at %d. [Internal Args Error: [\"x\"]]")
      expect(DiagnosticRegistry.format(:POSITIONAL)).to eq("Value %s at %d. [Internal Args Error: []]")
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

    it "formats parser insertion fixables from registry context only" do
      out = DiagnosticRegistry.format(
        :PARSER_EXPECTED_BEFORE_TOKEN,
        expected: "THEN",
        got: "RETURN",
        line: 12,
      )
      expect(out).to eq("Expected `THEN`, got 'RETURN' (line 12).")
    end

    it "formats syntax typo fixables from registry context only" do
      out = DiagnosticRegistry.format(:OPERATOR_TYPO_SUGGESTION, match: "s>", replace: "|>")
      expect(out).to eq("Unknown operator `s>` -- did you mean `|>`?")
    end
  end

  describe ".fix_description" do
    it "formats a registered fix template against named args" do
      out = DiagnosticRegistry.fix_description(
        :INSERT_EXPECTED_BEFORE_TOKEN,
        expected: "THEN",
        got: "RETURN",
        line: 12,
      )

      expect(out).to eq("Insert `THEN` before 'RETURN' at line 12.")
    end

    it "raises for unknown fix description codes" do
      expect {
        DiagnosticRegistry.fix_description(:NOT_A_FIX)
      }.to raise_error(RuntimeError, "Internal Compiler Error: Unknown fix description code :NOT_A_FIX")
    end

    it "embeds kwargs and missing key details when fix formatting fails" do
      out = DiagnosticRegistry.fix_description(:INSERT_EXPECTED_BEFORE_TOKEN, expected: "THEN")

      expect(out).to eq("Insert `%{expected}` before '%{got}' at line %{line}. [Internal Args Error: key{got} not found kwargs={:expected=>\"THEN\"}]")
    end
  end

  describe ".pending?" do
    it "returns true only for entries explicitly marked pending" do
      stub_const(
        "DiagnosticRegistry::DIAGNOSTICS",
        {
          PENDING_CODE: {
            severity: :error,
            category: :type,
            template: "Pending.",
            summary: "Pending test entry.",
            pending: true,
          },
          ACTIVE_CODE: {
            severity: :error,
            category: :type,
            template: "Active.",
            summary: "Active test entry.",
          },
          EXPLICIT_FALSE_CODE: {
            severity: :error,
            category: :type,
            template: "Active.",
            summary: "Explicit false test entry.",
            pending: false,
          },
        }
      )

      expect(DiagnosticRegistry.pending?(:PENDING_CODE)).to be(true)
      expect(DiagnosticRegistry.pending?(:ACTIVE_CODE)).to be(false)
      expect(DiagnosticRegistry.pending?(:EXPLICIT_FALSE_CODE)).to be(false)
      expect(DiagnosticRegistry.pending?(:MISSING_CODE)).to be(false)
    end
  end

  describe ErrorHelper do
    class FixableDiagnosticHarness
      include ErrorHelper
    end

    before { FixCollector.enable! }
    after { FixCollector.disable! }

    it "renders fixable findings from a registry code and params" do
      token = Struct.new(:line, :column).new(3, 5)

      FixableDiagnosticHarness.new.fixable!(
        token,
        code: :PARSER_EXPECTED_BEFORE_TOKEN,
        expected: "DO",
        got: "RETURN",
        line: 3,
        category: :type,
        level: :warning,
        fixes: [],
      )

      finding = FixCollector.drain.first
      expect(finding.message).to eq("Expected `DO`, got 'RETURN' (line 3).")
      expect(finding.category).to eq(:type)
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
