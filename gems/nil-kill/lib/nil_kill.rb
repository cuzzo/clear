#!/usr/bin/env ruby
# typed: false
# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "pathname"
require "set"
require "shellwords"
require "time"

begin
  require "prism"
rescue LoadError
  warn "error: prism is required; run `bundle install`"
  exit 2
end

module NilKill
  ROOT = File.expand_path("../../..", __dir__)
  TMP_DIR = File.expand_path(ENV.fetch("NIL_KILL_TMP_DIR", File.join(ROOT, "tmp", "nil-kill")), ROOT)
  RUNTIME_DIR = File.join(TMP_DIR, "runtime")
  INSTRUMENTED_DIR = File.join(TMP_DIR, "instrumented")
  EVIDENCE_PATH = File.join(TMP_DIR, "evidence.json")
  REPORT_PATH = File.join(TMP_DIR, "report.md")
  TRACE_PLAN_PATH = File.join(TMP_DIR, "trace-plan.json")
  SORBET_PAYLOAD_DIR = File.join(TMP_DIR, "sorbet-payload")
end

require_relative "nil_kill/util"
require_relative "nil_kill/spec_dependency_index"
require_relative "nil_kill/hash_shape_ops"
require_relative "nil_kill/rbi_return_index"
require_relative "nil_kill/store"
require_relative "nil_kill/fallibility_pressure"
require_relative "nil_kill/flow_graph"
require_relative "nil_kill/trace_plan"
require_relative "nil_kill/infer"
require_relative "nil_kill/source_index"
require_relative "nil_kill/slot_coverage"
require_relative "nil_kill/espalier_evidence"
require_relative "nil_kill/static_diff_audit"
require_relative "nil_kill/source_instrumenter"
require_relative "nil_kill/focus_hash_record"
require_relative "nil_kill/apply"
require_relative "nil_kill/interactive_review"
require_relative "nil_kill/loop"
require_relative "nil_kill/report"
require_relative "nil_kill/struct_rbi"
require_relative "nil_kill/guarded_autocorrect"
require_relative "nil_kill/doctor"
require_relative "nil_kill/cli"

NilKill::CLI.new(ARGV).run if $PROGRAM_NAME == __FILE__
