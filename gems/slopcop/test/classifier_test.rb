# frozen_string_literal: true

require "minitest/autorun"
require "tempfile"
require "json"
require "coverage"
require "tmpdir"
require "fileutils"
require_relative "../lib/slopcop"

class ClassifierTest < Minitest::Test
  C = SlopCop::Classifier

  def with_env(key, value)
    old = ENV[key]
    value.nil? ? ENV.delete(key) : ENV[key] = value
    yield
  ensure
    old.nil? ? ENV.delete(key) : ENV[key] = old
  end

  def node(expr)
    RubyVM::AbstractSyntaxTree.parse(expr).children.last
  end

  def test_type_guard_detects_is_a_nil_respond_and_safe_nav
    assert C.type_guard?(node("x.is_a?(Type)"))
    assert C.type_guard?(node("x.nil?"))
    assert C.type_guard?(node("x.respond_to?(:y)"))
    assert C.type_guard?(node("x&.foo"))
    refute C.type_guard?(node("x + 1"))
    refute C.type_guard?(node("x.bar(1)"))
  end

  def test_trivial_is_the_narrow_inert_residue
    assert C.trivial?(nil)
    assert C.trivial?(node("nil"))
    refute C.trivial?(node("foo(1)"))          # a call
    refute C.trivial?(node("return 5"))        # an outcome
    refute C.trivial?(node("x = 1"))           # an assignment
  end

  def test_categorize_priority_order
    g = node("x.is_a?(Type)")
    # FFI method name wins first
    assert_equal :ffi, C.categorize("lower_require", :if, g, true, nil, ["lower_require"])
    # diagnostic (raise) before type_norm
    assert_equal :diagnostic, C.categorize("m", :if, node("raise 'x'"), true)
    # type_norm before dead/defensive
    assert_equal :type_norm, C.categorize("m", :if, g, false)
    # no sibling taken + not type/diag/ffi -> dead
    assert_equal :dead, C.categorize("m", :if, node("foo(1)"), false)
    # live + trivial -> defensive
    assert_equal :defensive, C.categorize("m", :if, node("nil"), true)
    # live + real body + branch kind -> genuine
    assert_equal :genuine, C.categorize("m", :case, node("foo(1)"), true)
  end

  def test_project_supplied_diagnostic_methods_are_opt_in
    diag = node("report_invalid_input!(x)")
    assert_equal :genuine, C.categorize("m", :if, diag, true),
                 "project helper names are not baked into the gem"
    assert_equal :diagnostic,
                 C.categorize("m", :if, diag, true, nil, [], nil, nil, false,
                              [:report_invalid_input!])
  end

  def test_non_decision_coverage_artifact_is_noise_not_defensive
    pnode = RubyVM::AbstractSyntaxTree.parse("class C; end").children.last
    assert_nil C.categorize("m", :if, nil, false, nil, [], pnode)
    assert_nil C.categorize("m", :if, nil, false, nil, [], nil, "end")
    assert_nil C.categorize("m", :if, nil, false, nil, [], nil, "sig { returns(T::Boolean) }")
    assert_nil C.categorize("m", :if, nil, true, nil, [], nil, "")
    assert_nil C.categorize("m", :if, nil, true, nil, [], nil, "def shape(x)")
    assert_nil C.categorize("m", :if, nil, true, nil, [], nil, "include Expr")
  end

  def test_private_class_method_defs_are_attributed_to_method_body
    lines = <<~RB.lines
      module M
        private_class_method def self.shape(x = {})
          if x
            1
          else
            2
          end
        end
      end
    RB
    idx = C.method_index(lines)
    assert_equal "shape", idx[3]
    assert_equal "shape", idx[6]
  end

  def test_endless_defs_do_not_leak_method_attribution
    lines = <<~RB.lines
      def one = 1
      if x
        1
      end
    RB
    idx = C.method_index(lines)
    assert_equal "(top-level)", idx[2]
  end

  def test_sorbet_declaration_lines_are_noise
    lines = <<~RB.lines
      sig do
        params(
          value: String,
        ).returns(Integer)
      end
      const :value, String
      prop :out, T::Array[String]
    RB
    noise = C.declaration_noise_lines(lines)
    assert_equal Set.new(1..7), noise
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
    Coverage.start(branches: true)
    load f.path
    res = Coverage.result
    rs = { "T" => { "coverage" => { f.path => { "branches" => res.dig(f.path, :branches) } } } }
    rsf = Tempfile.new(["rs", ".json"])
    rsf.write(JSON.dump(rs))
    rsf.close

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
    Coverage.start(branches: true)
    load f.path
    res = Coverage.result
    rs = { "T" => { "coverage" => { f.path => { "branches" => res.dig(f.path, :branches) } } } }
    rsf = Tempfile.new(["rs", ".json"])
    rsf.write(JSON.dump(rs))
    rsf.close

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

  def test_kcov_cobertura_zig_classification_uses_normalized_line_hits
    grammar = ENV["DECOMPLEX_TS_ZIG_PATH"]
    skip "set DECOMPLEX_TS_ZIG_PATH to run Zig Tree-sitter kcov test" unless grammar && File.file?(grammar)

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
        assert arms.all? { |arm| arm.source == :kcov }
        assert_includes arms.map(&:defn), "run"
        assert_includes arms.map(&:category), :genuine
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
