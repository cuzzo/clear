# frozen_string_literal: true

return unless ENV["NIL_KILL_SUBPROCESS_COVERAGE_CHILD"] == "1"

begin
  require "simplecov"
rescue LoadError
  return
end

root = File.expand_path("../../../..", __dir__)
SimpleCov.root(root)
SimpleCov.command_name "nil-kill-subprocess-#{Process.pid}"
SimpleCov.coverage_dir ENV.fetch("NIL_KILL_SUBPROCESS_COVERAGE_DIR", File.join(root, "coverage", "ruby-gems"))
SimpleCov.print_error_status = false
SimpleCov.minimum_coverage 0
SimpleCov.formatter SimpleCov::Formatter::SimpleFormatter
SimpleCov.start do
  enable_coverage :branch
  add_filter "/gems/nil-kill/spec/"
  add_filter "/tmp/"
  add_filter "/vendor/"
end
