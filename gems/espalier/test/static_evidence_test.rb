# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "tmpdir"
require_relative "../lib/espalier"

class StaticEvidenceTest < Minitest::Test
  def test_marks_only_a_git_worktree_root_as_a_complete_corpus
    Dir.mktmpdir("espalier-closed-corpus") do |dir|
      system("git", "-C", dir, "init", "--quiet", exception: true)
      File.write(File.join(dir, "worker.rb"), <<~RUBY)
        class Worker
          def call
            1
          end
        end
      RUBY

      complete = Espalier::StaticEvidence.build([dir], root: dir)
      partial = Espalier::StaticEvidence.build([File.join(dir, "worker.rb")], root: dir)

      assert_equal true, complete.dig("corpus", "complete")
      assert_equal false, partial.dig("corpus", "complete")
      assert_equal true, complete.dig("input_coverage", "complete")
      assert_equal true, partial.dig("input_coverage", "complete")
    end
  end

  def test_marks_input_coverage_partial_when_fact_mine_recovers_from_syntax_error
    Dir.mktmpdir("espalier-input-recovery") do |dir|
      source = File.join(dir, "broken.rb")
      File.write(source, "def broken(\n")

      evidence = Espalier::StaticEvidence.build([source], root: dir)
      assert_equal false, evidence.dig("input_coverage", "complete")
      assert_equal [source], evidence.dig("input_coverage", "parse_recovery_files")
    end
  end

  def test_builds_static_evidence_using_rust_fact_mine
    nil_kill_features = loaded_nil_kill_features

    Dir.mktmpdir("espalier-static", Dir.pwd) do |dir|
      src = File.join(dir, "src")
      FileUtils.mkdir_p(src)
      File.write(File.join(src, "client_user.rb"), <<~RUBY)
        class ClientUser
          extend T::Sig

          sig { params(client: T.untyped).void }
          def initialize(client)
            @client = T.let(client, T.untyped)
          end

          sig { returns(String) }
          def call
            @client.fetch
            self.helper
          end

          sig { void }
          def helper
          end
        end
      RUBY

      evidence = Espalier::StaticEvidence.build([src], root: dir)

      assert_equal "espalier_static_evidence", evidence["kind"]
      assert_equal 3, evidence.dig("summary", "methods")
      # State protocols include the field call, but never the explicit
      # owner-method call (`self.helper`).
      assert_equal ["fetch"], evidence.dig("facts", "state_protocols", "ClientUser\u0000@client")
      coverage = evidence.dig("facts", "call_resolution_coverage")
      assert_operator coverage.fetch("eligible_call_sites"), :>, 0
      assert_equal coverage, evidence.dig("summary", "call_resolution_coverage")
      assert_equal false, evidence.dig("language_capabilities", "ruby", "runtime_tracing")
      assert_equal nil_kill_features, loaded_nil_kill_features
    end
  end

  def test_skips_root_rbi_annotations_for_explicit_non_project_targets
    Dir.mktmpdir("espalier-static-rbi", Dir.pwd) do |dir|
      target = File.join(dir, "tmp_target")
      rbi = File.join(dir, "sorbet", "rbi")
      FileUtils.mkdir_p(target)
      FileUtils.mkdir_p(rbi)
      File.write(File.join(target, "worker.rb"), <<~RUBY)
        class Worker
          def call(value)
            value
          end
        end
      RUBY
      File.write(File.join(rbi, "generated.rbi"), <<~RBI)
        class Generated
          sig { returns(String) }
          def name; end
        end
      RBI

      evidence = Espalier::StaticEvidence.build([target], root: dir)
      rbi_definitions = evidence.dig("facts", "type_definitions").select do |definition|
        definition["path"].to_s.end_with?(".rbi")
      end

      assert_empty rbi_definitions
      assert_equal 0, evidence.dig("summary", "rbi_field_types")
    end
  end

  # Hash shapes / collection lookups not yet implemented in Rust FactMine (Phase 2c).
  # This test documents the expected behavior once implemented.
  def test_static_evidence_includes_hash_record_lookup_facts
    Dir.mktmpdir("espalier-static-hash", Dir.pwd) do |dir|
      src = File.join(dir, "src")
      FileUtils.mkdir_p(src)
      File.write(File.join(src, "worker.rb"), <<~RUBY)
        class Worker
          def label
            user = {name: "Ada", id: 1}
            "\#{user[:name]}:\#{user.fetch(:id)}"
          end
        end
      RUBY

      evidence = Espalier::StaticEvidence.build([src], root: dir)
      lookups = evidence.dig("facts", "collection_index_lookups")

      assert_equal 2, evidence.dig("summary", "collection_index_lookups")
      assert_includes lookups.map { |lookup| lookup["code"] }, "user[:name]"
      assert_includes lookups.map { |lookup| lookup["code"] }, "user.fetch(:id)"
      assert lookups.all? { |lookup| lookup.dig("origin", "kind") == "hash literal" }
    end
  end

  def test_indexed_declared_token_predicate_is_constant_and_complete
    Dir.mktmpdir("espalier-indexed-token", Dir.pwd) do |dir|
      source = File.join(dir, "parser.rb")
      File.write(source, <<~RUBY)
        class Token < T::Struct
          const :kind, Symbol
        end

        class Parser
          extend T::Sig

          sig { params(tokens: T::Array[Token], position: Integer).returns(T::Boolean) }
          def eof?(tokens, position)
            tokens[position].kind == :eof
          end
        end
      RUBY

      evidence = Espalier::StaticEvidence.build([source], root: dir)
      modules = Espalier::StaticEvidence.project_modules(evidence)
      manifest = Espalier::Aggregator.new.aggregate(modules)
      parser_owner = manifest.find { |owner| owner[:module] == "Parser" }
      refute_nil parser_owner, manifest.inspect
      predicate = parser_owner.fetch(:functions)
        .find { |function| function[:name] == "eof?" }
      refute_nil predicate, parser_owner.inspect
      metrics = predicate.fetch(:quality_metrics)

      assert_equal "O(1)", metrics[:big_o]
      assert_equal "O(1)", metrics[:big_o_space]
      assert_equal true, metrics[:big_o_complete]
      assert_equal true, metrics[:big_o_space_complete]
      assert_empty Array(metrics[:big_o_unknowns])
    end
  end

  def test_project_modules_groups_by_owner
    evidence = {
      "methods" => [
        {
          "name" => "connect",
          "signature" => "def connect(id)",
          "params" => ["id"],
          "owner" => "ConnectionManager",
          "path" => "lib/conn.rb",
          "line" => 20,
          "span" => [20, 0, 25, 3],
          "language" => "ruby"
        }
      ],
      "fields" => [
        {
          "name" => "@active_connections",
          "owner" => "ConnectionManager",
          "path" => "lib/conn.rb",
          "line" => 15,
          "span" => [15, 0, 15, 20],
          "language" => "ruby"
        }
      ],
      "facts" => {
        "call_graph_edges" => [],
        "state_protocol_records" => [
          {
            "owner" => "ConnectionManager",
            "function" => "connect",
            "field" => "@active_connections",
            "protocol" => "sort_by",
            "line" => 23
          }
        ],
        "state_param_origin_records" => [],
        "struct_declarations" => [
          {
            "class" => "ConnectionManager",
            "fields" => ["active_connections"]
          }
        ]
      }
    }

    modules = Espalier::StaticEvidence.project_modules(evidence)
    assert_equal 1, modules.size
    mod = modules.first
    assert_equal "ConnectionManager", mod[:name]
    assert_equal "lib/conn.rb", mod[:file]
    assert_includes mod[:states], "@active_connections"
    assert_equal 1, mod[:methods].size
    assert_equal "connect", mod[:methods].first[:name]
    assert_includes mod.dig(:declared_fields, "ConnectionManager"), "active_connections"
    assert_includes mod[:methods].first[:delegations], {
      receiver: "@active_connections",
      message: "sort_by",
      line: 23,
      type: :always
    }
  end

  def test_project_modules_does_not_model_javascript_module_exports_as_instance_state
    evidence = {
      "owners" => [
        { "name" => "schemas", "kind" => "owner", "path" => "src/schemas.js", "language" => "javascript" }
      ],
      "methods" => [
        { "id" => "m1", "name" => "parse", "owner" => "schemas", "path" => "src/schemas.js", "line" => 3, "language" => "javascript" }
      ],
      "fields" => [
        { "name" => "parse", "owner" => "schemas", "path" => "src/schemas.js", "line" => 1, "language" => "javascript" }
      ],
      "facts" => { "calls" => [], "state_accesses" => [], "complexity_facts" => [], "struct_declarations" => [] }
    }

    mod = Espalier::StaticEvidence.project_modules(evidence).fetch(0)
    assert_equal :module, mod[:type]
    assert_empty mod[:states]
    assert_empty mod[:state_records]
  end

  def test_git_vcs_discovers_an_explicit_target_outside_the_command_root
    Dir.mktmpdir("espalier-vcs") do |dir|
      src = File.join(dir, "src")
      FileUtils.mkdir_p(src)
      file = File.join(src, "worker.js")
      File.write(file, "export function work() { return 1 }\n")
      system("git", "-C", dir, "init", "--quiet")
      system("git", "-C", dir, "add", ".")
      system("git", "-C", dir, "-c", "user.email=test@example.test", "-c", "user.name=test", "commit", "--quiet", "-m", "fixture")

      evidence = Espalier::StaticEvidence.new([src], root: Dir.pwd, vcs: :git)
      assert_equal [file], evidence.send(:target_files)
    end
  end

  def test_aggregator_accepts_zero_modules
    assert_equal [], Espalier::Aggregator.new.aggregate([])
  end

  def test_project_modules_excludes_typescript_overload_declarations_when_an_implementation_exists
    evidence = {
      "methods" => [
        { "id" => "declaration", "name" => "format", "owner" => "Formatter", "kind" => "instance", "path" => "src/formatter.ts", "line" => 1, "language" => "typescript", "raw_source" => "format(value: string): string;" },
        { "id" => "implementation", "name" => "format", "owner" => "Formatter", "kind" => "instance", "path" => "src/formatter.ts", "line" => 2, "language" => "typescript", "raw_source" => "format(value: string) { return value; }" }
      ],
      "fields" => [],
      "facts" => { "calls" => [], "state_accesses" => [], "complexity_facts" => [], "struct_declarations" => [] }
    }

    methods = Espalier::StaticEvidence.project_modules(evidence).fetch(0).fetch(:methods)
    assert_equal ["format"], methods.map { |method| method[:name] }
    assert_equal 2, methods.first[:line]
  end

  def test_project_modules_ranks_production_by_default_and_retains_selectable_tests
    evidence = {
      "methods" => [
        { "id" => "prod", "name" => "run", "owner" => "App", "path" => "src/app.go", "line" => 1 },
        { "id" => "test", "name" => "test_run", "owner" => "AppTest", "path" => "src/app_test.go", "line" => 1 },
      ],
      "fields" => [],
      "facts" => {},
    }

    assert_equal ["App"], Espalier::StaticEvidence.project_modules(evidence).map { |mod| mod[:name] }
    assert_equal ["AppTest"],
      Espalier::StaticEvidence.project_modules(evidence, source_roles: ["test"]).map { |mod| mod[:name] }
  end

  def test_source_roles_are_language_neutral_path_facts
    assert_equal "test", Espalier::StaticEvidence.source_role("src/widget_test.go")
    assert_equal "test", Espalier::StaticEvidence.source_role("src/normalizer-test.rs")
    assert_equal "test", Espalier::StaticEvidence.source_role("tests/test_widget.py")
    assert_equal "test", Espalier::StaticEvidence.source_role("Tests/ArgumentParserTests/AnyArgumentTests.swift")
    assert_equal "test", Espalier::StaticEvidence.source_role("src/jvmTest/kotlin/Foo.kt")
    assert_equal "test", Espalier::StaticEvidence.source_role("src/nonWasmTest/kotlin/Foo.kt")
    assert_equal "benchmark", Espalier::StaticEvidence.source_role("benchmarks/widget.rs")
    assert_equal "example", Espalier::StaticEvidence.source_role("examples/widget.rb")
    assert_equal "production", Espalier::StaticEvidence.source_role("rich/console.py")
    assert_equal "test", Espalier::StaticEvidence.source_role("Sources/ArgumentParserTestHelpers/Helpers.swift")
  end

  def test_method_source_roles_exclude_rust_inline_test_modules_and_their_lambdas
    methods = [
      {
        "id" => "production",
        "path" => "/project/src/lib.rs",
        "language" => "rust",
        "span" => [1, 0, 5, 1],
        "semantic_symbol" => "rust-analyzer cargo demo 0.1.0 run()."
      },
      {
        "id" => "test",
        "path" => "/project/src/lib.rs",
        "language" => "rust",
        "span" => [10, 4, 20, 5],
        "semantic_symbol" => "rust-analyzer cargo demo 0.1.0 tests/check()."
      },
      {
        "id" => "test-lambda",
        "path" => "/project/src/lib.rs",
        "language" => "rust",
        "kind" => "lambda",
        "span" => [14, 20, 14, 32]
      }
    ]

    assert_equal(
      { "production" => "production", "test" => "test", "test-lambda" => "test" },
      Espalier::StaticEvidence.method_source_roles(methods)
    )
  end

  def test_project_modules_prefers_a_primary_owner_over_an_extension_and_never_gives_protocols_state
    evidence = {
      "owners" => [
        { "name" => "Counter", "kind" => "extension", "path" => "Sources/Counter+Extras.swift", "line" => 1, "language" => "swift" },
        { "name" => "Counter", "kind" => "struct", "path" => "Sources/Counter.swift", "line" => 3, "language" => "swift" },
        { "name" => "Renderable", "kind" => "protocol", "path" => "Sources/Renderable.swift", "line" => 1, "language" => "swift" }
      ],
      "methods" => [
        { "id" => "counter-extra", "name" => "incremented", "owner" => "Counter", "path" => "Sources/Counter+Extras.swift", "line" => 2, "language" => "swift" },
        { "id" => "renderable", "name" => "render", "owner" => "Renderable", "path" => "Sources/Renderable.swift", "line" => 2, "language" => "swift" }
      ],
      "fields" => [
        { "name" => "cached", "owner" => "Renderable", "path" => "Sources/Renderable.swift", "line" => 1, "language" => "swift" }
      ],
      "facts" => {}
    }

    modules = Espalier::StaticEvidence.project_modules(evidence)
    counter = modules.find { |mod| mod[:name] == "Counter" }
    protocol = modules.find { |mod| mod[:name] == "Renderable" }
    assert_equal "Sources/Counter.swift", counter[:file]
    assert_equal :class, counter[:type]
    assert_equal :module, protocol[:type]
    assert_empty protocol[:states]
  end

  def test_project_modules_resolves_unique_static_and_flow_typed_targets
    evidence = {
      "methods" => [
        { "id" => "source-run", "owner" => "Source", "name" => "run", "kind" => "instance",
          "dispatch_name" => "run", "path" => "source.rb", "line" => 2, "language" => "ruby" },
        { "id" => "target-build", "owner" => "Target", "name" => "self.build", "kind" => "class",
          "dispatch_name" => "build", "path" => "target.rb", "line" => 2, "language" => "ruby" },
        { "id" => "target-work", "owner" => "Target", "name" => "work", "kind" => "instance",
          "dispatch_name" => "work", "path" => "target.rb", "line" => 6, "language" => "ruby" }
      ],
      "facts" => {
        "calls" => [
          { "source" => "source-run", "receiver" => "Target", "receiver_kind" => "type",
            "message" => "build", "target" => "target-build", "line" => 3 },
          { "source" => "source-run", "receiver" => "target", "receiver_kind" => "value",
            "message" => "work", "target" => "target-work", "line" => 4 }
        ],
        "flow_local_types" => [
          { "file" => "source.rb", "owner" => "Source", "function" => "run", "name" => "target",
            "line" => 4, "complete" => true,
            "resolved_types" => [FactMine::Syntax::TypeExpr.new("Primitive", "Target", "ruby")] }
        ]
      }
    }

    modules = Espalier::StaticEvidence.project_modules(evidence)
    run = modules.find { |mod| mod[:name] == "Source" }[:methods].first
    static_call = run[:delegations].find { |call| call[:message] == "build" }
    typed_call = run[:delegations].find { |call| call[:message] == "work" }

    assert_equal ["Target", "self.build"], [static_call[:target_owner], static_call[:target_method]]
    assert_equal ["Target", "work"], [typed_call[:target_owner], typed_call[:target_method]]
    assert_equal "target-build", static_call[:target_id]
    assert_equal "target-work", typed_call[:target_id]
    assert_equal "high", static_call[:confidence]
    assert_equal "high", typed_call[:confidence]
  end

  def test_project_modules_preserves_scip_identity_and_deduplicates_protocol_projection
    evidence = {
      "methods" => [{
        "id" => "source-run", "owner" => "Source", "name" => "run",
        "kind" => "instance", "path" => "source.java", "line" => 2,
        "language" => "java"
      }],
      "facts" => {
        "calls" => [{
          "source" => "source-run", "receiver" => "this.items", "state_receiver" => true,
          "message" => "size",
          "line" => 3, "semantic_symbol" => "scip-java maven jdk 21 java/util/List#size().",
          "target_provenance" => "scip", "known_time_complexity" => "O(1)"
        }],
        "state_protocol_records" => [{
          "owner" => "Source", "function" => "run", "field" => "items",
          "protocol" => "size", "line" => 3, "path" => "source.java", "language" => "java"
        }]
      }
    }

    run = Espalier::StaticEvidence.project_modules(evidence).first[:methods].first
    assert_equal 1, run[:delegations].count { |call| call[:message] == "size" && call[:line] == 3 }
    assert_equal "scip", run[:delegations].first[:target_provenance]
    assert_match(/java\/util\/List/, run[:delegations].first[:semantic_symbol])
  end

  def test_protocol_projection_deduplicates_canonical_call_by_exact_span
    evidence = {
      "methods" => [{
        "id" => "source-run", "owner" => "Source", "name" => "run",
        "kind" => "instance", "path" => "source.java", "line" => 2,
        "span" => [2, 0, 5, 1], "language" => "java"
      }],
      "facts" => {
        "calls" => [{
          "id" => "call-add", "source" => "source-run", "receiver" => "builder.items",
          "message" => "addAll", "line" => 3, "span" => [3, 4, 3, 31],
          "semantic_symbol" => "scip-java maven jdk 21 java/util/List#addAll().",
          "target_provenance" => "scip", "known_time_complexity" => "O(N)"
        }],
        "state_protocol_records" => [{
          "owner" => "Source", "function" => "run", "field" => "builder",
          "protocol" => "addAll", "line" => 3, "span" => [3, 4, 3, 31],
          "path" => "source.java", "language" => "java"
        }]
      }
    }

    run = Espalier::StaticEvidence.project_modules(evidence).first[:methods].first
    assert_equal 1, run[:delegations].count { |call| call[:message] == "addAll" }
    assert_equal "call-add", run[:delegations].first[:call_id]
    assert_equal "O(N)", run[:delegations].first[:known_time_complexity]
  end

  def test_protocol_projection_uses_the_containing_overload
    evidence = {
      "methods" => [{
        "id" => "first", "owner" => "Source", "name" => "run", "kind" => "instance",
        "path" => "source.java", "line" => 2, "span" => [2, 0, 4, 1], "language" => "java"
      }, {
        "id" => "second", "owner" => "Source", "name" => "run", "kind" => "instance",
        "path" => "source.java", "line" => 7, "span" => [7, 0, 10, 1], "language" => "java"
      }],
      "facts" => {
        "state_protocol_records" => [{
          "owner" => "Source", "function" => "run", "field" => "items",
          "protocol" => "size", "line" => 8, "path" => "source.java", "language" => "java"
        }]
      }
    }

    methods = Espalier::StaticEvidence.project_modules(evidence).first[:methods]
    assert_empty methods.find { |method| method[:id] == "first" }[:delegations]
    assert_equal ["size"], methods.find { |method| method[:id] == "second" }[:delegations].map { |call| call[:message] }
  end

  def test_project_modules_does_not_guess_ambiguous_or_incomplete_targets
    evidence = {
      "methods" => [
        { "id" => "source-run", "owner" => "Source", "name" => "run", "kind" => "instance",
          "dispatch_name" => "run", "path" => "source.rb", "line" => 2, "language" => "ruby" },
        { "id" => "target-build-a", "owner" => "Target", "name" => "self.build", "kind" => "class",
          "dispatch_name" => "build", "path" => "a.rb", "line" => 2, "language" => "ruby" },
        { "id" => "target-build-b", "owner" => "Target", "name" => "self.build", "kind" => "class",
          "dispatch_name" => "build", "path" => "b.rb", "line" => 2, "language" => "ruby" },
        { "id" => "target-work", "owner" => "Target", "name" => "work", "kind" => "instance",
          "dispatch_name" => "work", "path" => "target.rb", "line" => 6, "language" => "ruby" }
      ],
      "facts" => {
        "calls" => [
          { "source" => "source-run", "receiver" => "Target", "receiver_kind" => "type",
            "message" => "build", "line" => 3 },
          { "source" => "source-run", "receiver" => "target", "receiver_kind" => "value",
            "message" => "work", "line" => 4 }
        ],
        "flow_local_types" => [{
          "file" => "source.rb", "owner" => "Source", "function" => "run", "name" => "target",
          "line" => 4, "complete" => false,
          "resolved_types" => [FactMine::Syntax::TypeExpr.new("Primitive", "Target", "ruby")]
        }],
        "struct_declarations" => [{
          "class" => "Target", "fields" => [], "constant_operations" => ["build"]
        }]
      }
    }

    run = Espalier::StaticEvidence.project_modules(evidence)
      .find { |mod| mod[:name] == "Source" }[:methods].first
    run[:delegations].each do |call|
      assert_nil call[:target_owner]
      assert_nil call[:target_method]
      assert_nil call[:known_time_complexity], "ambiguous overrides must not fall back to generated cost"
    end
  end

  def test_project_modules_uses_normalized_constructor_and_constant_operation_evidence
    evidence = {
      "methods" => [
        { "id" => "source-run", "owner" => "Source", "name" => "run", "kind" => "instance",
          "dispatch_name" => "run", "path" => "source.rb", "line" => 2, "language" => "ruby" },
        { "id" => "record-init", "owner" => "Record", "name" => "initialize", "kind" => "instance",
          "dispatch_name" => "initialize", "path" => "record.rb", "line" => 2, "language" => "ruby" }
      ],
      "facts" => {
        "calls" => [
          { "source" => "source-run", "receiver" => "Record", "receiver_kind" => "type",
            "message" => "new", "constructor_target" => "initialize", "target" => "record-init", "line" => 3 },
          { "source" => "source-run", "receiver" => "Generated", "receiver_kind" => "type",
            "message" => "new", "constructor_target" => "initialize", "line" => 4 },
          { "source" => "source-run", "receiver" => "self", "receiver_kind" => "value",
            "message" => "[]", "line" => 5 },
          { "source" => "source-run", "receiver" => "T", "receiver_kind" => "type",
            "message" => "let", "known_time_complexity" => "O(1)",
            "known_space_complexity" => "O(1)", "line" => 6 }
        ],
        "struct_declarations" => [
          { "class" => "Source", "fields" => [], "constant_operations" => ["[]"] },
          { "class" => "Record", "fields" => [], "constant_operations" => ["new"] },
          { "class" => "Generated", "fields" => [], "constant_operations" => ["new"] }
        ]
      }
    }

    run = Espalier::StaticEvidence.project_modules(evidence)
      .find { |mod| mod[:name] == "Source" }[:methods].first
    constructor = run[:delegations].find { |call| call[:receiver] == "Record" }
    generated = run[:delegations].find { |call| call[:receiver] == "Generated" }
    reader = run[:delegations].find { |call| call[:message] == "[]" }
    intrinsic = run[:delegations].find { |call| call[:message] == "let" }

    assert_equal ["Record", "initialize"], [constructor[:target_owner], constructor[:target_method]]
    assert_nil constructor[:known_time_complexity], "an exact override must win over generated-operation cost"
    assert_equal ["O(1)", "O(1)"], [generated[:known_time_complexity], generated[:known_space_complexity]]
    assert_equal ["O(1)", "O(1)"], [reader[:known_time_complexity], reader[:known_space_complexity]]
    assert_equal ["O(1)", "O(1)"], [intrinsic[:known_time_complexity], intrinsic[:known_space_complexity]]
  end

  def test_builds_using_fact_mine_facts_file
    Dir.mktmpdir("espalier-mock", Dir.pwd) do |dir|
      mock_file = File.join(dir, "mock.rb")
      File.write(mock_file, "class MockClass; def mock_method; end; end")

      mock_facts = {
        "methods" => [
          {
            "name" => "mock_method",
            "owner" => "MockClass",
            "path" => "mock.rb",
            "line" => 1,
            "language" => "ruby"
          }
        ],
        "flow_local_types" => [
          {
            "file" => "mock.rb",
            "function" => "mock_method",
            "name" => "message",
            "place_id" => "place-1",
            "node_id" => "node-1",
            "line" => 1,
            "span" => [1, 0, 1, 7],
            "types" => ["string"],
            "complete" => true,
            "reaching_definitions" => ["node-0"]
          }
        ]
      }
      Tempfile.create(["mock-facts", ".json"]) do |f|
        f.write(JSON.dump(mock_facts))
        f.close
        begin
          ENV["FACT_MINE_FACTS_FILE"] = f.path
          evidence = Espalier::StaticEvidence.build([mock_file], root: dir)
          assert_equal "espalier_static_evidence", evidence["kind"]
          assert_equal 1, evidence.dig("summary", "methods")
          assert_equal "mock_method", evidence.dig("methods", 0, "name")
          assert_equal 1, evidence.dig("summary", "flow_local_types")
          assert_equal ["string"], evidence.dig("facts", "flow_local_types", 0, "types")
        ensure
          ENV["FACT_MINE_FACTS_FILE"] = nil
        end
      end
    end
  end

  private

  def loaded_nil_kill_features
    $LOADED_FEATURES.grep(%r{/nil[-_]kill/}).sort
  end
end
