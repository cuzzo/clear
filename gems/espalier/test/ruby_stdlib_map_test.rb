# frozen_string_literal: true

require "minitest/autorun"
require "yaml"

class RubyStdlibMapTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  SUPPORT = File.join(
    ROOT,
    "fact-mine",
    "config",
    "stdlib_maps",
    "support.yml"
  )

  def test_ruby_core_identity_blocker_is_machine_readable
    ruby = YAML.safe_load_file(SUPPORT).fetch("languages").fetch("ruby")
    assert_equal "blocked", ruby.fetch("status")
    assert_equal "project_scoped_core_symbols", ruby.fetch("blocker")
    assert_includes ruby.fetch("required_fix"), "stable runtime package"
  end
end
