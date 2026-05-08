# typed: false
# frozen_string_literal: true
#
# Runtime-trace observer for sig autogeneration.
#
# Activated by setting TRACE_SIGS=1 before loading. Hooks
# TracePoint(:call) on every method invocation, then reads each
# parameter's actual bound value via tp.binding.local_variable_get(name).
# This sees param values AFTER defaults have been applied (so optional
# params with `param = nil` defaults correctly show NilClass when
# callers omit them — caller-side `*args` capture would miss this).
#
# A paired :return TracePoint records the return type.
#
# Filtered to methods defined under src/ via tp.path.start_with?(SRC_DIR).
#
# Usage:
#   RUBYOPT="-r$(pwd)/tools/trace_sigs" bundle exec prspec spec/
#   RUBYOPT="-r$(pwd)/tools/trace_sigs" ./clear test transpile-tests/
#   RUBYOPT="-r$(pwd)/tools/trace_sigs" ruby benchmarks/runner.rb --leak
#
# Then aggregate + emit sigs:
#   bundle exec ruby tools/gen_sigs_from_trace.rb
#
# Cost: ~30-50% slowdown on the corpus (TracePoint(:call) fires every
# method call in src/). Don't enable in CI.

require "set"
require "fileutils"
# json is deferred to dump-time. Requiring it before bundler/setup runs
# activates the stdlib version and clashes with the Gemfile-locked json
# gem when src/backends/transpiler.rb runs `require "bundler/setup"`.

