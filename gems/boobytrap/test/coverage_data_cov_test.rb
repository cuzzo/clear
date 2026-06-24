# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "tmpdir"
require_relative "../lib/boobytrap"

class CoverageDataCovTest < Minitest::Test
  def test_format_label_and_branch_source
    data = Boobytrap::CoverageData
    assert_equal "SimpleCov", data.format_label(:simplecov)
    assert_equal "kcov Cobertura", data.format_label(:kcov_cobertura)
    assert_equal "kcov codecov", data.format_label(:kcov_codecov)
    assert_equal "Nil-Kill branch coverage", data.format_label(:nil_kill_branch)
    assert_equal "coverage.py JSON", data.format_label(:coverage_py)
    assert_equal "merged coverage", data.format_label(:multi)
    assert_equal "unknown", data.format_label(:unknown)

    assert_equal :native_branch, data.branch_source(:nil_kill_branch)
    assert_equal :coverage_py, data.branch_source(:coverage_py)
    assert_equal :coverage, data.branch_source(:simplecov)
    assert_equal :other, data.branch_source(:other)
  end

  def test_merge_native_arms
    data = Boobytrap::CoverageData
    arm1 = Boobytrap::CoverageData::NativeBranchArm.new(arm_id: "1", branch_id: "b1", kind: "if", member: "then", hits: 1)
    arm2 = Boobytrap::CoverageData::NativeBranchArm.new(arm_id: "2", branch_id: "b1", kind: "if", member: "else", hits: 2)
    arm3 = Boobytrap::CoverageData::NativeBranchArm.new(arm_id: "1", branch_id: "b1", kind: "if", member: "then", hits: 5)
    
    target = [arm1, arm2]
    source = [arm3]
    
    data.send(:merge_native_branch_arms!, target, source)
    
    assert_equal 2, target.size
    assert_equal 6, target[0].hits
    assert_equal 2, target[1].hits
  end

  def test_language_for
    data = Boobytrap::CoverageData
    assert_equal "zig", data.send(:language_for, "a.zig")
    assert_equal "python", data.send(:language_for, "a.py")
    assert_equal "javascript", data.send(:language_for, "a.js")
    assert_equal "javascript", data.send(:language_for, "a.jsx")
    assert_equal "typescript", data.send(:language_for, "a.ts")
    assert_equal "go", data.send(:language_for, "a.go")
    assert_equal "rust", data.send(:language_for, "a.rs")
    assert_equal "ruby", data.send(:language_for, "a.rb")
    assert_equal "unknown", data.send(:language_for, "a.txt")
  end

  def test_realish_path
    data = Boobytrap::CoverageData
    assert_equal File.expand_path("does_not_exist"), data.send(:realish_path, "does_not_exist")
  end

  def test_load_uncached_unsupported
    data = Boobytrap::CoverageData
    res = data.send(:load_uncached, "unsupported.txt", root: Dir.pwd)
    assert_empty res.files
  end

  def test_load_json_unknown
    Dir.mktmpdir do |dir|
      file = "#{dir}/unknown.json"
      File.write(file, '{"some": "data"}')
      res = Boobytrap::CoverageData.send(:load_json, file, root: dir)
      assert_empty res.files
    end
  end

  def test_dark_branch_misses_by_line
    data = Boobytrap::CoverageData
    arm1 = Minitest::Mock.new
    arm1.expect :covered, true
    arm1.expect :arm, Struct.new(:line).new(1)
    
    arm2 = Minitest::Mock.new
    arm2.expect :covered, false
    arm2.expect :arm, Struct.new(:line).new(2)
    
    data.stub :branch_arm_coverage, [arm1, arm2] do
      misses = data.dark_branch_misses_by_line(nil, nil)
      assert_equal 1, misses[2]
      assert_equal 0, misses[1]
    end
  end

  def test_native_branch_arm_coverage
    data = Boobytrap::CoverageData
    arm_native = Minitest::Mock.new
    arm_native.expect :arm_id, "arm1"
    arm_native.expect :arm_id, "arm1"
    arm_native.expect :hits, 5
    arm_native.expect :hits, 5

    file_cov = Minitest::Mock.new
    file_cov.expect :branch_arms, [arm_native]
    file_cov.expect :format, :simplecov

    arm = Minitest::Mock.new
    arm.expect :line, 1
    arm.expect :arm_id, "arm1"

    data.stub :native_arm_signature, "arm1" do
      res = data.native_branch_arm_coverage(file_cov, [arm])
      assert_equal 1, res.size
      assert_equal 5, res.first.hits
    end
  end

  def test_line_branch_arm_coverage
    data = Boobytrap::CoverageData
    
    file_cov = Minitest::Mock.new
    file_cov.expect :branch_arm_coverage?, false
    file_cov.expect :branch_coverage?, false
    file_cov.expect :line_coverage?, true
    file_cov.expect :line_hits, 5, [1]
    file_cov.expect :line_hits, 0, [2]
    
    arm = Minitest::Mock.new
    arm.expect :span, [1, 0, 2, 0]
    arm.expect :span, [1, 0, 2, 0]
    
    coverage = data.branch_arm_coverage(file_cov, [arm])
    
    assert_equal 1, coverage.length
    assert coverage.first.covered
    assert_equal 5, coverage.first.hits
    
    file_cov.verify
    arm.verify
  end

  def test_branch_catalog
    data = Boobytrap::CoverageData
    
    Boobytrap::CoverageData.stub :load_decomplex_syntax, false do
      res = data.branch_catalog([], root: "/tmp")
      assert_equal 1, res["schema_version"]
      assert_equal "nil-kill.branch-catalog", res["format"]
      assert_equal [], res["files"]
    end

    Boobytrap::CoverageData.stub :load_decomplex_syntax, true do
      Dir.mktmpdir do |dir|
        File.write("#{dir}/test.rb", "test")
        
        doc = Minitest::Mock.new
        doc.expect :language, "ruby"
        arm = Minitest::Mock.new
        arm.expect :kind, "if"
        arm.expect :kind, "if"
        arm.expect :member, "true"
        arm.expect :member, "true"
        arm.expect :decision_line, 1
        arm.expect :decision_span, [1, 1, 1, 4]
        arm.expect :decision_span, [1, 1, 1, 4]
        arm.expect :line, 2
        arm.expect :span, [2, 1, 2, 4]
        arm.expect :span, [2, 1, 2, 4]
        doc.expect :branch_arms, [arm]
        
        Decomplex::Syntax.stub :parse, doc do
          res = data.branch_catalog(["test.rb"], root: dir)
          assert_equal 1, res["files"].length
          assert_equal "ruby", res["files"].first["language"]
          assert_equal 1, res["files"].first["arms"].length
          assert_equal "if", res["files"].first["arms"].first["kind"]
        end
        
        arm.verify
        doc.verify
      end
    end
  end

  def test_arm_language
    data = Boobytrap::CoverageData
    arm = Minitest::Mock.new
    
    [
      ["test.zig", "zig"],
      ["test.py", "python"],
      ["test.js", "javascript"],
      ["test.ts", "typescript"],
      ["test.go", "go"],
      ["test.rs", "rust"],
      ["test.rb", "ruby"],
      ["test.txt", "unknown"]
    ].each do |ext, lang|
      arm.expect :file, ext
      assert_equal lang, data.arm_language(arm)
    end
    
    arm.verify
  end

  def test_language_for
    data = Boobytrap::CoverageData
    
    assert_equal "zig", data.language_for("test.zig")
    assert_equal "python", data.language_for("test.py")
    assert_equal "javascript", data.language_for("test.js")
    assert_equal "typescript", data.language_for("test.ts")
    assert_equal "go", data.language_for("test.go")
    assert_equal "rust", data.language_for("test.rs")
    assert_equal "ruby", data.language_for("test.rb")
    assert_equal "unknown", data.language_for("test.txt")
  end

  def test_branch_kind_compatible
    data = Boobytrap::CoverageData
    
    assert data.branch_kind_compatible?("if", "if")
    assert data.branch_kind_compatible?("if", "unless")
    refute data.branch_kind_compatible?("if", "case")
    
    assert data.branch_kind_compatible?("case", "case")
    refute data.branch_kind_compatible?("case", "if")
    
    assert data.branch_kind_compatible?("loop", "while")
    assert data.branch_kind_compatible?("loop", "until")
    assert data.branch_kind_compatible?("loop", "for")
    refute data.branch_kind_compatible?("loop", "if")
    
    assert data.branch_kind_compatible?("other", "other")
    refute data.branch_kind_compatible?("other", "different")
  end

  def test_matching_branch_arms
    data = Boobytrap::CoverageData
    
    arm = Minitest::Mock.new
    arm.expect :kind, "if"
    arm.expect :span, [2, 0, 3, 0]
    arm.expect :span, [2, 0, 3, 0]
    arm.expect :line, 1
    arm.expect :member, "true"
    def arm.decision_span; [1, 0, 4, 0]; end
    
    parent = { kind: "if", span: [1, 0, 4, 0] }
    tuple = { span: [1, 0, 1, 10], kind: "true" }
    
    res = data.matching_branch_arms([arm], parent, tuple)
    assert_equal 1, res.length
    
    arm.verify
  end

  def test_load_uncached
    data = Boobytrap::CoverageData
    
    # Json
    data.stub :load_json, :json_loaded do
      assert_equal :json_loaded, data.send(:load_uncached, "a.json", root: Dir.pwd)
      assert_equal :json_loaded, data.send(:load_uncached, "a.JSON", root: Dir.pwd)
    end
    
    # XML
    data.stub :load_cobertura, :xml_loaded do
      assert_equal :xml_loaded, data.send(:load_uncached, "a.xml", root: Dir.pwd)
    end
    
    # unknown
    res = data.send(:load_uncached, "a.unknown", root: Dir.pwd)
    assert_empty res.files
  end

  def test_load_json_formats
    data = Boobytrap::CoverageData
    
    Dir.mktmpdir do |dir|
      file = "#{dir}/a.json"
      File.write(file, '{"some": "data"}')
      
      data.stub :simplecov_resultset?, true do
        data.stub :load_simplecov, :simplecov_loaded do
          assert_equal :simplecov_loaded, data.send(:load_json, file, root: dir)
        end
      end
      
      data.stub :simplecov_resultset?, false do
        data.stub :nil_kill_branch_coverage?, true do
          data.stub :load_nil_kill_branch_coverage, :nil_kill_loaded do
            assert_equal :nil_kill_loaded, data.send(:load_json, file, root: dir)
          end
        end
      end

      data.stub :simplecov_resultset?, false do
        data.stub :nil_kill_branch_coverage?, false do
          data.stub :kcov_codecov?, true do
            data.stub :load_kcov_codecov, :kcov_loaded do
              assert_equal :kcov_loaded, data.send(:load_json, file, root: dir)
            end
          end
        end
      end
    end
  end

  def test_arm_language
    data = Boobytrap::CoverageData
    
    arm1 = Minitest::Mock.new
    arm1.expect :file, "a.zig"
    assert_equal "zig", data.send(:arm_language, arm1)

    arm2 = Minitest::Mock.new
    arm2.expect :file, "a.py"
    assert_equal "python", data.send(:arm_language, arm2)
  end

  def test_static_arm_id
    data = Boobytrap::CoverageData
    
    file_cov = Minitest::Mock.new
    file_cov.expect :source_path, "a.zig"
    file_cov.expect :language, ""
    file_cov.expect :language, ""
    
    arm = Minitest::Mock.new
    arm.expect :file, "a.zig"
    arm.expect :line, 1
    arm.expect :branch_id, "b1"
    arm.expect :member, "m1"
    arm.expect :decision_span, [1, 2]
    arm.expect :respond_to?, true, [:arm_span]
    arm.expect :arm_span, [3, 4]
    arm.expect :respond_to?, true, [:member]
    arm.expect :line, 1
    arm.expect :respond_to?, true, [:kind]
    arm.expect :kind, "if"
    arm.expect :respond_to?, true, [:body]
    arm.expect :body, ""
    arm.expect :respond_to?, true, [:span]
    arm.expect :span, [1, 2, 3, 4]
    
    id = data.send(:static_arm_id, file_cov, arm)
    assert id
  end
end
