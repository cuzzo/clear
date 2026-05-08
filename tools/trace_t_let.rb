# typed: false
# frozen_string_literal: true
#
# Companion tracer that hooks T.let calls and records (file, line,
# value-class) for every invocation. Activated alongside trace_sigs.rb
# via the same TRACE_SIGS=1 / RUBYOPT mechanism.
#
# T.let is a method on `T` (sorbet-runtime) that returns its first
# argument unchanged after asserting the type. We replace it with a
# wrapper that records the value's class then calls the original.
#
# The output JSONL has one record per (file, line) pair, with a
# `classes:` set of all observed value classes plus `calls:`.
#
# Usage: same activation as trace_sigs.rb.

require "set"
require "fileutils"

module TLetTracer
  SRC_DIR = File.expand_path(File.join(__dir__, "..", "src"))
  OUT_DIR = File.expand_path(File.join(__dir__, "..", "tmp", "sig_obs_tlet"))

  @records = {}  # [path, line] => { calls:, classes: }
  @lock = Mutex.new

  class << self
    attr_reader :records, :lock
  end

  def self.class_name_of(obj)
    return "NilClass" if obj.nil?
    cls = obj.class rescue nil
    return "T.untyped" unless cls
    cls.name || "T.untyped"
  end

  def self.record(path, line, value)
    return unless path&.start_with?(SRC_DIR)
    key = [path, line]
    @lock.synchronize do
      r = (@records[key] ||= { calls: 0, classes: Set.new })
      r[:calls] += 1
      r[:classes] << class_name_of(value)
    end
  end

  def self.dump
    require "json"
    FileUtils.mkdir_p(OUT_DIR)
    path = File.join(OUT_DIR, "tlet-#{Process.pid}.jsonl")
    File.open(path, "w") do |f|
      @records.each do |(p, ln), r|
        f.puts JSON.generate(path: p, line: ln, calls: r[:calls], classes: r[:classes].to_a.sort)
      end
    end
  end
end

if ENV["TRACE_SIGS"] == "1"
  # Wait for sorbet-runtime to load (Bundler/setup runs first), then
  # hook T.let.
  begin
    require "sorbet-runtime"
  rescue LoadError
    # Will be loaded later by user code; the hook below installs once
    # the constant is available. We use TracePoint(:end) on T.
  end

  install_hook = lambda do
    return unless defined?(T) && T.respond_to?(:let)
    return if T.singleton_class.method_defined?(:__orig_let)
    T.singleton_class.alias_method(:__orig_let, :let)
    T.singleton_class.define_method(:let) do |value, type, **kw|
      # Determine caller location.
      caller_loc = caller_locations(1, 1)&.first
      if caller_loc
        TLetTracer.record(caller_loc.absolute_path || caller_loc.path, caller_loc.lineno, value)
      end
      T.send(:__orig_let, value, type, **kw)
    end
  end

  install_hook.call
  unless defined?(T) && T.respond_to?(:let)
    # Re-try installation when sorbet-runtime loads.
    TracePoint.new(:end) do |tp|
      install_hook.call
    end.enable
  end

  at_exit { TLetTracer.dump }
end