module SigTracer
  SRC_DIR = File.expand_path(File.join(__dir__, "..", "src"))
  OUT_DIR = File.expand_path(File.join(__dir__, "..", "tmp", "sig_obs"))

  @records = {}
  @lock = Mutex.new
  # Threads in `b_call` need a stack to pair with `b_return`.
  # Keyed by Thread.current.object_id. We don't need the values for now
  # but keeping the structure makes future :raise tracking trivial.

  class << self
    attr_reader :records, :lock
  end

  def self.bucket(klass_name, method_name, kind)
    key = [klass_name, method_name.to_s, kind]
    @lock.synchronize do
      @records[key] ||= {
        calls: 0,
        params: {},  # name => Set of class names (param value types)
        param_elem: {},  # name => Set of class names (Array/Set element types)
        param_kv:   {},  # name => [Set keys, Set values] (Hash key/value types)
        param_order: [], # Array of param names in defined order
        returns: Set.new,
        return_elem: Set.new,         # Array/Set element types of returns
        return_kv:   [Set.new, Set.new], # Hash [keys, values] of returns
        raised: Set.new,
        block_given_count: 0,
      }
    end
  end

  # Class name for any object (handles BasicObject and weird singleton
  # classes that don't return a Class from `.class`).
  def self.class_name_of(obj)
    return "NilClass" if obj.nil?
    cls = obj.class rescue nil
    return "T.untyped" unless cls
    cls.name || "T.untyped"
  end

  # If value is an Array/Set, return up to N element classes. If it's
  # a Hash, return [key_classes, value_classes]. Else nil.
  ELEMENT_SAMPLE = 20
  def self.element_classes(value)
    case value
    when Array
      seen = Set.new
      value.each_with_index do |e, i|
        break if i >= ELEMENT_SAMPLE
        seen << class_name_of(e)
      end
      [:elem, seen]
    when Hash
      keys = Set.new
      vals = Set.new
      i = 0
      value.each do |k, v|
        break if i >= ELEMENT_SAMPLE
        keys << class_name_of(k)
        vals << class_name_of(v)
        i += 1
      end
      [:hash, [keys, vals]]
    when Set
      seen = Set.new
      value.each_with_index do |e, i|
        break if i >= ELEMENT_SAMPLE
        seen << class_name_of(e)
      end
      [:elem, seen]
    else
      nil
    end
  end

  # Determine the (klass, kind) tuple for a TracePoint(:call) event.
  # Returns nil to skip (e.g. anonymous classes, methods defined on
  # singleton classes we can't name cleanly).
  def self.identify_method(tp)
    defined_class = tp.defined_class
    return nil unless defined_class

    # `defined_class` for a singleton method is the singleton class.
    # We want to record `kind: :class` and the name of the underlying
    # class. Detect singletons via `singleton_class?` (Ruby 2.0+).
    if defined_class.respond_to?(:singleton_class?) && defined_class.singleton_class?
      target = singleton_target(defined_class)
      return nil unless target.is_a?(Module)
      return [target.name, :class] if target.name
      nil
    else
      [defined_class.name, :instance]
    end
  end

  # Recover the class/module that owns a singleton class.
  # `obj.singleton_class.attached_object` is the cleanest path on
  # Ruby >= 3.2; fall back to inspecting `tp.self` for older runtimes.
  def self.singleton_target(sclass)
    if sclass.respond_to?(:attached_object)
      sclass.attached_object rescue nil
    end
  end

  def self.record_call(tp)
    info = identify_method(tp)
    return unless info
    klass_name, kind = info
    return unless klass_name # anonymous classes can return nil

    method_name = tp.method_id

    # Resolve the def's parameter list from the actual method object.
    # tp.parameters works in modern Ruby and is the canonical source.
    params = tp.parameters rescue nil
    return unless params

    b = bucket(klass_name, method_name, kind)

    bnd = tp.binding
    @lock.synchronize do
      b[:calls] += 1
      param_names = []
      params.each do |kind_sym, pname|
        next unless pname
        next if %i[rest keyrest block].include?(kind_sym)
        param_names << pname.to_s
        value = bnd.local_variable_get(pname) rescue nil
        cls_name = class_name_of(value)
        b[:params][pname.to_s] ||= Set.new
        b[:params][pname.to_s] << cls_name

        # Container element-type sampling. Cheap enough to do
        # unconditionally — only fires Array/Set/Hash.each on the
        # actual value, capped at ELEMENT_SAMPLE.
        ec = element_classes(value)
        if ec
          tag, data = ec
          if tag == :elem
            b[:param_elem][pname.to_s] ||= Set.new
            b[:param_elem][pname.to_s].merge(data)
          else
            kset, vset = (b[:param_kv][pname.to_s] ||= [Set.new, Set.new])
            kset.merge(data[0])
            vset.merge(data[1])
          end
        end
      end
      b[:param_order] = param_names if b[:param_order].empty?
    end
  end

  def self.record_return(tp)
    info = identify_method(tp)
    return unless info
    klass_name, kind = info
    return unless klass_name

    method_name = tp.method_id
    return_value = tp.return_value
    cls_name = class_name_of(return_value)

    b = bucket(klass_name, method_name, kind)
    @lock.synchronize do
      b[:returns] << cls_name

      ec = element_classes(return_value)
      if ec
        tag, data = ec
        if tag == :elem
          b[:return_elem].merge(data)
        else
          b[:return_kv][0].merge(data[0])
          b[:return_kv][1].merge(data[1])
        end
      end
    end
  end

  def self.record_raise(tp)
    info = identify_method(tp)
    return unless info
    klass_name, kind = info
    return unless klass_name

    method_name = tp.method_id
    raised = tp.raised_exception
    cls_name = class_name_of(raised)

    b = bucket(klass_name, method_name, kind)
    @lock.synchronize do
      b[:raised] << cls_name
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
          params_by_name: b[:params].transform_values { |s| s.to_a.sort },
          # Container element types per param. For Array/Set values,
          # `param_elem[name]` is the union of element classes seen.
          # For Hash values, `param_kv[name]` is [keys, values].
          param_elem: b[:param_elem].transform_values { |s| s.to_a.sort },
          param_kv:   b[:param_kv].transform_values { |kv| [kv[0].to_a.sort, kv[1].to_a.sort] },
          param_order: b[:param_order],
          returns: b[:returns].to_a.sort,
          return_elem: b[:return_elem].to_a.sort,
          return_kv:   [b[:return_kv][0].to_a.sort, b[:return_kv][1].to_a.sort],
          raised: b[:raised].to_a.sort,
        )
      end
    end
  end

  CALL_TRACE = TracePoint.new(:call) do |tp|
    next unless tp.path.start_with?(SRC_DIR)
    record_call(tp)
  end

  RETURN_TRACE = TracePoint.new(:return) do |tp|
    next unless tp.path.start_with?(SRC_DIR)
    record_return(tp)
  end

  RAISE_TRACE = TracePoint.new(:raise) do |tp|
    next unless tp.path.start_with?(SRC_DIR)
    record_raise(tp)
  end
end

if ENV["TRACE_SIGS"] == "1"
  SigTracer::CALL_TRACE.enable
  SigTracer::RETURN_TRACE.enable
  SigTracer::RAISE_TRACE.enable
  at_exit { SigTracer.dump }
end
