# frozen_string_literal: true

require "minitest/autorun"
require "tempfile"
require "json"
require "tmpdir"
require "fileutils"
require_relative "../lib/slopcop"
require_relative "support/branch_resultset_helper"

class ClassifierTest < Minitest::Test
  include BranchResultsetHelper

  C = SlopCop::Classifier

  def with_env(key, value)
    old = ENV[key]
    value.nil? ? ENV.delete(key) : ENV[key] = value
    yield
  ensure
    old.nil? ? ENV.delete(key) : ENV[key] = old
  end

  def test_type_guard_detects_is_a_nil_respond_and_safe_nav
    assert C.type_guard_text?("x.is_a?(Type)")
    assert C.type_guard_text?("x.nil?")
    assert C.type_guard_text?("x.respond_to?(:y)")
    assert C.type_guard_text?("x&.foo")
    refute C.type_guard_text?("x + 1")
    refute C.type_guard_text?("x.bar(1)")
  end

  def test_language_lexicons_drive_type_guard_detection
    assert C.type_guard_text?("x.is_a?(Type)", language: :ruby)
    refute C.type_guard_text?("x.is_a?(Type)", language: :python)
    assert C.type_guard_text?("isinstance(x, Type)", language: :python)
    assert C.type_guard_text?("value is None", language: :python)
    assert C.type_guard_text?("typeof value === 'string'", language: :javascript)
    assert C.type_guard_text?("err != nil", language: :go)
    assert C.type_guard_text?("value.is_none()", language: :rust)
    assert C.type_guard_text?("@typeInfo(T)", language: :zig)
  end

  def test_language_lexicons_drive_diagnostic_detection
    assert C.diagnostic_text?("raise 'x'", language: :ruby)
    refute C.diagnostic_text?("panic('x')", language: :ruby)
    assert C.diagnostic_text?("raise ValueError('x')", language: :python)
    assert C.diagnostic_text?("throw new Error('x')", language: :typescript)
    assert C.diagnostic_text?("panic(\"bad\")", language: :go)
    assert C.diagnostic_text?("panic!(\"bad\")", language: :rust)
    assert C.diagnostic_text?("@panic(\"bad\")", language: :zig)
  end

  def test_categorize_uses_language_lexicon
    assert_equal :diagnostic,
                 C.categorize_text("m", :if, "panic(\"bad\")", true,
                                   nil, [], [], language: :go)
    assert_equal :type_norm,
                 C.categorize_text("m", :if, "return 1", false,
                                   "isinstance(x, Type)", [], [], language: :python)
  end

  def test_trivial_is_the_narrow_inert_residue
    assert C.trivial_text?(nil)
    assert C.trivial_text?("nil")
    refute C.trivial_text?("foo(1)")          # a call
    refute C.trivial_text?("return 5")        # an outcome
    refute C.trivial_text?("x = 1")           # an assignment
  end

  def test_categorize_priority_order
    g = "x.is_a?(Type)"
    # FFI method name wins first
    assert_equal :ffi, C.categorize_text("lower_require", :if, g, true, nil, ["lower_require"])
    # diagnostic (raise) before type_norm
    assert_equal :diagnostic, C.categorize_text("m", :if, "raise 'x'", true)
    # type_norm before dead/defensive
    assert_equal :type_norm, C.categorize_text("m", :if, g, false)
    # no sibling taken + not type/diag/ffi -> dead
    assert_equal :dead, C.categorize_text("m", :if, "foo(1)", false)
    # live + trivial -> defensive
    assert_equal :defensive, C.categorize_text("m", :if, "nil", true)
    # live + real body + branch kind -> genuine
    assert_equal :genuine, C.categorize_text("m", :case, "foo(1)", true)
  end

  def test_project_supplied_diagnostic_methods_are_opt_in
    diag = "report_invalid_input!(x)"
    assert_equal :genuine, C.categorize_text("m", :if, diag, true),
                 "project helper names are not baked into the gem"
    assert_equal :diagnostic,
                 C.categorize_text("m", :if, diag, true, nil, [], [:report_invalid_input!])
  end

  # Real resultset via stdlib Coverage (same branch-tuple shape SimpleCov
  # uses), so classify_file runs the true path on real dark arms.
  def test_classify_file_on_real_coverage
    src = <<~RB
      def shape(x, n)
        return 0 if x.is_a?(String)        # type_norm (dark: never String)
        if n > 0
          a = 1
        else
          a = 2                            # genuine-ish (dark else, sibling taken)
        end
        a
      end
      shape(7, 5)
    RB
    f = Tempfile.new(["cov", ".rb"])
    f.write(src)
    f.close
    rsf = Tempfile.new(["rs", ".json"])
    write_branch_resultset(f.path, rsf.path)

    arms = C.classify_file(rsf.path, f.path)
    cats = arms.map(&:category)
    assert_includes cats, :type_norm, "the never-true String guard"
    refute_empty arms
  ensure
    f&.unlink
    rsf&.unlink
  end

  def test_classify_file_uses_project_diagnostic_lexicon
    src = <<~RB
      def report_invalid_input!(x)
        x
      end

      def shape(n)
        if n > 0
          1
        else
          report_invalid_input!(n)
        end
      end

      shape(1)
    RB
    f = Tempfile.new(["cov", ".rb"])
    f.write(src)
    f.close
    rsf = Tempfile.new(["rs", ".json"])
    write_branch_resultset(f.path, rsf.path)

    default_cats = C.classify_file(rsf.path, f.path).map(&:category)
    custom_cats = C.classify_file(rsf.path, f.path,
                                  diagnostic_mids: [:report_invalid_input!]).map(&:category)
    assert_includes default_cats, :genuine
    assert_includes custom_cats, :diagnostic
    refute_includes custom_cats, :genuine
  ensure
    f&.unlink
    rsf&.unlink
  end

  def test_tree_sitter_static_zig_classification_when_coverage_is_absent
    grammar = ENV["DECOMPLEX_TS_ZIG_PATH"]
    skip "set DECOMPLEX_TS_ZIG_PATH to run Zig Tree-sitter static test" unless grammar && File.file?(grammar)

    src = <<~ZIG
      const Worker = struct {
          count: i32 = 0,

          fn run(self: *Worker, x: i32) bool {
              if (x > 0) {
                  self.count += 1;
                  return true;
              } else {
                  return false;
              }
              switch (x) {
                  1 => return true,
                  2 => return false,
                  else => return false,
              }
          }
      };
    ZIG
    f = Tempfile.new(["slopcop-zig", ".zig"])
    f.write(src)
    f.close

    with_env("DECOMPLEX_PARSER", "tree_sitter") do
      arms = C.classify_file("/missing-resultset.json", f.path)

      refute_empty arms
      assert arms.all? { |arm| arm.source == :tree_sitter_static }
      assert_includes arms.map(&:defn), "run"
      assert_includes arms.map(&:category), :genuine
    end
  ensure
    f&.unlink
  end

  def test_kcov_cobertura_zig_classification_infers_dark_arms_from_line_hits
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/src")
      file = "#{dir}/src/worker.zig"
      File.write(file, <<~ZIG)
        const Worker = struct {
            count: i32 = 0,

            fn run(self: *Worker, x: i32) bool {
                if (x > 0) {
                    return true;
                } else {
                    self.count += 1;
                    return false;
                }
            }
        };
      ZIG
      coverage = "#{dir}/cobertura.xml"
      File.write(coverage, <<~XML)
        <?xml version="1.0" ?>
        <coverage>
          <sources><source>#{dir}</source></sources>
          <packages><package name=""><classes>
            <class name="worker" filename="src/worker.zig">
              <lines>
                <line number="4" hits="1"/>
                <line number="5" hits="1"/>
                <line number="6" hits="1"/>
                <line number="8" hits="0"/>
                <line number="9" hits="0"/>
              </lines>
            </class>
          </classes></package></packages>
        </coverage>
      XML

      with_env("DECOMPLEX_PARSER", "tree_sitter") do
        arms = C.classify_file(coverage, file, root: dir)

        refute_empty arms
        assert arms.all? { |arm| arm.source == :tree_sitter_static }
        assert_equal ["run"], arms.map(&:defn).uniq
        assert_includes arms.map(&:line), 7
        assert_includes arms.map(&:category), :genuine
      end
    end
  end

  def test_nil_kill_branch_coverage_zig_classification_uses_native_dark_arms
    grammar = ENV["DECOMPLEX_TS_ZIG_PATH"]
    skip "set DECOMPLEX_TS_ZIG_PATH to run Zig native branch coverage test" unless grammar && File.file?(grammar)

    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/src")
      file = "#{dir}/src/worker.zig"
      File.write(file, <<~ZIG)
        const Worker = struct {
            count: i32 = 0,

            fn run(self: *Worker, x: i32) bool {
                if (x > 0) {
                    return true;
                } else {
                    self.count += 1;
                    return false;
                }
            }
        };
      ZIG
      catalog = SlopCop::CoverageData.branch_catalog(["src/worker.zig"], root: dir)
      file_entry = catalog.fetch("files").first
      file_entry["lines"] = { "4" => 1, "5" => 1, "6" => 1, "8" => 0, "9" => 0 }
      file_entry["arms"] = file_entry.fetch("arms").map do |arm|
        arm.merge("hits" => (arm["label"] == "then" ? 1 : 0))
      end
      else_line = file_entry.fetch("arms").find { |arm| arm["label"] == "else" }.fetch("arm_line")
      coverage = "#{dir}/branch-coverage.json"
      File.write(coverage, JSON.dump(catalog.merge("format" => "nil-kill.branch-coverage")))

      with_env("DECOMPLEX_PARSER", nil) do
        arms = C.classify_file(coverage, file, root: dir)

        refute_empty arms
        assert arms.all? { |arm| arm.source == :native_branch }
        assert_includes arms.map(&:defn), "run"
        assert_includes arms.map(&:category), :genuine
        assert_equal [else_line], arms.map(&:line)
      end
    end
  end

  def test_coverage_py_json_python_classification_uses_branch_arcs
    grammar = ENV["DECOMPLEX_TS_PYTHON_PATH"]
    skip "set DECOMPLEX_TS_PYTHON_PATH to run Python branch coverage test" unless grammar && File.file?(grammar)

    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/src")
      file = "#{dir}/src/worker.py"
      File.write(file, <<~PY)
        def choose(x):
            if x:
                return 1
            else:
                return 2
      PY
      coverage = "#{dir}/coverage.json"
      File.write(coverage, JSON.dump(
        "meta" => { "format" => 2, "branch_coverage" => true },
        "files" => {
          "src/worker.py" => {
            "executed_lines" => [1, 2, 3],
            "missing_lines" => [5],
            "executed_branches" => [[2, 3]],
            "missing_branches" => [[2, 5]]
          }
        }
      ))

      with_env("DECOMPLEX_PARSER", nil) do
        arms = C.classify_file(coverage, file, root: dir)
        refute_empty arms
        assert arms.all? { |arm| arm.source == :coverage_py }
        assert_equal ["choose"], arms.map(&:defn)
        assert_equal [:genuine], arms.map(&:category)
        assert_equal [4], arms.map(&:line)
      end
    end
  end

  def test_kcov_covered_zig_file_does_not_fall_back_to_static
    grammar = ENV["DECOMPLEX_TS_ZIG_PATH"]
    skip "set DECOMPLEX_TS_ZIG_PATH to run Zig Tree-sitter kcov test" unless grammar && File.file?(grammar)

    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/src")
      file = "#{dir}/src/worker.zig"
      File.write(file, <<~ZIG)
        fn run(x: i32) bool {
            if (x > 0) {
                return true;
            } else {
                return false;
            }
        }
      ZIG
      coverage = "#{dir}/cobertura.xml"
      File.write(coverage, <<~XML)
        <?xml version="1.0" ?>
        <coverage>
          <sources><source>#{dir}</source></sources>
          <packages><package name=""><classes>
            <class name="worker" filename="src/worker.zig">
              <lines>
                <line number="2" hits="1"/>
                <line number="3" hits="1"/>
                <line number="5" hits="1"/>
              </lines>
            </class>
          </classes></package></packages>
        </coverage>
      XML

      with_env("DECOMPLEX_PARSER", "tree_sitter") do
        assert_empty C.classify_file(coverage, file, root: dir)
      end
    end
  end
end
