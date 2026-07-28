# frozen_string_literal: true

require "minitest/autorun"

class PhpStdlibMapTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  PHP = File.join(ROOT, "fact-mine", "config", "stdlib_maps", "php")

  def test_consumer_indexer_patch_uses_commit_qualified_version
    patch = File.read(File.join(PHP, "scip-php-exact-version.patch"))
    assert_includes patch, "$version = '0.0.1+71a5b117';"
  end
end
