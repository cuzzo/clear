# typed: strict
# frozen_string_literal: true

require "json"
require "digest"
require "fileutils"
require "open3"
require "securerandom"
require "sorbet-runtime"
require "tmpdir"
require_relative "scope"
require_relative "counterfactual"

module TestMiser
  module Evidence
    class InvalidOracleFacts < ArgumentError; end

    class SourceSpan < T::Struct
      extend T::Sig

      const :start_line, Integer
      const :start_column, Integer
      const :end_line, Integer
      const :end_column, Integer
      const :start_offset, T.nilable(Integer), default: nil
      const :end_offset, T.nilable(Integer), default: nil

      sig { returns(T::Hash[String, T.untyped]) }
      def to_h
        {
          "start_line" => start_line,
          "start_column" => start_column,
          "end_line" => end_line,
          "end_column" => end_column,
          "start_offset" => start_offset,
          "end_offset" => end_offset,
        }.compact
      end
    end

    class OracleKind < T::Enum
      enums do
        Equality = new("EQUALITY")
        Identity = new("IDENTITY")
        Truthiness = new("TRUTHINESS")
        NullCheck = new("NULL_CHECK")
        ExceptionExpectation = new("EXCEPTION_EXPECTATION")
        Snapshot = new("SNAPSHOT")
        MockVerification = new("MOCK_VERIFICATION")
        Property = new("PROPERTY")
        CompileFailure = new("COMPILE_FAILURE")
        SubprocessOutput = new("SUBPROCESS_OUTPUT")
        Unknown = new("UNKNOWN")
      end
    end

    class OracleFact < T::Struct
      extend T::Sig

      const :oracle_id, String
      const :test_id, String
      const :oracle_kind, OracleKind
      const :oracle_span, SourceSpan
      const :expected_span, T.nilable(SourceSpan), default: nil
      const :actual_span, T.nilable(SourceSpan), default: nil
      const :framework, String
      const :confidence, Float
      const :source_file, T.nilable(String), default: nil

      sig { returns(T::Hash[String, T.untyped]) }
      def to_h
        {
          "oracle_id" => oracle_id,
          "test_id" => test_id,
          "oracle_kind" => oracle_kind.serialize,
          "oracle_span" => oracle_span.to_h,
          "expected_span" => expected_span&.to_h,
          "actual_span" => actual_span&.to_h,
          "framework" => framework,
          "confidence" => confidence,
          "source_file" => source_file,
        }.compact
      end
    end

    class OracleFacts < T::Struct
      extend T::Sig

      const :facts, T::Array[OracleFact]
      const :metadata, T::Hash[String, T.untyped], default: {}

      sig { returns(T::Hash[String, T.untyped]) }
      def to_h
        validate_unique_ids!
        {"schema" => "test-quality-oracle-facts/v1", "facts" => facts.map(&:to_h), "metadata" => metadata}
      end

      sig { returns(T::Array[OracleFact]) }
      def validate_unique_ids!
        duplicates = facts.group_by(&:oracle_id).select { |_id, rows| rows.length > 1 }.keys.sort
        raise InvalidOracleFacts, "duplicate oracle IDs: #{duplicates.join(', ')}" unless duplicates.empty?

        facts
      end

      sig { params(path: String).returns(OracleFacts) }
      def self.load(path)
        payload = JSON.parse(File.read(path))
        unless payload["schema"] == "test-quality-oracle-facts/v1" && payload["facts"].is_a?(Array)
          raise InvalidOracleFacts, "#{path}: expected test-quality-oracle-facts/v1"
        end

        artifact = new(
          facts: payload.fetch("facts").map { |row| parse_fact(row) }.freeze,
          metadata: payload.fetch("metadata", {}),
        )
        artifact.validate_unique_ids!
        artifact
      rescue JSON::ParserError => error
        raise InvalidOracleFacts, "#{path}: invalid JSON: #{error.message}"
      end

      sig { params(rows: T::Array[T.untyped], metadata: T::Hash[String, T.untyped]).returns(OracleFacts) }
      def self.from_rows(rows, metadata: {})
        artifact = new(facts: rows.map { |row| parse_fact(row) }.freeze, metadata: metadata)
        artifact.validate_unique_ids!
        artifact
      end

      sig { params(path: String).void }
      def write(path)
        File.write(path, "#{JSON.pretty_generate(to_h)}\n")
      end

      class << self
        extend T::Sig

        private

        sig { params(row: T.untyped).returns(OracleFact) }
        def parse_fact(row)
          unless row.is_a?(Hash)
            raise InvalidOracleFacts, "oracle fact must be an object"
          end

          OracleFact.new(
            oracle_id: nonempty_string(row.fetch("oracle_id"), "oracle_id"),
            test_id: nonempty_string(row.fetch("test_id"), "test_id"),
            oracle_kind: OracleKind.deserialize(String(row.fetch("oracle_kind"))),
            oracle_span: parse_span(row.fetch("oracle_span")),
            expected_span: optional_span(row["expected_span"]),
            actual_span: optional_span(row["actual_span"]),
            framework: nonempty_string(row.fetch("framework"), "framework"),
            confidence: confidence(row.fetch("confidence")),
            source_file: row["source_file"]&.to_s,
          )
        rescue KeyError, TypeError, ArgumentError => error
          raise InvalidOracleFacts, "invalid oracle fact: #{error.message}"
        end

        sig { params(row: T.untyped).returns(SourceSpan) }
        def parse_span(row)
          unless row.is_a?(Hash)
            raise InvalidOracleFacts, "oracle span must be an object"
          end

          start_line = Integer(row.fetch("start_line"))
          start_column = Integer(row.fetch("start_column"))
          end_line = Integer(row.fetch("end_line"))
          end_column = Integer(row.fetch("end_column"))
          start_offset = optional_integer(row["start_offset"])
          end_offset = optional_integer(row["end_offset"])
          unless start_line.positive? && start_column.positive? && end_line.positive? && end_column.positive?
            raise InvalidOracleFacts, "oracle span positions must be positive"
          end
          unless end_line > start_line || (end_line == start_line && end_column >= start_column)
            raise InvalidOracleFacts, "oracle span end must not precede its start"
          end
          if start_offset && start_offset.negative? || end_offset && end_offset.negative?
            raise InvalidOracleFacts, "oracle span offsets must not be negative"
          end
          if start_offset && end_offset && end_offset < start_offset
            raise InvalidOracleFacts, "oracle span end offset must not precede its start offset"
          end

          SourceSpan.new(
            start_line: start_line,
            start_column: start_column,
            end_line: end_line,
            end_column: end_column,
            start_offset: start_offset,
            end_offset: end_offset,
          )
        end

        sig { params(value: T.untyped, label: String).returns(String) }
        def nonempty_string(value, label)
          text = String(value)
          raise InvalidOracleFacts, "#{label} must not be empty" if text.empty?

          text
        end

        sig { params(value: T.untyped).returns(Float) }
        def confidence(value)
          parsed = Float(value)
          raise InvalidOracleFacts, "confidence must be finite and between 0 and 1" unless parsed.finite? && parsed.between?(0.0, 1.0)

          parsed
        end

        sig { params(value: T.untyped).returns(T.nilable(SourceSpan)) }
        def optional_span(value)
          return nil if value.nil?

          parse_span(value)
        end

        sig { params(value: T.untyped).returns(T.nilable(Integer)) }
        def optional_integer(value)
          return nil if value.nil?

          Integer(value)
        end
      end
    end

    module OracleFactProvider
      extend T::Sig
      extend T::Helpers
      interface!

      sig do
        abstract.params(test_id: String, source_path: String, language: String).returns(T::Array[OracleFact])
      end
      def facts(test_id:, source_path:, language:)
      end
    end

    class StaticOracleFactProvider
      extend T::Sig
      include OracleFactProvider

      sig { params(artifact: OracleFacts).void }
      def initialize(artifact)
        @artifact = artifact
      end

      sig do
        override.params(test_id: String, source_path: String, language: String).returns(T::Array[OracleFact])
      end
      def facts(test_id:, source_path:, language:)
        @artifact.facts.select do |fact|
          fact.test_id == test_id && (fact.source_file.nil? || fact.source_file == source_path)
        end
      end
    end

    module OracleFramework
      extend T::Sig

      MINITEST = T.let({
        "assert" => OracleKind::Truthiness,
        "assert_equal" => OracleKind::Equality,
        "assert_same" => OracleKind::Identity,
        "assert_nil" => OracleKind::NullCheck,
        "refute_nil" => OracleKind::NullCheck,
        "refute" => OracleKind::Truthiness,
        "assert_raises" => OracleKind::ExceptionExpectation,
        "assert_output" => OracleKind::SubprocessOutput,
      }.freeze, T::Hash[String, OracleKind])
      RSPEC = T.let({
        "expect" => OracleKind::Equality,
        "eq" => OracleKind::Equality,
        "eql" => OracleKind::Equality,
        "be_nil" => OracleKind::NullCheck,
        "raise_error" => OracleKind::ExceptionExpectation,
        "have_received" => OracleKind::MockVerification,
      }.freeze, T::Hash[String, OracleKind])
      PYTEST = T.let({
        "assert" => OracleKind::Truthiness,
        "assert_equal" => OracleKind::Equality,
        "assert_raises" => OracleKind::ExceptionExpectation,
      }.freeze, T::Hash[String, OracleKind])
      UNITTEST = T.let({
        "assertEqual" => OracleKind::Equality,
        "assertIs" => OracleKind::Identity,
        "assertTrue" => OracleKind::Truthiness,
        "assertFalse" => OracleKind::Truthiness,
        "assertIsNone" => OracleKind::NullCheck,
        "assertRaises" => OracleKind::ExceptionExpectation,
      }.freeze, T::Hash[String, OracleKind])
      JUNIT = T.let({
        "assertEquals" => OracleKind::Equality,
        "assertSame" => OracleKind::Identity,
        "assertTrue" => OracleKind::Truthiness,
        "assertFalse" => OracleKind::Truthiness,
        "assertNull" => OracleKind::NullCheck,
        "assertThrows" => OracleKind::ExceptionExpectation,
      }.freeze, T::Hash[String, OracleKind])
      JEST = T.let({
        "expect" => OracleKind::Equality,
        "toEqual" => OracleKind::Equality,
        "toStrictEqual" => OracleKind::Equality,
        "toBe" => OracleKind::Identity,
        "toBeTruthy" => OracleKind::Truthiness,
        "toBeFalsy" => OracleKind::Truthiness,
        "toBeNull" => OracleKind::NullCheck,
        "toThrow" => OracleKind::ExceptionExpectation,
      }.freeze, T::Hash[String, OracleKind])

      sig { params(source: String, language: String, override: T.nilable(String)).returns(T.nilable(String)) }
      def self.detect(source, language, override: nil)
        return override unless override.nil? || override.empty?

        text = source
        case language.downcase
        when "ruby"
          return "minitest" if text.match?(/Minitest::Test|require\s*[\(\s][\"']minitest/)
          return "rspec" if text.match?(/RSpec\.describe|require\s*[\(\s][\"']rspec/)
        when "python"
          return "unittest" if text.match?(/(?:import\s+unittest|from\s+unittest\b|unittest\.TestCase)/)
          return "pytest" if text.match?(/(?:import\s+pytest|from\s+pytest\b)/)
        when "java", "kotlin"
          return "junit" if text.match?(/org\.junit|@(?:Test|ParameterizedTest)\b/)
        when "javascript", "typescript"
          return "jest" if text.match?(/(?:from\s*[\"'](?:@jest\/globals|vitest)|require\s*[\(\s][\"'](?:@jest|vitest))/)
        end
        nil
      end

      sig { params(framework: String, call: T.untyped).returns(T.nilable(OracleKind)) }
      def self.kind(framework, call)
        table = case framework
                when "minitest" then MINITEST
                when "rspec" then RSPEC
                when "pytest" then PYTEST
                when "unittest" then UNITTEST
                when "junit" then JUNIT
                when "jest" then JEST
                else {}
                end
        return nil unless framework_receiver_allowed?(framework, call)

        message = call.is_a?(Hash) ? call["message"] : call
        table[message.to_s]
      end

      sig { params(framework: String, call: T.untyped).returns(T::Boolean) }
      def self.framework_receiver_allowed?(framework, call)
        return true unless call.is_a?(Hash)

        receiver = call["receiver"].to_s
        owner = call["owner"].to_s
        return false unless receiver.empty? || %w[self this].include?(receiver)

        return owner.empty? || owner.end_with?("Test") if framework == "minitest"
        return owner.empty? || owner.end_with?("TestCase") if framework == "unittest"
        return owner.empty? || owner.match?(/(?:Spec|_spec)\z/i) if framework == "rspec"

        true
      end
    end

    # FactMine's normalized syntax-facts output is deliberately provider-neutral.
    # This adapter turns assertion-shaped call facts into the TestMiser oracle
    # schema without claiming recognition for calls it cannot classify.
    class FactMineOracleFactProvider
      extend T::Sig
      include OracleFactProvider

      sig { params(binary: String, runner: T.untyped, framework: T.nilable(String)).void }
      def initialize(binary: ENV.fetch("FACT_MINE_RUST_BINARY", "gems/fact-mine/target/release/fact-mine-rust"), runner: Open3, framework: nil)
        @binary = binary
        @runner = runner
        @framework = framework
      end

      sig do
        override.params(test_id: String, source_path: String, language: String).returns(T::Array[OracleFact])
      end
      def facts(test_id:, source_path:, language:)
        stdout, stderr, status = @runner.capture3(@binary, "syntax-facts", "--language", language, source_path)
        raise InvalidOracleFacts, "FactMine failed for #{source_path}: #{stderr}" unless status.success?

        payload = JSON.parse(stdout)
        framework = OracleFramework.detect(File.read(source_path), language, override: @framework)
        return [] if framework.nil?
        calls = Array(payload["documents"]).flat_map { |document| Array(document["calls"]) }
        calls.filter_map.with_index do |call, index|
          kind = OracleFramework.kind(framework, call)
          next if kind.nil?

          span = factmine_span(call["span"])
          OracleFact.new(
            oracle_id: "factmine:#{Digest::SHA256.hexdigest("#{source_path}:#{index}:#{span.to_h}")[0, 16]}",
            test_id: test_id,
            oracle_kind: kind,
            oracle_span: span,
            framework: framework,
            confidence: 0.90,
            source_file: source_path,
          )
        end
      rescue JSON::ParserError => error
        raise InvalidOracleFacts, "FactMine returned invalid JSON: #{error.message}"
      end

      private

      sig { params(raw: T.untyped).returns(SourceSpan) }
      def factmine_span(raw)
        values = Array(raw).map(&:to_i)
        raise InvalidOracleFacts, "FactMine oracle span is missing" unless values.length == 4

        SourceSpan.new(
          start_line: [values[0], 1].max,
          start_column: [values[1], 1].max,
          end_line: [values[2], 1].max,
          end_column: [values[3], 1].max,
        )
      end
    end

    # Tree-sitter is used for framework-specific syntax recognition when a
    # FactMine binary is unavailable or a framework needs a narrower query.
    # Grammar shared libraries are supplied explicitly (TREE_SITTER_RUBY_PATH,
    # etc.); silently falling back to regex would make a positive oracle claim
    # unsound.
    class TreeSitterOracleFactProvider
      extend T::Sig
      include OracleFactProvider

      sig { params(grammar_paths: T::Hash[String, String], framework: T.nilable(String)).void }
      def initialize(grammar_paths: {}, framework: nil)
        @grammar_paths = grammar_paths
        @framework = framework
      end

      sig do
        override.params(test_id: String, source_path: String, language: String).returns(T::Array[OracleFact])
      end
      def facts(test_id:, source_path:, language:)
        require "tree_sitter"
        grammar = @grammar_paths[language] || ENV["TREE_SITTER_#{language.upcase}_PATH"] || ENV["DECOMPLEX_TS_#{language.upcase}_PATH"]
        raise InvalidOracleFacts, "Tree-sitter grammar path is required for #{language}" if grammar.to_s.empty?

        tree_sitter = T.unsafe(Object.const_get(:TreeSitter))
        tree_sitter.register_language(language, grammar) unless tree_sitter.languages.include?(language)
        parser = tree_sitter.const_get(:Parser).new
        parser.language = language
        source = File.read(source_path)
        framework = OracleFramework.detect(source, language, override: @framework)
        return [] if framework.nil?
        tree = parser.parse(source)
        raise InvalidOracleFacts, "Tree-sitter could not parse #{source_path}" if tree.nil?

        calls = []
        walk_tree(tree.root_node) do |node|
          calls << node if node.kind == "call" ||
            (node.kind == "body_statement" && node.children.any? { |child| child.kind == "argument_list" } && node.children.first&.kind == "identifier")
        end
        calls.filter_map.with_index do |node, index|
          method_node = node.child_by_field_name("method") || node.child_by_field_name("function") || node.children.find { |child| child.kind == "identifier" }
          kind = OracleFramework.kind(framework, method_node&.text)
          next if kind.nil?

          span = tree_span(node)
          OracleFact.new(
            oracle_id: "tree-sitter:#{Digest::SHA256.hexdigest("#{source_path}:#{index}:#{node.start_byte}")[0, 16]}",
            test_id: test_id,
            oracle_kind: kind,
            oracle_span: span,
            framework: framework,
            confidence: 0.85,
            source_file: source_path,
          )
        end
      rescue LoadError => error
        raise InvalidOracleFacts, "Tree-sitter Ruby binding is unavailable: #{error.message}"
      end

      private

      sig { params(node: T.untyped, block: T.proc.params(node: T.untyped).void).void }
      def walk_tree(node, &block)
        yield node
        node.children.each { |child| walk_tree(child, &block) }
      end

      sig { params(node: T.untyped).returns(SourceSpan) }
      def tree_span(node)
        SourceSpan.new(
          start_line: node.start_point.row + 1,
          start_column: node.start_point.column + 1,
          end_line: node.end_point.row + 1,
          end_column: node.end_point.column + 1,
          start_offset: node.start_byte,
          end_offset: node.end_byte,
        )
      end

    end

    class OracleMutationKind < T::Enum
      enums do
        DisableOracle = new("DISABLE_ORACLE")
        NegateBoolean = new("NEGATE_BOOLEAN")
        PerturbExpected = new("PERTURB_EXPECTED")
        RemoveInvocation = new("REMOVE_INVOCATION")
        BroadenException = new("BROADEN_EXCEPTION")
        RemoveVerification = new("REMOVE_VERIFICATION")
        PerturbSnapshot = new("PERTURB_SNAPSHOT")
      end
    end

    class OracleMutationPlan < T::Struct
      extend T::Sig

      const :oracle_id, String
      const :mutation, OracleMutationKind
      const :recognized, T::Boolean
      const :reason, String

      sig { returns(T::Hash[String, T.untyped]) }
      def to_h
        {
          "oracle_id" => oracle_id,
          "mutation" => mutation.serialize,
          "recognized" => recognized,
          "reason" => reason,
        }
      end
    end

    class OracleRewrite < T::Struct
      extend T::Sig

      const :oracle_id, String
      const :mutation, OracleMutationKind
      const :recognized, T::Boolean
      const :applied, T::Boolean
      const :reason, String

      sig { returns(T::Hash[String, T.untyped]) }
      def to_h
        {
          "oracle_id" => oracle_id,
          "mutation" => mutation.serialize,
          "recognized" => recognized,
          "applied" => applied,
          "reason" => reason,
        }
      end

      sig { returns(String) }
      def id
        "#{oracle_id}:#{mutation.serialize}"
      end
    end

    module OracleRewriteAdapter
      extend T::Sig
      extend T::Helpers
      interface!

      sig do
        abstract.params(fact: OracleFact, plan: OracleMutationPlan, source: String, language: String).returns([String, OracleRewrite])
      end
      def rewrite(fact:, plan:, source:, language:)
      end
    end

    class ConservativeOracleRewriteAdapter
      extend T::Sig
      include OracleRewriteAdapter

      sig do
        override.params(fact: OracleFact, plan: OracleMutationPlan, source: String, language: String).returns([String, OracleRewrite])
      end
      def rewrite(fact:, plan:, source:, language:)
        unless plan.recognized
          return [source, OracleRewrite.new(oracle_id: fact.oracle_id, mutation: plan.mutation, recognized: false, applied: false, reason: plan.reason)]
        end

        span = plan.mutation == OracleMutationKind::PerturbExpected ? fact.expected_span : fact.oracle_span
        offsets = source_offsets(source, span)
        unless offsets
          return [source, OracleRewrite.new(oracle_id: fact.oracle_id, mutation: plan.mutation, recognized: true, applied: false, reason: "oracle span has no valid source range")]
        end

        start_offset, end_offset = offsets
        original = source.byteslice(start_offset...end_offset).to_s
        replacement = replacement_for(plan.mutation, original, language, fact.framework)
        rewritten = source.dup
        rewritten[start_offset...end_offset] = replacement
        [rewritten, OracleRewrite.new(oracle_id: fact.oracle_id, mutation: plan.mutation, recognized: true, applied: true, reason: "conservative source rewrite applied")]
      rescue StandardError => error
        [source, OracleRewrite.new(oracle_id: fact.oracle_id, mutation: plan.mutation, recognized: true, applied: false, reason: "rewrite rejected: #{error.message}")]
      end

      private

      sig { params(source: String, span: T.nilable(SourceSpan)).returns(T.nilable([Integer, Integer])) }
      def source_offsets(source, span)
        return nil if span.nil?
        return [T.must(span.start_offset), T.must(span.end_offset)] if span.start_offset && span.end_offset

        lines = source.lines
        return nil if span.start_line > lines.length || span.end_line > lines.length

        start_offset = lines.first(span.start_line - 1).sum(&:bytesize) + character_offset(T.must(lines[span.start_line - 1]), span.start_column)
        end_offset = lines.first(span.end_line - 1).sum(&:bytesize) + character_offset(T.must(lines[span.end_line - 1]), span.end_column)
        return nil if start_offset > end_offset || end_offset > source.bytesize

        [start_offset, end_offset]
      end

      sig { params(line: String, column: Integer).returns(Integer) }
      def character_offset(line, column)
        line.byteslice(0, [column - 1, 0].max).to_s.bytesize
      end

      sig { params(mutation: OracleMutationKind, original: String, language: String, framework: String).returns(String) }
      def replacement_for(mutation, original, language, framework)
        case mutation
        when OracleMutationKind::DisableOracle
          return "nil" if language.downcase == "ruby" && %w[minitest rspec].include?(framework)
          return "pass" if language.downcase == "python" && %w[pytest unittest].include?(framework)
          return "void 0" if %w[javascript typescript].include?(language.downcase) && framework == "jest"
          return ";" if %w[java kotlin].include?(language.downcase) && framework == "junit"

          raise ArgumentError, "no safe oracle-disabling adapter for #{framework}/#{language}"
        when OracleMutationKind::NegateBoolean
          if language.downcase == "ruby" && framework == "minitest"
            return original.sub(/\bassert_equal\b/, "refute_equal") if original.match?(/\bassert_equal\b/)
            return original.sub(/\bassert_same\b/, "refute_same") if original.match?(/\bassert_same\b/)
            return original.sub(/\bassert\b/, "refute") if original.match?(/\bassert\b/)
            return original.sub(/\brefute\b/, "assert") if original.match?(/\brefute\b/)
          end

          if language.downcase == "ruby" && framework == "rspec"
            return original.sub(/\bto\s+eq\b/, "to_not eq") if original.match?(/\bto\s+eq\b/)
            return original.sub(/\bto\s+eql\b/, "to_not eql") if original.match?(/\bto\s+eql\b/)
          end

          if language.downcase == "python" && framework == "unittest"
            return original.sub(/\bassertEqual\b/, "assertNotEqual") if original.match?(/\bassertEqual\b/)
            return original.sub(/\bassertTrue\b/, "assertFalse") if original.match?(/\bassertTrue\b/)
            return original.sub(/\bassertFalse\b/, "assertTrue") if original.match?(/\bassertFalse\b/)
          end

          if language.downcase == "python" && framework == "pytest" && original.lstrip.start_with?("assert ")
            indent = original[/\A\s*/].to_s
            expression = original.lstrip.delete_prefix("assert ").strip
            return "#{indent}assert not (#{expression})"
          end

          if %w[javascript typescript].include?(language.downcase) && framework == "jest"
            return original.sub(/\.(toEqual|toStrictEqual|toBe|toBeTruthy|toBeFalsy|toBeNull|toThrow)\b/, ".not.\\1") if original.match?(/\.(?:toEqual|toStrictEqual|toBe|toBeTruthy|toBeFalsy|toBeNull|toThrow)\b/)
          end

          if %w[java kotlin].include?(language.downcase) && framework == "junit"
            return original.sub(/\bassertEquals\b/, "assertNotEquals") if original.match?(/\bassertEquals\b/)
            return original.sub(/\bassertTrue\b/, "assertFalse") if original.match?(/\bassertTrue\b/)
            return original.sub(/\bassertFalse\b/, "assertTrue") if original.match?(/\bassertFalse\b/)
          end

          raise ArgumentError, "no safe oracle-negation adapter for #{framework}/#{language}"
        else
          raise ArgumentError, "no conservative adapter for #{mutation.serialize}"
        end
      end
    end

    class OracleMutationPlanner
      extend T::Sig

      PLANS = T.let({
        OracleKind::Equality => [OracleMutationKind::NegateBoolean],
        OracleKind::Identity => [OracleMutationKind::NegateBoolean],
        OracleKind::Truthiness => [OracleMutationKind::NegateBoolean],
        OracleKind::NullCheck => [OracleMutationKind::NegateBoolean],
        OracleKind::ExceptionExpectation => [],
        OracleKind::Snapshot => [],
        OracleKind::MockVerification => [],
        OracleKind::Property => [OracleMutationKind::NegateBoolean],
        OracleKind::CompileFailure => [],
        OracleKind::SubprocessOutput => [],
      }.freeze, T::Hash[OracleKind, T::Array[OracleMutationKind]])

      sig { params(fact: OracleFact).returns(T::Array[OracleMutationPlan]) }
      def self.plan(fact)
        mutations = PLANS.fetch(fact.oracle_kind, [])
        supported = PLANS.key?(fact.oracle_kind)
        disable = OracleMutationPlan.new(
          oracle_id: fact.oracle_id,
          mutation: OracleMutationKind::DisableOracle,
          recognized: supported,
          reason: supported ? "disable the one recognized oracle while preserving the rest of the test" : "unsupported oracle kind",
        )
        return [disable] if mutations.empty?

        plans = T.let([disable], T::Array[OracleMutationPlan])
        mutations.each do |mutation|
          plans << OracleMutationPlan.new(
            oracle_id: fact.oracle_id,
            mutation: mutation,
            recognized: true,
            reason: "framework-specific safe transformation",
          )
        end.freeze
        plans
      end

      sig { params(fact: OracleFact).returns(T.nilable(OracleMutationPlan)) }
      def self.control_plan(fact)
        plan(fact).find { |candidate| candidate.mutation != OracleMutationKind::DisableOracle }
      end
    end

    class OracleTrial < T::Struct
      extend T::Sig

      const :test_id, String
      const :oracle_id, String
      const :mutant_id, String
      const :killed, T::Boolean
      const :executed, T::Boolean
      const :trial, Integer, default: 0
      const :trial_id, String, default: "legacy"
      const :environment_fingerprint, T.nilable(String), default: nil

      sig { returns(T::Hash[String, T.untyped]) }
      def to_h
        {
          "test_id" => test_id,
          "oracle_id" => oracle_id,
          "mutant_id" => mutant_id,
          "killed" => killed,
          "executed" => executed,
          "trial" => trial.zero? && trial_id == "legacy" ? nil : trial,
          "trial_id" => trial_id == "legacy" ? nil : trial_id,
          "environment_fingerprint" => environment_fingerprint,
        }.compact
      end
    end

    class OracleSensitivity < T::Struct
      extend T::Sig

      const :test_id, String
      const :oracle_id, String
      const :original_kills, T::Array[String]
      const :oracle_dependent_kills, T::Array[String]
      const :persists_without_oracle, T::Array[String]
      const :complete, T::Boolean
      const :unknown_reason, T.nilable(String)
      const :observed_trials, Integer, default: 0
      const :trial_ids, T::Array[String], default: []
      const :stable, T::Boolean, default: false

      sig { returns(T::Hash[String, T.untyped]) }
      def to_h
        {
          "test_id" => test_id,
          "oracle_id" => oracle_id,
          "original_kills" => original_kills,
          "oracle_dependent_kills" => oracle_dependent_kills,
          "persists_without_oracle" => persists_without_oracle,
          "complete" => complete,
          "unknown_reason" => unknown_reason,
          "observed_trials" => observed_trials,
          "trial_ids" => trial_ids,
          "stable" => stable,
        }
      end
    end

    class OracleSensitivityAnalysis < T::Struct
      extend T::Sig

      const :results, T::Array[OracleSensitivity]
      const :scope, T.nilable(EvidenceScope), default: nil
      const :execution_results, T::Array[T::Hash[String, T.untyped]], default: []

      sig { returns(T::Hash[String, T.untyped]) }
      def to_h
        {
          "schema" => "test-quality-evidence/oracle-sensitivity-v1",
          "summary" => {
            "oracles" => results.length,
            "complete_oracles" => results.count(&:complete),
            "oracle_dependent_kills" => results.sum { |result| result.oracle_dependent_kills.length },
            "persists_without_oracle" => results.sum { |result| result.persists_without_oracle.length },
          },
          "scope" => scope&.to_h,
          "oracles" => results.map(&:to_h),
          "execution_results" => execution_results,
        }
      end
    end

    class OracleSensitivityAnalyzer
      extend T::Sig

      sig do
        params(
          facts: OracleFacts,
          original_kills: T::Hash[String, T::Array[String]],
          disabled_trials: T::Array[OracleTrial],
          rewrites: T::Array[OracleRewrite],
          scope: T.nilable(EvidenceScope),
          trial_ids: T.nilable(T::Array[String]),
          min_trials: Integer,
          execution_results: T::Array[T::Hash[String, T.untyped]],
        ).returns(OracleSensitivityAnalysis)
      end
      def self.analyze(facts:, original_kills:, disabled_trials:, rewrites:, scope: nil, trial_ids: nil, min_trials: 1, execution_results: [])
        raise ArgumentError, "min_trials must be positive" unless min_trials.positive?

        facts.validate_unique_ids!
        duplicate_rewrites = rewrites.group_by(&:oracle_id).select { |_id, rows| rows.length > 1 }.keys.sort
        raise InvalidOracleFacts, "duplicate oracle rewrite IDs: #{duplicate_rewrites.join(', ')}" unless duplicate_rewrites.empty?
        rewrite_by_id = rewrites.to_h { |rewrite| [rewrite.oracle_id, rewrite] }
        results = facts.facts.map do |fact|
          original_known = original_kills.key?(fact.test_id)
          original = original_kills.fetch(fact.test_id, []).uniq.sort
          fact_trials = disabled_trials.select do |trial|
            trial.test_id == fact.test_id && trial.oracle_id == fact.oracle_id
          end
          trials = fact_trials.select { |trial| original.include?(trial.mutant_id) }
          expected_trial_ids = trial_ids || trials.map(&:trial_id).uniq.sort
          result_for(
            fact,
            original,
            trials,
            rewrite_by_id[fact.oracle_id],
            original_known: original_known,
            expected_trial_ids: expected_trial_ids,
            min_trials: min_trials,
          )
        end.freeze
        OracleSensitivityAnalysis.new(results: results, scope: scope, execution_results: execution_results)
      end

      class << self
        extend T::Sig

        private

        sig do
          params(
            fact: OracleFact,
            original: T::Array[String],
            trials: T::Array[OracleTrial],
            rewrite: T.nilable(OracleRewrite),
            original_known: T::Boolean,
            expected_trial_ids: T::Array[String],
            min_trials: Integer,
          ).returns(OracleSensitivity)
        end
        def result_for(fact, original, trials, rewrite, original_known:, expected_trial_ids:, min_trials:)
          reason = original_known ? nil : "original kill attribution is missing"
          reason ||= rewrite_reason(rewrite)
          reason ||= trial_reason(original, trials, expected_trial_ids, min_trials)
          complete = reason.nil?
          disabled_kills = original.select do |mutant_id|
            expected_trial_ids.all? do |run_id|
              row = trials.find { |trial| trial.trial_id == run_id && trial.mutant_id == mutant_id }
              row&.killed == true
            end
          end.sort
          stable = stable_trials?(original, trials, expected_trial_ids)
          reason ||= "oracle-disabled results are flaky" unless stable
          complete = false unless stable
          OracleSensitivity.new(
            test_id: fact.test_id,
            oracle_id: fact.oracle_id,
            original_kills: original,
            oracle_dependent_kills: complete ? (original - disabled_kills).sort.freeze : [].freeze,
            persists_without_oracle: complete ? (original & disabled_kills).sort.freeze : [].freeze,
            complete: complete,
            unknown_reason: reason,
            observed_trials: trials.map(&:trial_id).uniq.length,
            trial_ids: trials.map(&:trial_id).uniq.sort,
            stable: stable,
          )
        end

        sig { params(rewrite: T.nilable(OracleRewrite)).returns(T.nilable(String)) }
        def rewrite_reason(rewrite)
          return "no safe oracle rewrite was supplied" if rewrite.nil?
          return "oracle rewrite was not recognized" unless rewrite.recognized
          return "oracle rewrite could not be applied" unless rewrite.applied

          nil
        end

        sig do
          params(original: T::Array[String], trials: T::Array[OracleTrial], expected_trial_ids: T::Array[String], min_trials: Integer).returns(T.nilable(String))
        end
        def trial_reason(original, trials, expected_trial_ids, min_trials)
          return nil if original.empty? && expected_trial_ids.empty?
          return "oracle-disabled attribution is incomplete" if expected_trial_ids.empty?
          return "oracle-disabled trials do not contain the required repeated-trial matrix" if expected_trial_ids.length < min_trials
          return "oracle-disabled trials did not execute" unless trials.all?(&:executed)
          return "oracle-disabled attribution is incomplete" unless original.all? do |mutant_id|
            expected_trial_ids.all? { |run_id| trials.any? { |trial| trial.mutant_id == mutant_id && trial.trial_id == run_id } }
          end
          duplicate = trials.group_by { |trial| [trial.mutant_id, trial.trial_id] }.any? { |_key, rows| rows.length > 1 }
          return "oracle-disabled matrix contains duplicate trial observations" if duplicate

          environments = trials.filter_map(&:environment_fingerprint).uniq
          return "oracle-disabled trials ran in incomparable environments" if environments.length > 1

          nil
        end

        sig { params(original: T::Array[String], trials: T::Array[OracleTrial], expected_trial_ids: T::Array[String]).returns(T::Boolean) }
        def stable_trials?(original, trials, expected_trial_ids)
          return true if original.empty?
          return false if expected_trial_ids.empty?

          original.all? do |mutant_id|
            outcomes = expected_trial_ids.map do |run_id|
              row = trials.find { |trial| trial.mutant_id == mutant_id && trial.trial_id == run_id }
              row&.killed
            end
            outcomes.all? { |outcome| !outcome.nil? } && outcomes.uniq.length == 1
          end
        end
      end
    end

    class OracleExecutionRequest < T::Struct
      const :repository, String
      const :revision, String, default: "HEAD"
      const :source_path, String
      const :test_command, T::Array[String]
      const :baseline_test_command, T.nilable(T::Array[String]), default: nil
      const :mutant_commands, T::Hash[String, T::Array[String]], default: {}
      const :test_id, String
      const :fact, OracleFact
      const :plan, OracleMutationPlan
      const :control_plan, T.nilable(OracleMutationPlan), default: nil
      const :language, String
      const :trial_count, Integer, default: 3
      const :limits, CommandLimits, factory: -> { CommandLimits.new }
      const :scope, T.nilable(EvidenceScope), default: nil
      const :allow_dirty, T::Boolean, default: false
    end

    class OracleExecutionResult < T::Struct
      extend T::Sig

      const :disabled_rewrite, OracleRewrite
      const :control_rewrite, T.nilable(OracleRewrite)
      const :disabled_control_outcome, TestOutcome
      const :control_outcome, T.nilable(TestOutcome)
      const :baseline_outcome, TestOutcome
      const :disabled_trials, T::Array[OracleTrial]
      const :run_id, String
      const :environment_fingerprint, String

      sig { returns(T::Boolean) }
      def control_verified?
        control_outcome == TestOutcome::AssertionFailure
      end

      sig { returns(T::Hash[String, T.untyped]) }
      def to_h
        {
          "run_id" => run_id,
          "environment_fingerprint" => environment_fingerprint,
          "disabled_rewrite" => disabled_rewrite.to_h,
          "control_rewrite" => control_rewrite&.to_h,
          "baseline_outcome" => baseline_outcome.serialize,
          "disabled_control_outcome" => disabled_control_outcome.serialize,
          "control_outcome" => control_outcome&.serialize,
          "control_verified" => control_verified?,
          "disabled_trials" => disabled_trials.map(&:to_h),
        }
      end
    end

    class OracleExecutionRunner
      extend T::Sig

      sig { params(command_runner: CommandRunner, adapter: OracleRewriteAdapter, parser: TestResultParser).void }
      def initialize(command_runner: ProcessCommandRunner.new, adapter: ConservativeOracleRewriteAdapter.new, parser: DefaultTestResultParser.new)
        @command_runner = command_runner
        @adapter = adapter
        @parser = parser
      end

      sig { params(request: OracleExecutionRequest).returns(OracleExecutionResult) }
      def run(request)
        raise ArgumentError, "trial_count must be positive" unless request.trial_count.positive?
        ensure_clean_repository!(request)
        original_source = File.read(File.join(request.repository, request.source_path))
        disable_plan = request.plan.mutation == OracleMutationKind::DisableOracle ? request.plan : OracleMutationPlanner.plan(request.fact).first
        control_plan = request.control_plan
        control_plan ||= request.plan unless request.plan.mutation == OracleMutationKind::DisableOracle
        control_plan ||= OracleMutationPlanner.control_plan(request.fact)
        disabled_source, disabled_rewrite = @adapter.rewrite(
          fact: request.fact, plan: T.must(disable_plan), source: original_source, language: request.language,
        )
        control_source, control_rewrite = if control_plan
          @adapter.rewrite(fact: request.fact, plan: control_plan, source: original_source, language: request.language)
        else
          [original_source, nil]
        end
        environment = Digest::SHA256.hexdigest("#{request.repository}:#{request.revision}:#{request.language}")
        run_id = "oracle-#{SecureRandom.uuid}"

        Dir.mktmpdir("test-miser-oracle-") do |directory|
          archive_revision(request, directory)
          target = File.join(directory, request.source_path)
          FileUtils.mkdir_p(File.dirname(target))
          File.write(target, original_source)
          baseline = @command_runner.run(request.baseline_test_command || request.test_command, chdir: directory, limits: request.limits)
          baseline_outcome = @parser.parse(baseline)
          disabled_control_outcome = TestOutcome::InfrastructureFailure
          control_outcome = nil
          disabled_trials = []
          if disabled_rewrite.applied && baseline_outcome == TestOutcome::Passed
            File.write(target, disabled_source)
            disabled_result = @command_runner.run(request.test_command, chdir: directory, limits: request.limits)
            disabled_control_outcome = @parser.parse(disabled_result)
            if disabled_control_outcome == TestOutcome::Passed
              request.trial_count.times do |index|
                request.mutant_commands.each do |mutant_id, command|
                  result = @command_runner.run(command, chdir: directory, limits: request.limits)
                  outcome = @parser.parse(result)
                  disabled_trials << OracleTrial.new(
                    test_id: request.test_id,
                    oracle_id: request.fact.oracle_id,
                    mutant_id: mutant_id,
                    killed: outcome == TestOutcome::AssertionFailure,
                    executed: outcome != TestOutcome::InfrastructureFailure,
                    trial: index,
                    trial_id: "#{run_id}-#{index}",
                    environment_fingerprint: environment,
                  )
                end
              end
            end
          end
          if control_rewrite&.applied && baseline_outcome == TestOutcome::Passed
            File.write(target, control_source)
            control_result = @command_runner.run(request.test_command, chdir: directory, limits: request.limits)
            control_outcome = @parser.parse(control_result)
          end
          OracleExecutionResult.new(
            disabled_rewrite: disabled_rewrite,
            control_rewrite: control_rewrite,
            disabled_control_outcome: disabled_control_outcome,
            baseline_outcome: baseline_outcome,
            control_outcome: control_outcome,
            disabled_trials: disabled_trials.freeze,
            run_id: run_id,
            environment_fingerprint: environment,
          )
        end
      end

      private

      sig { params(request: OracleExecutionRequest).void }
      def ensure_clean_repository!(request)
        return if request.allow_dirty

        out, _err, status = Open3.capture3("git", "status", "--porcelain=v1", "--untracked-files=all", chdir: request.repository)
        return if status.success? && out.empty?

        raise InvalidOracleFacts, "oracle execution requires a clean worktree"
      end

      sig { params(request: OracleExecutionRequest, directory: String).void }
      def archive_revision(request, directory)
        _stdout, stderr, status = Open3.capture3("git", "archive", request.revision, "-o", "#{directory}/source.tar", chdir: request.repository)
        raise InvalidOracleFacts, "could not archive #{request.revision}: #{stderr}" unless status.success?
        _stdout, stderr, status = Open3.capture3("tar", "-xf", "#{directory}/source.tar", "-C", directory)
        raise InvalidOracleFacts, "could not extract #{request.revision}: #{stderr}" unless status.success?
      end
    end
  end
end
