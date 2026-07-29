# frozen_string_literal: true

# Ruby TracePoint support for the language-neutral NilKill runtime_call event.
# This file is loaded by the legacy Ruby tracer without loading the full
# NilKill command stack.
module NilKillRuntimeTrace
  @runtime_calls = {}
  @runtime_package_by_path = {}
  @runtime_scip_frames = Hash.new { |hash, thread_id| hash[thread_id] = [] }
  @runtime_scip_native_calls = Hash.new { |hash, thread_id| hash[thread_id] = [] }
  @runtime_scip_native_result_depth = 0
  RUNTIME_SCIP_SOURCE_SLICE = ENV.fetch("NIL_KILL_TRACE_SOURCE_SLICE", "")
    .split(File::PATH_SEPARATOR)
    .reject(&:empty?)
    .map { |path| File.expand_path(path) }
    .to_set

  class << self
    attr_reader :runtime_calls, :runtime_scip_frames, :runtime_scip_native_calls
  end

  def self.record_runtime_scip_line(tp)
    path = abs_path(tp.path)
    return unless target_path?(path)

    # A prior line can arm result capture without executing a native call.
    # Its window ends at the next Ruby line event, unless a native call is
    # still suspended across a yielding callback.
    if @runtime_scip_native_result_armed && !@runtime_scip_native_result_depth.to_i.positive?
      @runtime_scip_native_result_armed = false
      runtime_scip_native_result_trace.disable
    end

    frame = @runtime_scip_frames[Thread.current.object_id].last
    return unless frame

    frame[:callsite] = {
      path: path,
      line: src_line(path, tp.lineno),
    }
    _capture_call, capture_result, _receiver_shape = runtime_scip_captures_for(frame[:callsite])
    return unless capture_result && runtime_scip_native_calls_enabled?

    # Enable c_return before the requested c_call starts. Enabling it from
    # inside c_call can expose a VM housekeeping return that has no matching
    # c_call frame, corrupting the requested result.
    @runtime_scip_native_result_armed = true
    runtime_scip_native_result_trace.enable
  end

  def self.enter_runtime_scip_ruby_call(tp)
    parent = @runtime_scip_frames[Thread.current.object_id].last
    fallback_callsite = parent&.fetch(:callsite, nil)
    # A Ruby :line event is emitted for the outer expression of a multiline
    # literal/call, not necessarily for a nested Ruby call inside it.  The
    # demand-driven trace plan is keyed by the nested call's real source line,
    # so treating that stale outer line as authoritative silently drops an
    # observation FactMine explicitly requested.  Avoid the comparatively
    # expensive stack lookup on the usual planned path; recover the caller
    # location only when the current line has no requested capture.
    callsite = if runtime_scip_captures_for(fallback_callsite).any?
                 fallback_callsite
               else
                 runtime_scip_ruby_callsite(tp, fallback_callsite)
               end
    capture_call, capture_result, receiver_shape = runtime_scip_captures_for(callsite)
    observed_call = if capture_call || capture_result || receiver_shape
                      record_runtime_scip_call(
                        tp,
                        receiver_shape: receiver_shape,
                        deduplicate: !capture_result && !receiver_shape,
                      )
                    end
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
      capture_result: capture_result && !observed_call.nil?,
    }
  end

  def self.leave_runtime_scip_ruby_call(tp)
    frame = @runtime_scip_frames[Thread.current.object_id].pop
    return unless frame&.fetch(:capture_result, false)

    record_runtime_scip_result(frame[:observed_call], tp.return_value)
  end

  def self.enter_runtime_scip_native_call(tp)
    frame = @runtime_scip_frames[Thread.current.object_id].last
    callsite = runtime_scip_native_callsite(tp, frame&.fetch(:callsite, nil))
    capture_call, capture_result, receiver_shape = runtime_scip_captures_for(callsite)
    observed_call = if capture_call || capture_result || receiver_shape
                      record_runtime_scip_call(
                        tp,
                        receiver_shape: receiver_shape,
                        deduplicate: !capture_result && !receiver_shape,
                        callsite: callsite,
                      )
                    end
    capture_result &&= !observed_call.nil?

    # c_return is overwhelmingly the hottest TracePoint event. Enable it only
    # while an exact FactMine demand is in flight; retain sentinels for nested
    # native calls so return pairing remains correct while it is enabled.
    if capture_result || @runtime_scip_native_result_depth.to_i.positive?
      @runtime_scip_native_calls[Thread.current.object_id] << {
        observed_call: observed_call,
        capture_result: capture_result,
        defined_class: tp.defined_class,
        method_id: tp.method_id,
      }
    end
    return unless capture_result

    @runtime_scip_native_result_depth = @runtime_scip_native_result_depth.to_i + 1
    # Keep a line-armed trace alive until the next line event. That covers
    # multiple requested native calls on one source line without re-enabling
    # c_return from inside a later c_call.
    unless @runtime_scip_native_result_armed
      runtime_scip_native_result_trace.enable
    end
  end

  def self.leave_runtime_scip_native_call(tp)
    frames = @runtime_scip_native_calls[Thread.current.object_id]
    frame = frames.pop
    return unless frame
    # Enabling a c_return TracePoint from inside a c_call callback can expose
    # an in-flight VM housekeeping return for which no c_call frame was
    # observed. Never pair that return with the demand we just armed: doing so
    # would assign a nested value to an unrelated source call. A mismatch is
    # discarded rather than retained: losing one optional observation is safe,
    # while retaining it can leave c_return tracing enabled process-wide.
    matched = frame[:method_id] == tp.method_id && frame[:defined_class].equal?(tp.defined_class)

    record_runtime_scip_result(frame[:observed_call], tp.return_value) if matched && frame[:capture_result]
    return unless frame[:capture_result]

    @runtime_scip_native_result_depth -= 1
    if !@runtime_scip_native_result_depth.positive? && !@runtime_scip_native_result_armed
      runtime_scip_native_result_trace.disable
    end
  end

  def self.runtime_scip_native_result_trace
    @runtime_scip_native_result_trace ||= TracePoint.new(:c_return) do |trace|
      leave_runtime_scip_native_call(trace)
    end
  end

  # Ruby can evaluate multiple entries of a multiline literal after one
  # `:line` event. For a native call TracePoint's own path/line is the exact
  # caller anchor; the frame anchor is only a fallback for VM/internal paths.
  # Keeping this resolution in the Ruby tracer makes FactMine's generic trace
  # plan precise without reimplementing any source analysis here.
  def self.runtime_scip_native_callsite(tp, fallback)
    path = abs_path(tp.path)
    return fallback unless target_path?(path)

    { path: path, line: src_line(path, tp.lineno) }
  rescue StandardError
    fallback
  end

  # For a :call TracePoint, tp.path/tp.lineno identify the callee's
  # declaration, not the caller expression.  The callback stack is stable:
  # this TracePoint handler, the callee frame, then the source caller.  Use
  # that third frame only as a precision fallback (see
  # enter_runtime_scip_ruby_call), and reject locations outside the selected
  # production target just as the native-call path does.
  def self.runtime_scip_ruby_callsite(tp, fallback)
    # Stack layout includes this helper, enter_runtime_scip_ruby_call, and
    # the TracePoint callback before the callee frame. Locate that callee by
    # TracePoint's declaration location instead of relying on a fixed depth;
    # recursion and wrappers otherwise make a positional lookup fragile.
    callee_path = abs_path(tp.path)
    locations = caller_locations(2, 16)
    callee_index = locations.index do |candidate|
      abs_path(candidate.absolute_path || candidate.path) == callee_path &&
        candidate.lineno == tp.lineno
    end
    location = callee_index && locations[callee_index + 1]
    return fallback unless location

    path = abs_path(location.absolute_path || location.path)
    return fallback unless target_path?(path)

    { path: path, line: src_line(path, location.lineno) }
  rescue StandardError
    fallback
  end

  # Ruby-level call tracing remains useful for project and gem dispatch while
  # this switch gives the feedback loop an explicit, measurable fast tier.
  # A full collect keeps native calls enabled by default; callers that only
  # need to validate a FactMine/NilKill join can opt out of the expensive VM
  # C-call events without changing any source-language analysis.
  def self.runtime_scip_native_calls_enabled?
    ENV.fetch("NIL_KILL_RUNTIME_SCIP_NATIVE", "1") != "0"
  end

  def self.runtime_package(path, native:)
    return {
      package_manager: "ruby",
      package: "ruby",
      version: RUBY_VERSION,
    } if native

    # TracePoint uses pseudo-paths such as `<internal:warning>` for Ruby-core
    # implementations written outside the workspace. `File.expand_path`
    # would turn those into a relative path under ROOT and incorrectly label
    # `Kernel#warn` (and peers) as project code. They have no workspace source
    # declaration to analyze, so retain the trusted Ruby-core identity.
    raw_path = path.to_s
    if raw_path.start_with?("<internal:")
      return {
        package_manager: "ruby",
        package: "ruby",
        version: RUBY_VERSION,
      }
    end

    absolute = raw_path.empty? ? nil : abs_path(raw_path)
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
        elsif absolute == ROOT || absolute.start_with?("#{ROOT}#{File::SEPARATOR}")
          # Trace targets are intentionally narrower than the workspace: a
          # project may call a sibling tool without instrumenting that tool's
          # source. It is still a workspace declaration, not a Ruby core
          # method. Keep real loaded gems above this branch so a checked-out
          # gem dependency retains its exact Rubygems identity.
          {
            package_manager: "workspace",
            package: ENV.fetch("NIL_KILL_PROJECT_NAME", File.basename(ROOT)),
            version: ENV.fetch("NIL_KILL_PROJECT_VERSION", "workspace"),
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

  # C-backed accessors generated for a workspace/test class arrive as
  # :c_call events, so TracePoint gives them no Ruby method path.  Treating
  # every such method as CRuby incorrectly exports test doubles such as a
  # Struct reader as `ruby` stdlib symbols.  A named receiver class retains
  # the source location of its constant declaration; use that provenance only
  # for identity/role attribution. FactMine still owns the generated-accessor
  # complexity join.
  def self.native_receiver_source_location(receiver)
    klass = receiver.is_a?(Module) ? receiver : receiver.class
    return unless klass.is_a?(Module)

    @runtime_native_receiver_source_locations ||= {}
    return @runtime_native_receiver_source_locations[klass] if
      @runtime_native_receiver_source_locations.key?(klass)

    name = klass.name.to_s
    location = name.empty? ? nil : Object.const_source_location(name)
    path = location && location.first
    absolute = path && !path.start_with?("<") ? abs_path(path) : nil
    value = absolute && File.file?(absolute) ? { path: absolute, line: location.last.to_i } : nil
    @runtime_native_receiver_source_locations[klass] = value
  rescue StandardError
    @runtime_native_receiver_source_locations[klass] = nil if defined?(klass) && klass
    nil
  end

  def self.runtime_nonproduction_source_path?(path)
    absolute = File.expand_path(path, ROOT)
    return false unless absolute.start_with?("#{ROOT}#{File::SEPARATOR}")

    relative = absolute.delete_prefix("#{ROOT}#{File::SEPARATOR}")
    components = Pathname.new(relative).each_filename.to_a
    components.any? { |component| %w[test tests spec specs].include?(component) } ||
      components.last.to_s.match?(/(?:_test|_spec)\.rb\z/)
  rescue StandardError
    false
  end

  def self.record_runtime_scip_call(tp, receiver_shape: true, deduplicate: false, callsite: nil)
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
    callsite ||= frame[:callsite]
    return unless caller && callsite

    # Keep the trusted CRuby/generated-accessor identity for production
    # classes. The source-location override exists solely to prevent a test
    # double with a C-backed accessor from masquerading as CRuby stdlib.
    native_source = native ? native_receiver_source_location(tp.self) : nil
    native_source = nil unless native_source && runtime_nonproduction_source_path?(native_source.fetch(:path))
    raw_callee_path = native ? native_source&.fetch(:path, "").to_s : tp.path.to_s
    # Keep TracePoint's pseudo-file identity long enough for package
    # attribution, then omit it from the declaration locator entirely. It is
    # Ruby-core implementation metadata, not a repository source path.
    virtual_core_path = raw_callee_path.start_with?("<internal:")
    callee_path = if virtual_core_path
                    nil
                  else
                    abs_path(raw_callee_path)
                  end
    package = runtime_package(
      virtual_core_path ? raw_callee_path : callee_path,
      native: native && native_source.nil?
    )
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
      line: native_source ? native_source.fetch(:line) : (native ? nil : src_line(callee_path, tp.lineno)),
      native: native,
      receiver_type: class_name(tp.self),
    }.merge(package)
    receiver_domain = receiver_shape ? runtime_value_domain(tp.self) : runtime_type_domain(tp.self)

    key = [
      caller[:class], caller[:method], caller[:kind], caller[:path], caller[:line],
      callsite[:path], callsite[:line],
      callee[:owner], callee[:name], callee[:kind], callee[:path], callee[:line],
      callee[:receiver_type],
      callee[:native], callee[:package_manager], callee[:package], callee[:version],
    ]
    # The generic overlay consumes a type/domain set, never call frequency.
    # For identity-only evidence, the first observation is therefore a
    # complete fact. Per-thread memoization avoids a global mutex and hash
    # merge for every repetition of a hot native operation.
    seen = Thread.current[:__nil_kill_runtime_scip_identity_samples] ||= {}
    return key if deduplicate && seen[key]

    @lock.synchronize do
      record = (@runtime_calls[key] ||= {
        schema_version: 1,
        event: "runtime_call",
        language: "ruby",
        run_id: ENV.fetch("NIL_KILL_RUN_ID", ""),
        caller: caller,
        callsite: callsite,
        callee: callee,
        receiver_domain: receiver_domain,
        result_truths: [],
        count: 0,
      })
      merge_runtime_value_domain!(record[:receiver_domain], receiver_domain)
      record[:count] += 1
    end
    seen[key] = true if deduplicate
    key
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
      if record && (value == true || value == false)
        record[:result_truths] = Array(record[:result_truths]) | [value]
      end
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

  def self.runtime_type_domain(value)
    empty_runtime_value_domain.merge(types: [class_name(value)])
  end

  def self.runtime_value_domain(value)
    domain = empty_runtime_value_domain
    domain[:types] << class_name(value)
    record_key = runtime_record_shape_key(value)
    domain[:shapes] << shape_payload(record_key) if record_key
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

  # A runtime record is an observation about the value itself, rather than a
  # source-flow conclusion. Keep it in the language-neutral value-shape
  # vocabulary so FactMine can join it with its CFG/DFG without Ruby having to
  # reason about any call sites. Binding Struct#members also makes collection
  # safe when an application overrides `members` on a generated record.
  def self.runtime_record_shape_key(value, depth = 2)
    return unless value.is_a?(Struct)

    fields = ORIG_STRUCT_MEMBERS.bind_call(value)
    return unless fields.is_a?(Array)

    members = fields.each_with_object({}) do |field, out|
      name = field.to_s
      next if name.empty?

      # Ruby does not emit TracePoint call events for generated Struct reader
      # methods. Preserve the observed member value as a language-neutral
      # shape instead, so FactMine can type a downstream call through its
      # generic record-accessor CFG/DFG join.  This observes the value only;
      # it does not duplicate assignment or dispatch analysis in NilKill.
      member = ORIG_STRUCT_FETCH.bind_call(value, field)
      out[name] = runtime_record_member_shape(member, depth)
    end
    return if members.empty?

    name = class_name(value)
    signature = members.map { |member, shape| "#{member}=#{JSON.generate(shape)}" }.join("\\0")
    key = "record:#{name}:#{signature}".freeze
    remember_shape(key, { kind: "record", name: name, members: members })
  rescue StandardError
    nil
  end

  def self.runtime_record_member_shape(value, depth)
    return shape_payload(class_shape_key(value)) unless depth.positive?

    record_key = runtime_record_shape_key(value, depth - 1)
    return shape_payload(record_key) if record_key

    if collection_value?(value)
      return shape_payload(collection_type_shape_key(value, depth - 1))
    end

    shape_payload(class_shape_key(value))
  end

  def self.merge_runtime_value_domain!(target, source)
    source.each do |field, values|
      target[field] = (Array(target[field]) | Array(values)).sort_by do |item|
        item.is_a?(Hash) ? JSON.generate(item) : item.to_s
      end
    end
    target
  end

  # A valid new plan is an authority to elide unnecessary values. A missing
  # field means an older plan, so preserve exhaustive collection until the
  # next collect regenerates it rather than silently dropping evidence.
  def self.runtime_scip_result_capture?(callsite)
    runtime_scip_value_capture?("runtime_result_call_sites", callsite)
  end

  def self.runtime_scip_call_capture?(callsite)
    runtime_scip_value_capture?("runtime_call_sites", callsite)
  end

  def self.runtime_scip_receiver_shape_capture?(callsite)
    runtime_scip_value_capture?("runtime_collection_receiver_sites", callsite)
  end

  # The active source line can produce many native TracePoint events. Resolve
  # all three generic demands together and memoize them on that line anchor so
  # the hot path performs neither repeated plan parsing nor string allocation.
  def self.runtime_scip_captures_for(callsite)
    return [true, true, true] unless callsite
    return callsite[:runtime_scip_captures] if callsite.key?(:runtime_scip_captures)
    unless RUNTIME_SCIP_SOURCE_SLICE.empty? ||
        RUNTIME_SCIP_SOURCE_SLICE.include?(File.expand_path(callsite[:path]))
      return callsite[:runtime_scip_captures] = [false, false, false]
    end

    plan = trace_plan
    return callsite[:runtime_scip_captures] = [true, true, true] unless plan

    key = [callsite[:path], callsite[:line]].join("\0")
    callsite[:runtime_scip_captures] = %w[
      runtime_call_sites
      runtime_result_call_sites
      runtime_collection_receiver_sites
    ].map do |field|
      sites = plan[field]
      sites.nil? || sites[key] == true
    end
  end

  def self.runtime_scip_value_capture?(field, callsite)
    plan = trace_plan
    return true unless plan
    sites = plan[field]
    return true unless sites
    return false unless callsite

    sites[[callsite[:path], callsite[:line]].join("\0")] == true
  end

  def self.install_runtime_scip_trace
    events = %i[line call return]
    events << :c_call if runtime_scip_native_calls_enabled?
    TracePoint.new(*events) do |trace|
      case trace.event
      when :line
        record_runtime_scip_line(trace)
      when :call
        enter_runtime_scip_ruby_call(trace)
      when :return
        leave_runtime_scip_ruby_call(trace)
      when :c_call
        enter_runtime_scip_native_call(trace)
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
