# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "../lib/boobytrap"

class DecomplexRiskCovTest < Minitest::Test
  def test_load_decomplex_syntax_rescue
    # Simulate missing Decomplex::Syntax and missing files
    old_const = Object.send(:remove_const, :Decomplex) if defined?(Decomplex)
    
    # Stub require to raise LoadError
    Boobytrap::DecomplexRisk.stub :require, ->(_) { raise LoadError } do
      # Also need to stub File.file? to return false for the sibling check
      File.stub :file?, false do
        refute Boobytrap::DecomplexRisk.send(:load_decomplex_syntax)
      end
    end
  ensure
    Object.const_set(:Decomplex, old_const) if old_const
  end

  def test_load_decomplex_source_filter_rescue
    # Simulate load error falling back to sibling
    Boobytrap::DecomplexRisk.stub :require, ->(path) { 
      raise LoadError if path == "espalier/type_profile"
      true 
    } do
      File.stub :file?, true do
        assert Boobytrap::DecomplexRisk.send(:load_decomplex_source_filter)
      end
    end
  end

  def test_relpath_enoent
    assert_equal "missing.rb", Boobytrap::DecomplexRisk.relpath("invalid_missing/missing.rb", "invalid_missing")
  end

  def test_load_decomplex_source_filter
    Boobytrap::DecomplexRisk.stub :load_decomplex_source_filter, false do
      Dir.mktmpdir do |dir|
        File.write("#{dir}/test.rb", "test")
        assert Boobytrap::DecomplexRisk.source_file?("test.rb", root: dir)
        refute Boobytrap::DecomplexRisk.source_file?("test.txt", root: dir)
        refute Boobytrap::DecomplexRisk.excluded_path?("test.rb", root: dir)
      end
    end
  end

  def test_language_for
    assert_equal "ruby", Decomplex::Syntax.language_for("a.rb")
    assert_equal "python", Decomplex::Syntax.language_for("a.py")
    assert_equal "javascript", Decomplex::Syntax.language_for("a.js")
    assert_equal "typescript", Decomplex::Syntax.language_for("a.ts")
    assert_equal "go", Decomplex::Syntax.language_for("a.go")
    assert_equal "rust", Decomplex::Syntax.language_for("a.rs")
    assert_equal "zig", Decomplex::Syntax.language_for("a.zig")
    assert_equal "c", Decomplex::Syntax.language_for("a.c")
    assert_equal "cpp", Decomplex::Syntax.language_for("a.cpp")
    assert_equal "csharp", Decomplex::Syntax.language_for("a.cs")
    assert_equal "kotlin", Decomplex::Syntax.language_for("a.kt")
    assert_equal "generic", Decomplex::Syntax.language_for("a.txt")
  end

  def test_parse_rescue
    Decomplex::Syntax.stub :language_for, ->(_) { raise "error" } do
      doc = Decomplex::Syntax.parse("a.rb")
      assert_equal "generic", doc.language
      assert_empty doc.branch_arms
    end
  end

  def test_supported_exts
    assert_includes Boobytrap::DecomplexRisk.supported_exts, ".rb"
  end

end
