# frozen_string_literal: true

if ENV["NIL_KILL_COVERAGE"] == "1"
  require "simplecov"

  begin
    require "simplecov-cobertura"
    cobertura_available = true
  rescue LoadError
    cobertura_available = false
  end

  SimpleCov.command_name "nil-kill"
  SimpleCov.coverage_dir "coverage/nil-kill"
  SimpleCov.print_error_status = false
  SimpleCov.minimum_coverage 0
  SimpleCov.start do
    enable_coverage :branch
    track_files "gems/nil-kill/lib/**/*.rb"
    track_files "gems/auto-type/lib/**/*.rb"
    add_filter "/gems/nil-kill/spec/"
    add_group "nil-kill", "gems/nil-kill/lib"
    add_group "auto-type", "gems/auto-type/lib"

    if cobertura_available
      formatter SimpleCov::Formatter::MultiFormatter.new([
        SimpleCov::Formatter::HTMLFormatter,
        SimpleCov::Formatter::CoberturaFormatter,
      ])
    end
  end
end

require "fileutils"
require "open3"
require "tmpdir"
require "stringio"

nil_kill_root = File.expand_path("../../..", __dir__)
ENV["NIL_KILL_TMP_DIR"] ||= File.join(nil_kill_root, "tmp", "nil-kill-spec", Process.pid.to_s)

require_relative "../lib/nil_kill"

module NilKillSpecHelpers
  NIL_KILL_PATH_CONSTANTS = %i[
    TMP_DIR RUNTIME_DIR INSTRUMENTED_DIR EVIDENCE_PATH REPORT_PATH TRACE_PLAN_PATH SORBET_PAYLOAD_DIR
  ].freeze

  def reset_nil_kill_tmp_paths!(tmp_dir)
    root = NilKill::ROOT
    paths = {
      TMP_DIR: File.expand_path(tmp_dir, root),
      RUNTIME_DIR: File.join(File.expand_path(tmp_dir, root), "runtime"),
      INSTRUMENTED_DIR: File.join(File.expand_path(tmp_dir, root), "instrumented"),
      EVIDENCE_PATH: File.join(File.expand_path(tmp_dir, root), "evidence.json"),
      REPORT_PATH: File.join(File.expand_path(tmp_dir, root), "report.md"),
      TRACE_PLAN_PATH: File.join(File.expand_path(tmp_dir, root), "trace-plan.json"),
      SORBET_PAYLOAD_DIR: File.join(File.expand_path(tmp_dir, root), "sorbet-payload"),
    }
    old_verbose = $VERBOSE
    $VERBOSE = nil
    paths.each do |name, value|
      NilKill.send(:remove_const, name) if NilKill.const_defined?(name, false)
      NilKill.const_set(name, value)
    end
  ensure
    $VERBOSE = old_verbose
  end

  def repo_tmp_file(name, body)
    dir = File.join(NilKill::ROOT, "tmp", "nil-kill-spec-#{Process.pid}-#{object_id}")
    FileUtils.mkdir_p(dir)
    path = File.join(dir, name)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, body)
    [path, Pathname.new(path).relative_path_from(Pathname.new(NilKill::ROOT)).to_s]
  end

  def isolated_env(vars)
    old = vars.each_key.to_h { |key| [key, ENV[key]] }
    vars.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    old.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end
end

RSpec.configure do |config|
  config.include NilKillSpecHelpers

  config.around do |example|
    old_tmp = ENV["NIL_KILL_TMP_DIR"]
    tmp = File.join(nil_kill_root, "tmp", "nil-kill-spec", Process.pid.to_s, example.id.gsub(/[^\w.-]+/, "_"))
    ENV["NIL_KILL_TMP_DIR"] = tmp
    reset_nil_kill_tmp_paths!(tmp)
    example.run
  ensure
    old_tmp.nil? ? ENV.delete("NIL_KILL_TMP_DIR") : ENV["NIL_KILL_TMP_DIR"] = old_tmp
    reset_nil_kill_tmp_paths!(old_tmp || File.join(nil_kill_root, "tmp", "nil-kill-spec", Process.pid.to_s))
  end
end

Dir[File.join(__dir__, "support", "*.rb")].sort.each { |f| require f }
