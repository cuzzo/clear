# frozen_string_literal: true

# Ruby TracePoint support for the language-neutral NilKill runtime_call event.
# This file is loaded by the legacy Ruby tracer without loading the full
# NilKill command stack.
module NilKillRuntimeTrace
  @runtime_calls = {}
  @runtime_package_by_path = {}
  @runtime_scip_frames = Hash.new { |hash, thread_id| hash[thread_id] = [] }
  @runtime_scip_native_calls = Hash.new { |hash, thread_id| hash[thread_id] = [] }

  class << self
    attr_reader :runtime_calls, :runtime_scip_frames, :runtime_scip_native_calls
  end

  def self.record_runtime_scip_line(tp)
    path = abs_path(tp.path)
    return unless target_path?(path)

    frame = @runtime_scip_frames[Thread.current.object_id].last
    return unless frame

    frame[:callsite] = {
      path: path,
      line: src_line(path, tp.lineno),
    }
  end

  def self.enter_runtime_scip_ruby_call(tp)
    observed_call = record_runtime_scip_call(tp)
    owner = method_owner(tp.defined_class)
    path = abs_path(tp.path)
    @runtime_scip_frames[Thread.current.object_id] << {
      caller: owner && {
        class: owner[0],
        method: tp.method_id.to_s,
        kind: owner[1],
        path: path,
        line: src_line(path, tp.lineno),
      },
      callsite: nil,
      observed_call: observed_call,
    }
  end

  def self.leave_runtime_scip_ruby_call(tp)
    frame = @runtime_scip_frames[Thread.current.object_id].pop
    record_runtime_scip_result(frame&.fetch(:observed_call, nil), tp.return_value)
  end

  def self.enter_runtime_scip_native_call(tp)
    observed_call = record_runtime_scip_call(tp)
    @runtime_scip_native_calls[Thread.current.object_id] << observed_call
  end

  def self.leave_runtime_scip_native_call(tp)
    observed_call = @runtime_scip_native_calls[Thread.current.object_id].pop
    record_runtime_scip_result(observed_call, tp.return_value)
  end

  def self.runtime_package(path, native:)
    return {
      package_manager: "ruby",
      package: "ruby",
      version: RUBY_VERSION,
    } if native

    absolute = path.to_s.empty? ? nil : abs_path(path)
    return @runtime_package_by_path[absolute] if absolute && @runtime_package_by_path.key?(absolute)

    package =
      if absolute && target_path?(absolute)
        {
          package_manager: "workspace",
          package: ENV.fetch("NIL_KILL_PROJECT_NAME", File.basename(ROOT)),
          version: ENV.fetch("NIL_KILL_PROJECT_VERSION", "workspace"),
        }
      elsif absolute
        spec = Gem.loaded_specs.values.find do |candidate|
          root = File.expand_path(candidate.full_gem_path)
          absolute == root || absolute.start_with?("#{root}#{File::SEPARATOR}")
        end
        if spec
          {
            package_manager: "rubygems",
            package: spec.name,
            version: spec.version.to_s,
          }
        else
          {
            package_manager: "ruby",
            package: "ruby",
            version: RUBY_VERSION,
          }
        end
      else
        {
          package_manager: "ruby",
          package: "ruby",
          version: RUBY_VERSION,
        }
      end
    @runtime_package_by_path[absolute] = package if absolute
    package
  end

  def self.record_runtime_scip_call(tp)
    return if Thread.current[:__nil_kill_runtime_scip] ||
      Thread.current[:__nil_kill_collection_hook]
    # Existing NilKill recorders also use this mutex. Metadata discovery may
    # execute instrumented Ruby (or raise through an instrumented rescue path),
    # so never enter this recorder while the current thread owns that lock.
    return if @lock.respond_to?(:owned?) && @lock.owned?

    Thread.current[:__nil_kill_runtime_scip] = true
    owner = method_owner(tp.defined_class)
    return unless owner
    return if owner[0] == "NilKillRuntimeTrace"

    native = tp.event == :c_call
    frame = @runtime_scip_frames[Thread.current.object_id].last
    return unless frame
    caller = frame[:caller]
    callsite = frame[:callsite]
    return unless caller && callsite

    callee_path = native ? nil : abs_path(tp.path)
    package = runtime_package(callee_path, native: native)
    # Sorbet installs validation wrappers under the application's declared
    # owner. TracePoint reports both that wrapper and the underlying method;
    # the wrapper is an implementation detail, not a source-level call target.
    return if package[:package] == "sorbet-runtime" &&
      !owner[0].to_s.start_with?("T::")

    callee = {
      owner: owner[0],
      name: tp.method_id.to_s,
      kind: owner[1],
      path: callee_path,
      line: native ? nil : src_line(callee_path, tp.lineno),
      native: native,
      receiver_type: class_name(tp.self),
    }.merge(package)
    receiver_domain = runtime_value_domain(tp.self)

    @lock.synchronize do
      key = [
        caller[:class], caller[:method], caller[:kind], caller[:path], caller[:line],
        callsite[:path], callsite[:line],
        callee[:owner], callee[:name], callee[:kind], callee[:path], callee[:line],
        callee[:native], callee[:package_manager], callee[:package], callee[:version],
      ]
      record = (@runtime_calls[key] ||= {
        schema_version: 1,
        event: "runtime_call",
        language: "ruby",
        run_id: ENV.fetch("NIL_KILL_RUN_ID", ""),
        caller: caller,
        callsite: callsite,
        callee: callee,
        receiver_domain: receiver_domain,
        count: 0,
      })
      merge_runtime_value_domain!(record[:receiver_domain], receiver_domain)
      record[:count] += 1
      key
    end
  rescue StandardError
    # Tracing is observational and must never alter application behavior.
    # Unavailable metadata is omitted instead of escaping into user code.
    nil
  ensure
    Thread.current[:__nil_kill_runtime_scip] = nil
  end

  def self.record_runtime_scip_result(key, value)
    return unless key
    return if Thread.current[:__nil_kill_runtime_scip]

    Thread.current[:__nil_kill_runtime_scip] = true
    observed = runtime_value_domain(value)
    @lock.synchronize do
      record = @runtime_calls[key]
      merge_runtime_value_domain!(record[:result_domain] ||= empty_runtime_value_domain, observed) if record
    end
  rescue StandardError
    nil
  ensure
    Thread.current[:__nil_kill_runtime_scip] = nil
  end

  def self.empty_runtime_value_domain
    {
      types: [],
      elements: [],
      keys: [],
      values: [],
      shapes: [],
    }
  end

  def self.runtime_value_domain(value)
    domain = empty_runtime_value_domain
    domain[:types] << class_name(value)
    shape = container_shape(value)
    if shape
      if shape[0] == :array
        domain[:elements].concat(shape[1].to_a)
      else
        domain[:keys].concat(shape[1][0].to_a)
        domain[:values].concat(shape[1][1].to_a)
      end
      domain[:shapes] << shape_payload(collection_type_shape_key(value))
    end
    %i[types elements keys values].each { |field| domain[field].sort! }
    domain[:shapes].sort_by! { |value_shape| JSON.generate(value_shape) }
    domain
  end

  def self.merge_runtime_value_domain!(target, source)
    source.each do |field, values|
      target[field] = (Array(target[field]) | Array(values)).sort_by do |item|
        item.is_a?(Hash) ? JSON.generate(item) : item.to_s
      end
    end
    target
  end

  def self.install_runtime_scip_trace
    TracePoint.new(:line, :call, :return, :c_call, :c_return) do |trace|
      case trace.event
      when :line
        record_runtime_scip_line(trace)
      when :call
        enter_runtime_scip_ruby_call(trace)
      when :return
        leave_runtime_scip_ruby_call(trace)
      when :c_call
        enter_runtime_scip_native_call(trace)
      when :c_return
        leave_runtime_scip_native_call(trace)
      end
    end.enable
  end

  def self.dump_runtime_scip_calls(pid)
    File.open(File.join(OUT_DIR, "runtime-calls-#{pid}.jsonl"), "w") do |file|
      @runtime_calls.values.sort_by do |record|
        caller = record.fetch(:caller)
        callsite = record.fetch(:callsite)
        callee = record.fetch(:callee)
        [
          callsite.fetch(:path), callsite.fetch(:line),
          caller.fetch(:class), caller.fetch(:method),
          callee.fetch(:owner), callee.fetch(:name),
        ]
      end.each { |record| file.puts JSON.generate(record) }
    end
  end
end
