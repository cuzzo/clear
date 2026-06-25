# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../lib/boobytrap"

class CoverageProvidersNilKillJsonlTest < Minitest::Test
  def test_handles_file
    provider = Boobytrap::CoverageProviders::NilKillJsonl
    assert_equal false, provider.handles_file?("nonexistent.jsonl")

    Dir.mktmpdir do |dir|
      file = "#{dir}/coverage-123.jsonl"
      File.write(file, '{"path": "a.rb", "lines": [1, 2]}')
      assert_equal true, provider.handles_file?(file)

      bad_file = "#{dir}/coverage-456.jsonl"
      File.write(bad_file, "{bad json}")
      assert_equal false, provider.handles_file?(bad_file)
    end
  end

  def test_load
    provider = Boobytrap::CoverageProviders::NilKillJsonl
    Dir.mktmpdir do |dir|
      file = "#{dir}/coverage-123.jsonl"
      File.write(file, '{"path": "a.rb", "lines": [1, 3]}')

      dataset = provider.load(file, root: dir)
      refute_nil dataset
      refute_empty dataset.files

      abs = File.expand_path("a.rb", dir)
      cov = dataset.files[abs]
      refute_nil cov
      assert_equal [1, nil, 1], cov.lines
    end
  end
end
