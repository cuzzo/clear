# frozen_string_literal: true

# Ruby TracePoint support for the language-neutral NilKill runtime_call event.
# This file is loaded by the legacy Ruby tracer without loading the full
# NilKill command stack.
module NilKillRuntimeTrace
  @runtime_calls = {}
  @runtime_package_by_path = {}

  def self.runtime_callsite(skip_first_target: false)
    skipped_target = false
    Thread.each_caller_location do |location|
      raw = location.absolute_path || location.path
      next unless raw

      path = abs_path(raw)
      next if path == SELF_ABS || !target_path?(path)
      if skip_first_target && !skipped_target
        skipped_target = true
        next
      end

      return { path: path, line: location.lineno }
    end
    nil
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

    Thread.current[:__nil_kill_runtime_scip] = true
    owner = method_owner(tp.defined_class)
    return unless owner

    native = tp.event == :c_call
    callsite = runtime_callsite(skip_first_target: !native)
    return unless callsite

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
      line: native ? nil : tp.lineno,
      native: native,
      receiver_type: class_name(tp.self),
    }.merge(package)

    @lock.synchronize do
      stack = @frames[Thread.current.object_id]
      frame = stack.last
      if frame && !native && frame[:method_key] &&
          frame[:method_key][0] == owner[0] &&
          frame[:method_key][1] == tp.method_id.to_s &&
          frame[:method_key][3] == callee_path
        frame = stack[-2]
      end
      return unless frame && frame[:method_key]

      caller = method_key_payload(frame[:method_key])
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
  ensure
    Thread.current[:__nil_kill_runtime_scip] = nil
  end

  def self.install_runtime_scip_trace
    TracePoint.new(:call, :c_call) { |trace| record_runtime_scip_call(trace) }.enable
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
