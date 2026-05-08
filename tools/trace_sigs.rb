# typed: false
# frozen_string_literal: true
#
# Runtime-trace observer for sig autogeneration.
#
# Activated by setting TRACE_SIGS=1 before loading. Hooks
# TracePoint(:end) so that whenever a class/module body defined under
# `src/` finishes, every instance + singleton method on it is wrapped
# via Module#prepend. The wrapper records (arg classes, kwarg classes,
# return class) for every call, then `at_exit` dumps observations as
# JSONL to tmp/sig_obs/obs-<pid>.jsonl.
#
# Usage:
#   RUBYOPT="-r$(pwd)/tools/trace_sigs" bundle exec prspec spec/
#   RUBYOPT="-r$(pwd)/tools/trace_sigs" ./clear test transpile-tests/
#   RUBYOPT="-r$(pwd)/tools/trace_sigs" ruby benchmarks/runner.rb --leak
#
# Then aggregate + emit sigs:
#   bundle exec ruby tools/gen_sigs_from_trace.rb
#
# Cost: ~10-20% slowdown on the corpus. Don't enable in CI.
#
# Known gaps:
# - Methods added after class :end fires (lazy `define_method` in
#   `included` callbacks) are missed. Most src/ code defines methods
#   at class body load time, so this is a small gap.
# - Default-arg values pollute observations (caller didn't pass that
#   class, the default did). Mitigated by trimming params to
#   args.length when method has optionals.

require "set"
require "fileutils"
# json is deferred to dump-time. Requiring it before bundler/setup runs
# activates the stdlib version and clashes with the Gemfile-locked json
# gem when src/backends/transpiler.rb runs `require "bundler/setup"`.

module SigTracer
  SRC_DIR = File.expand_path(File.join(__dir__, "..", "src"))
  OUT_DIR = File.expand_path(File.join(__dir__, "..", "tmp", "sig_obs"))

  @records = {}
  @wrapped = Set.new
  @lock = Mutex.new

  class << self
    attr_reader :records, :lock
  end

  def self.bucket(klass_name, method_name, kind)
    key = [klass_name, method_name.to_s, kind]
    @lock.synchronize do
      @records[key] ||= {
        calls: 0,
        params: [],
        kw: {},
        returns: Set.new,
        raised: Set.new,
        block_given_count: 0,
      }
    end
  end

  def self.record_call(klass_name, method_name, kind, args, kwargs, block_given, result, raised)
    b = bucket(klass_name, method_name, kind)
    @lock.synchronize do
      b[:calls] += 1
      b[:block_given_count] += 1 if block_given
      args.each_with_index do |a, i|
        b[:params][i] ||= Set.new
        b[:params][i] << a.class.name.to_s
      end
      kwargs.each do |k, v|
        b[:kw][k] ||= Set.new
        b[:kw][k] << v.class.name.to_s
      end
      if raised
        b[:raised] << raised.class.name.to_s
      else
        b[:returns] << (result.nil? ? "NilClass" : result.class.name.to_s)
      end
    end
  end

  # Build a Module that prepends instance-method wrappers for `methods`.
  def self.build_instance_tracer(klass_name, methods)
    mod = Module.new
    methods.each do |m|
      mod.module_eval do
        define_method(m) do |*args, **kwargs, &blk|
          raised = nil
          result = nil
          begin
            result = super(*args, **kwargs, &blk)
          rescue Exception => e
            raised = e
            raise
          ensure
            SigTracer.record_call(klass_name, m, :instance, args, kwargs, !blk.nil?, result, raised)
          end
          result
        end
      end
    end
    mod
  end

  def self.build_singleton_tracer(klass_name, methods)
    mod = Module.new
    methods.each do |m|
      mod.module_eval do
        define_method(m) do |*args, **kwargs, &blk|
          raised = nil
          result = nil
          begin
            result = super(*args, **kwargs, &blk)
          rescue Exception => e
            raised = e
            raise
          ensure
            SigTracer.record_call(klass_name, m, :class, args, kwargs, !blk.nil?, result, raised)
          end
          result
        end
      end
    end
    mod
  end

  def self.wrap_all(klass)
    return unless klass.is_a?(Module)
    name = klass.name
    return unless name # skip anonymous

    new_imethods = nil
    new_smethods = nil
    @lock.synchronize do
      new_imethods = klass.instance_methods(false).reject do |m|
        @wrapped.include?([name, m.to_s, :instance])
      end
      new_imethods.each { |m| @wrapped << [name, m.to_s, :instance] }

      new_smethods = klass.singleton_methods(false).reject do |m|
        @wrapped.include?([name, m.to_s, :class])
      end
      new_smethods.each { |m| @wrapped << [name, m.to_s, :class] }
    end

    return if new_imethods.empty? && new_smethods.empty?

    if !new_imethods.empty?
      tracer = build_instance_tracer(name, new_imethods)
      begin
        klass.prepend(tracer)
      rescue StandardError, FrozenError
        # Some metaclasses can't be prepended (e.g. frozen). Skip.
      end
    end

    return if new_smethods.empty?

    s_tracer = build_singleton_tracer(name, new_smethods)
    begin
      klass.singleton_class.prepend(s_tracer)
    rescue StandardError, FrozenError
      # Skip.
    end
  end

  def self.dump
    require "json"
    FileUtils.mkdir_p(OUT_DIR)
    path = File.join(OUT_DIR, "obs-#{Process.pid}.jsonl")
    File.open(path, "w") do |f|
      @records.each do |key, b|
        f.puts JSON.generate(
          klass: key[0],
          method: key[1],
          kind: key[2],
          calls: b[:calls],
          block_given_count: b[:block_given_count],
          params: b[:params].map { |s| (s&.to_a || []).sort },
          kw: b[:kw].transform_values { |s| s.to_a.sort },
          returns: b[:returns].to_a.sort,
          raised: b[:raised].to_a.sort,
        )
      end
    end
  end

  TRACE = TracePoint.new(:end) do |tp|
    next unless tp.path.start_with?(SRC_DIR)
    wrap_all(tp.self)
  end
end

if ENV["TRACE_SIGS"] == "1"
  SigTracer::TRACE.enable
  at_exit { SigTracer.dump }
end
