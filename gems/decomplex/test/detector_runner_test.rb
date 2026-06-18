# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "tempfile"
require_relative "../lib/decomplex"

class DetectorRunnerTest < Minitest::Test
  FIXTURE = "gems/decomplex/test/fixtures/co_update_sample.rb"

  def test_co_update_ruby_engine_canonical_json_is_frozen
    expected = <<~JSON
      {"co_written_pairs":[{"pair":["provenance","storage"],"sites":["gems/decomplex/test/fixtures/co_update_sample.rb:stable_one","gems/decomplex/test/fixtures/co_update_sample.rb:stable_two","gems/decomplex/test/fixtures/co_update_sample.rb:stable_three"],"support":3}],"neglected_updates":[{"at":"gems/decomplex/test/fixtures/co_update_sample.rb:misses_provenance:17","has":"storage","missing":"provenance","pair":["provenance","storage"],"recv":"node","spans":{"gems/decomplex/test/fixtures/co_update_sample.rb:misses_provenance:17":[17,2,17,22]},"support":3}]}
    JSON

    assert_equal expected, Decomplex::DetectorRunner.canonical_json("co-update", [FIXTURE], engine: "ruby")
  end

  def test_co_update_rust_engine_matches_ruby_engine_byte_for_byte
    skip "cargo is not available" unless cargo_available?

    ok, ruby_json, rust_json = Decomplex::DetectorRunner.compare("co-update", [FIXTURE])

    assert ok, diff_message(ruby_json, rust_json)
    assert_equal ruby_json, rust_json
  end

  def test_native_command_language_for_recognizes_jvm_and_swift_extensions
    assert_equal "java", Decomplex::Native::Command.language_for("Example.java")
    assert_equal "kotlin", Decomplex::Native::Command.language_for("Example.kt")
    assert_equal "kotlin", Decomplex::Native::Command.language_for("Example.kts")
    assert_equal "swift", Decomplex::Native::Command.language_for("Example.swift")
  end

  def test_miner_rust_engine_matches_ruby_engine_byte_for_byte
    skip "cargo is not available" unless cargo_available?

    Tempfile.create(["decomplex-miner", ".rb"]) do |file|
      file.write(<<~RUBY)
        def one(a, b, c)
          a && b && c
        end

        def two(a, b, c)
          a && b && c
        end

        def three(a, b, c)
          a && b && c
        end

        def broken(a, b)
          a && b
        end
      RUBY
      file.flush

      ok, ruby_json, rust_json = Decomplex::DetectorRunner.compare("miner", [file.path])

      assert ok, diff_message(ruby_json, rust_json)
      assert_equal ruby_json, rust_json
    end
  end

  def test_flay_similarity_rust_engine_matches_ruby_engine_byte_for_byte
    skip "cargo is not available" unless cargo_available?

    Tempfile.create(["decomplex-flay", ".rb"]) do |file|
      file.write(<<~RUBY)
        def one(a, b)
          total = a + b
          puts total
          total * 2
        end

        def two(x, y)
          total = x + y
          puts total
          total * 2
        end
      RUBY
      file.flush

      ok, ruby_json, rust_json = Decomplex::DetectorRunner.compare("flay-similarity", [file.path], mass: 4, fuzzy: 1)

      assert ok, diff_message(ruby_json, rust_json)
      assert_equal ruby_json, rust_json
    end
  end

  def test_semantic_alias_rust_engine_matches_ruby_engine_byte_for_byte
    skip "cargo is not available" unless cargo_available?

    Tempfile.create(["decomplex-semantic-alias", ".rb"]) do |file|
      file.write(<<~RUBY)
        def frame?; @provenance == :frame; end
        def is_frame?; provenance == :frame; end
        def heap?; @provenance == :heap; end
        def somewhere(node)
          return 1 if node.provenance == :frame
        end
      RUBY
      file.flush

      ok, ruby_json, rust_json = Decomplex::DetectorRunner.compare("semantic-alias", [file.path])

      assert ok, diff_message(ruby_json, rust_json)
      assert_equal ruby_json, rust_json
    end
  end

  def test_predicate_alias_rust_engine_matches_ruby_engine_byte_for_byte
    skip "cargo is not available" unless cargo_available?

    Tempfile.create(["decomplex-predicate-alias", ".rb"]) do |file|
      file.write(<<~RUBY)
        def first?; true; end
        def second?; true; end

        def nil_body; nil; end
        def other_nil_body; nil; end

        def setup
          super
          self[:type_params] ||= []
        end

        def type_params
          self[:type_params] ||= []
        end

        def emit_one
          <<~ZIG.chomp
            hi
          ZIG
        end

        def emit_two
          <<~ZIG.chomp
            bye
          ZIG
        end
      RUBY
      file.flush

      ok, ruby_json, rust_json = Decomplex::DetectorRunner.compare("predicate-alias", [file.path])

      assert ok, diff_message(ruby_json, rust_json)
      assert_equal ruby_json, rust_json
    end
  end

  def test_temporal_ordering_pressure_rust_engine_matches_ruby_engine_byte_for_byte
    skip "cargo is not available" unless cargo_available?

    Tempfile.create(["decomplex-temporal-ordering", ".rb"]) do |file|
      file.write(<<~RUBY)
        class Order
          def one; @a = 1; end
          def two; @a = 2; @b = 3; end
          def three; @b = 4; end
          def reader; @a; end
        end
      RUBY
      file.flush

      ok, ruby_json, rust_json = Decomplex::DetectorRunner.compare("temporal-ordering-pressure", [file.path])

      assert ok, diff_message(ruby_json, rust_json)
      assert_equal ruby_json, rust_json
    end
  end

  def test_state_branch_density_rust_engine_matches_ruby_engine_byte_for_byte
    skip "cargo is not available" unless cargo_available?

    Tempfile.create(["decomplex-state-branch", ".rb"]) do |file|
      file.write(<<~RUBY)
        class User < T::Struct
          const :name, String
          const :admin, T::Boolean
        end

        class Checker
          sig { params(user: User).void }
          def check(user)
            if user.admin
              @checked = true
            end
            if @checked && user.name == "admin"
              puts "Hello"
            end
          end
        end
      RUBY
      file.flush

      ok, ruby_json, rust_json = Decomplex::DetectorRunner.compare("state-branch-density", [file.path])

      assert ok, diff_message(ruby_json, rust_json)
      assert_equal ruby_json, rust_json
    end
  end

  def test_redundant_nil_guard_rust_engine_matches_ruby_engine_byte_for_byte
    skip "cargo is not available" unless cargo_available?

    Tempfile.create(["decomplex-redundant-nil", ".rb"]) do |file|
      file.write(<<~RUBY)
        def check(x)
          if x
            puts x.nil?
            x&.foo
          end
        end
      RUBY
      file.flush

      ok, ruby_json, rust_json = Decomplex::DetectorRunner.compare("redundant-nil-guard", [file.path])

      assert ok, diff_message(ruby_json, rust_json)
      assert_equal ruby_json, rust_json
    end
  end

  def test_state_mesh_rust_engine_matches_ruby_engine_byte_for_byte
    skip "cargo is not available" unless cargo_available?

    Tempfile.create(["decomplex-state-mesh", ".rb"]) do |file|
      file.write(<<~RUBY)
        class Mesh
          def initialize
            @a = 1
            @b = 2
          end

          def writer
            @a = 3
          end

          def reader
            @a + @b
          end

          def a_alias
            @a
          end
        end
      RUBY
      file.flush

      ok, ruby_json, rust_json = Decomplex::DetectorRunner.compare("state-mesh", [file.path])

      assert ok, diff_message(ruby_json, rust_json)
      assert_equal ruby_json, rust_json
    end
  end

  def test_inconsistent_rename_clone_rust_engine_matches_ruby_engine_byte_for_byte
    skip "cargo is not available" unless cargo_available?

    Tempfile.create(["decomplex-rename", ".rb"]) do |file|
      file.write(<<~RUBY)
        def one(a, b)
          res = a + b
          puts res
          res * 2
        end

        def two(x, b)
          res = x + b
          puts res
          res * 2
        end
      RUBY
      file.flush

      ok, ruby_json, rust_json = Decomplex::DetectorRunner.compare("inconsistent-rename-clone", [file.path])

      assert ok, diff_message(ruby_json, rust_json)
      assert_equal ruby_json, rust_json
    end
  end

  def test_derived_state_rust_engine_matches_ruby_engine_byte_for_byte
    skip "cargo is not available" unless cargo_available?

    Tempfile.create(["decomplex-derived", ".rb"]) do |file|
      file.write(<<~RUBY)
        def check(a)
          b = a + 1
          a = 2
          puts b
        end
      RUBY
      file.flush

      ok, ruby_json, rust_json = Decomplex::DetectorRunner.compare("derived-state", [file.path])

      assert ok, diff_message(ruby_json, rust_json)
      assert_equal ruby_json, rust_json
    end
  end

  def test_implicit_control_flow_rust_engine_matches_ruby_engine_byte_for_byte
    skip "cargo is not available" unless cargo_available?

    Tempfile.create(["decomplex-implicit", ".rb"]) do |file|
      file.write(<<~RUBY)
        class Flow
          def prepare; @a = 1; end
          def validate; @b = @a; end
          def run
            prepare
            validate
          end
        end
      RUBY
      file.flush

      ok, ruby_json, rust_json = Decomplex::DetectorRunner.compare("implicit-control-flow", [file.path])

      assert ok, diff_message(ruby_json, rust_json)
      assert_equal ruby_json, rust_json
    end
  end

  def test_weighted_inlined_complexity_rust_engine_matches_ruby_engine_byte_for_byte
    skip "cargo is not available" unless cargo_available?

    Tempfile.create(["decomplex-weighted", ".rb"]) do |file|
      file.write(<<~RUBY)
        class Complex
          def entry
            helper_one
            helper_two if condition?
          end

          private
          def helper_one
            if a; b; else; c; end
          end

          def helper_two
            while x; y; end
          end
          
          def condition?; true; end
        end
      RUBY
      file.flush

      ok, ruby_json, rust_json = Decomplex::DetectorRunner.compare("weighted-inlined-complexity", [file.path])

      assert ok, diff_message(ruby_json, rust_json)
      assert_equal ruby_json, rust_json
    end
  end

  def test_locality_drag_rust_engine_matches_ruby_engine_byte_for_byte
    skip "cargo is not available" unless cargo_available?

    Tempfile.create(["decomplex-locality", ".rb"]) do |file|
      file.write(<<~RUBY)
        def heavy(x)
          y = x + 1
          # Unrelated work
          a = 1; b = 2; c = 3; d = 4; e = 5
          puts a, b, c, d, e
          # Finally use y
          puts y
        end
      RUBY
      file.flush

      ok, ruby_json, rust_json = Decomplex::DetectorRunner.compare("locality-drag", [file.path])

      assert ok, diff_message(ruby_json, rust_json)
      assert_equal ruby_json, rust_json
    end
  end

  def test_operational_discontinuity_rust_engine_matches_ruby_engine_byte_for_byte
    skip "cargo is not available" unless cargo_available?

    Tempfile.create(["decomplex-discontinuity", ".rb"]) do |file|
      file.write(<<~RUBY)
        def phase_shift
          a = 1
          b = 2
          
          # Phase 2
          x = 3
          y = 4
          puts x, y
        end
      RUBY
      file.flush

      ok, ruby_json, rust_json = Decomplex::DetectorRunner.compare("operational-discontinuity", [file.path])

      assert ok, diff_message(ruby_json, rust_json)
      assert_equal ruby_json, rust_json
    end
  end

  def test_oversized_predicate_rust_engine_matches_ruby_engine_byte_for_byte
    skip "cargo is not available" unless cargo_available?

    Tempfile.create(["decomplex-oversized", ".rb"]) do |file|
      file.write(<<~RUBY)
        def complex_check
          if a && b && c && d
            puts "Too big"
          end
        end
      RUBY
      file.flush

      ok, ruby_json, rust_json = Decomplex::DetectorRunner.compare("oversized-predicate", [file.path])

      assert ok, diff_message(ruby_json, rust_json)
      assert_equal ruby_json, rust_json
    end
  end

  def test_path_condition_rust_engine_matches_ruby_engine_byte_for_byte
    skip "cargo is not available" unless cargo_available?

    Tempfile.create(["decomplex-path", ".rb"]) do |file|
      file.write(<<~RUBY)
        def one
          if a && b
            puts "Here"
          end
        end

        def two
          if a
            if b
              puts "Also here"
            end
          end
        end

        def three
          if a
            puts "Neglected"
          end
        end
      RUBY
      file.flush

      ok, ruby_json, rust_json = Decomplex::DetectorRunner.compare("path-condition", [file.path])

      assert ok, diff_message(ruby_json, rust_json)
      assert_equal ruby_json, rust_json
    end
  end

  def test_sequence_mine_rust_engine_matches_ruby_engine_byte_for_byte
    skip "cargo is not available" unless cargo_available?

    Tempfile.create(["decomplex-sequence", ".rb"]) do |file|
      file.write(<<~RUBY)
        def one
          prepare
          validate
          execute
        end

        def two
          prepare
          validate
          execute
        end

        def three
          prepare
          validate
          execute
        end

        def broken
          prepare
          execute
        end
      RUBY
      file.flush

      ok, ruby_json, rust_json = Decomplex::DetectorRunner.compare("sequence-mine", [file.path])

      assert ok, diff_message(ruby_json, rust_json)
      assert_equal ruby_json, rust_json
    end
  end

  def test_function_lcom_rust_engine_matches_ruby_engine_byte_for_byte
    skip "cargo is not available" unless cargo_available?

    Tempfile.create(["decomplex-lcom", ".rb"]) do |file|
      file.write(<<~RUBY)
        def disjoint_concerns
          a = 1
          b = a + 1
          puts b

          x = 2
          y = x + 2
          puts y
        end
      RUBY
      file.flush

      ok, ruby_json, rust_json = Decomplex::DetectorRunner.compare("function-lcom", [file.path])

      assert ok, diff_message(ruby_json, rust_json)
      assert_equal ruby_json, rust_json
    end
  end

  def test_false_simplicity_rust_engine_matches_ruby_engine_byte_for_byte
    skip "cargo is not available" unless cargo_available?

    Tempfile.create(["decomplex-false", ".rb"]) do |file|
      file.write(<<~RUBY)
        class Meta
          def hack
            send(:foo)
            puts "Hidden IO"
            $GLOBAL_STATE = 1
          end
        end
      RUBY
      file.flush

      ok, ruby_json, rust_json = Decomplex::DetectorRunner.compare("false-simplicity", [file.path])

      assert ok, diff_message(ruby_json, rust_json)
      assert_equal ruby_json, rust_json
    end
  end

  def test_fat_union_rust_engine_matches_ruby_engine_byte_for_byte
    skip "cargo is not available" unless cargo_available?

    Tempfile.create(["decomplex-fat", ".rb"]) do |file|
      file.write(<<~RUBY)
        def handle(node)
          case node
          when CallNode
            node.name
            node.args
          when LocalVarNode
            node.name
            node.type
          end
        end
      RUBY
      file.flush

      ok, ruby_json, rust_json = Decomplex::DetectorRunner.compare("fat-union", [file.path])

      assert ok, diff_message(ruby_json, rust_json)
      assert_equal ruby_json, rust_json
    end
  end

  def test_decision_pressure_rust_engine_matches_ruby_engine_byte_for_byte
    skip "cargo is not available" unless cargo_available?

    Tempfile.create(["decomplex-decision-pressure", ".rb"]) do |file|
      file.write(<<~RUBY)
        def scan(node)
          value = node.respond_to?(:symbol) ? node.symbol&.reg : nil
          value.nil?
        ensure
          node&.cleanup
        end
      RUBY
      file.flush

      ok, ruby_json, rust_json = Decomplex::DetectorRunner.compare("decision-pressure", [file.path])

      assert ok, diff_message(ruby_json, rust_json)
      assert_equal ruby_json, rust_json
    end
  end

  def test_local_flow_rust_engine_matches_ruby_engine_byte_for_byte
    skip "cargo is not available" unless cargo_available?

    Tempfile.create(["decomplex-local-flow", ".rb"]) do |file|
      file.write(<<~RUBY)
        class Billing
          def mixed(price, tax)
            subtotal = price + tax
            total = subtotal.round

            timestamp = Time.now
            buffer = []
            buffer << timestamp
            [total, buffer]
          end
        end
      RUBY
      file.flush

      ok, ruby_json, rust_json = Decomplex::DetectorRunner.compare("local-flow", [file.path])

      assert ok, diff_message(ruby_json, rust_json)
      assert_equal ruby_json, rust_json
    end
  end

  def test_structural_topology_rust_engine_matches_ruby_engine_byte_for_byte
    skip "cargo is not available" unless cargo_available?

    Tempfile.create(["decomplex-structural-topology", ".rb"]) do |file|
      file.write(<<~RUBY)
        class Worker
          def run(items)
            prepare
            if ready?
              validate
            end
            items.each do |item|
              helper(item)
            end
          end

          private
          def prepare; end
          def ready?; true; end
          def validate; end
          def helper(item); item; end

          public :validate
        end
      RUBY
      file.flush

      ok, ruby_json, rust_json = Decomplex::DetectorRunner.compare("structural-topology", [file.path])

      assert ok, diff_message(ruby_json, rust_json)
      assert_equal ruby_json, rust_json
    end
  end

  def test_detector_cli_compare_engines_outputs_canonical_json
    skip "cargo is not available" unless cargo_available?

    stdout, stderr, status = Open3.capture3(
      "ruby",
      "gems/decomplex/exe/decomplex",
      "detector",
      "co-update",
      "--compare-engines",
      FIXTURE
    )

    assert status.success?, stderr
    assert_equal Decomplex::DetectorRunner.canonical_json("co-update", [FIXTURE], engine: "ruby"), stdout
  end

  def test_detector_cli_compare_engines_accepts_jobs
    skip "cargo is not available" unless cargo_available?

    stdout, stderr, status = Open3.capture3(
      "ruby",
      "gems/decomplex/exe/decomplex",
      "detector",
      "co-update",
      "--compare-engines",
      "--jobs=2",
      FIXTURE
    )

    assert status.success?, stderr
    assert_equal Decomplex::DetectorRunner.canonical_json("co-update", [FIXTURE], engine: "ruby"), stdout
  end

  def test_detector_cli_benchmark_keeps_json_stdout_canonical
    stdout, stderr, status = Open3.capture3(
      "ruby",
      "gems/decomplex/exe/decomplex",
      "detector",
      "co-update",
      "--engine=ruby",
      "--json",
      "--benchmark",
      FIXTURE
    )

    assert status.success?, stderr
    assert_equal Decomplex::DetectorRunner.canonical_json("co-update", [FIXTURE], engine: "ruby"), stdout
    assert_match(/decomplex detector=co-update engine=ruby files=1 elapsed=\d+\.\d+s/, stderr)
  end

  private

  def cargo_available?
    system("cargo", "--version", out: File::NULL, err: File::NULL)
  end

  def diff_message(left, right)
    "ruby and rust detector output differed\n--- ruby\n#{left}\n--- rust\n#{right}"
  end
end
