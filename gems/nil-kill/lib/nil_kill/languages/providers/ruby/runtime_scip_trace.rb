# frozen_string_literal: true

# Ruby TracePoint support for the language-neutral NilKill runtime_call event.
# This file is loaded by the legacy Ruby tracer without loading the full
# NilKill command stack.
module NilKillRuntimeTrace
  @runtime_calls = {}
  @runtime_package_by_path = {}
  @runtime_scip_frames = Hash.new { |hash, thread_id| hash[thread_id] = [] }

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
    record_runtime_scip_call(tp)
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
    }
  end

  def self.leave_runtime_scip_ruby_call
    @runtime_scip_frames[Thread.current.object_id].pop
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
        count: 0,
      })
      record[:count] += 1
    end
  rescue StandardError
    # Tracing is observational and must never alter application behavior.
    # Unavailable metadata is omitted instead of escaping into user code.
    nil
  ensure
    Thread.current[:__nil_kill_runtime_scip] = nil
  end

  def self.install_runtime_scip_trace
    TracePoint.new(:line, :call, :return, :c_call) do |trace|
      case trace.event
      when :line
        record_runtime_scip_line(trace)
      when :call
        enter_runtime_scip_ruby_call(trace)
      when :return
        leave_runtime_scip_ruby_call
      when :c_call
        record_runtime_scip_call(trace)
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
