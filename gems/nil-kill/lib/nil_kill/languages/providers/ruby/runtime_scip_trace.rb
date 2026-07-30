# frozen_string_literal: true

# Ruby TracePoint support for the language-neutral NilKill runtime_call event.
# This file is loaded by the legacy Ruby tracer without loading the full
# NilKill command stack.
module NilKillRuntimeTrace
  @runtime_calls = {}
  @runtime_package_by_path = {}
  @runtime_scip_frames = Hash.new { |hash, thread_id| hash[thread_id] = [] }
  @runtime_scip_external_depth = Hash.new(0)
  @runtime_scip_native_calls = Hash.new { |hash, thread_id| hash[thread_id] = [] }
  @runtime_scip_native_result_depth = 0
  @runtime_function_entries = Hash.new(0)
  @runtime_executed_callsites = Hash.new(0)
  @runtime_exact_anchor_executions = Hash.new(0)
  @runtime_anchor_execution_stack = Hash.new { |hash, thread_id| hash[thread_id] = [] }
  @runtime_anchor_marker_depth = Hash.new(0)
  @runtime_generated_wrapper_methods = Set.new
  # Collector-installed wrappers may be the Ruby frame observed by
  # TracePoint even though the workload invoked the wrapped method. Preserve
  # that raw target identity without doing any source/call-flow inference.
  @runtime_transparent_wrapper_targets = {}
  RUNTIME_SCIP_SOURCE_SLICE = ENV.fetch("NIL_KILL_TRACE_SOURCE_SLICE", "")
    .split(File::PATH_SEPARATOR)
    .reject(&:empty?)
    .map { |path| File.expand_path(path) }
    .to_set

  class << self
    attr_reader :runtime_calls, :runtime_scip_frames, :runtime_scip_native_calls
  end

  def self.register_runtime_scip_transparent_wrapper(defined_class, method_id, target)
    @runtime_transparent_wrapper_targets[[defined_class, method_id.to_sym]] = target.freeze
  end

  # Source instrumentation receives this opaque symbol/range from FactMine.
  # The collector records only that the expression was entered and associates
  # a matching TracePoint call with the symbol. It performs no source lookup,
  # receiver inference, dispatch resolution, or flow analysis.
  def self.begin_runtime_anchor_execution(symbol, selector)
    true
  end

  def self.end_runtime_anchor_execution(_symbol)
    nil
  end

  RUNTIME_ANCHOR_MARKER_METHODS = %i[
    begin_runtime_anchor_execution
    end_runtime_anchor_execution
  ].freeze
  RUNTIME_ANCHOR_MARKER_PATH = __FILE__.freeze

  # Marker methods intentionally have inert bodies. Consume their literal
  # arguments inside the active Ruby TracePoint callback, where Ruby suppresses
  # nested tracing. Otherwise the marker's own Hash/Thread operations become
  # native events in the demand window they are controlling.
  def self.record_runtime_anchor_marker_call(tp)
    return false unless tp.path == RUNTIME_ANCHOR_MARKER_PATH
    return false unless RUNTIME_ANCHOR_MARKER_METHODS.include?(tp.method_id)

    thread_id = Thread.current.object_id
    @runtime_anchor_marker_depth[thread_id] += 1
    symbol = tp.binding.local_variable_get(
      tp.method_id == :begin_runtime_anchor_execution ? :symbol : :_symbol
    ).to_s
    if tp.method_id == :begin_runtime_anchor_execution
      selector = tp.binding.local_variable_get(:selector).to_s
      @runtime_exact_anchor_executions[symbol] += 1
      @runtime_anchor_execution_stack[thread_id] << {
        symbol: symbol,
        selector: selector,
      }
      return true
    end

    stack = @runtime_anchor_execution_stack[Thread.current.object_id]
    index = stack.rindex { |entry| entry.fetch(:symbol) == symbol }
    stack.delete_at(index) if index
    true
  end

  def self.record_runtime_anchor_marker_return(tp)
    return false unless tp.path == RUNTIME_ANCHOR_MARKER_PATH
    return false unless RUNTIME_ANCHOR_MARKER_METHODS.include?(tp.method_id)

    thread_id = Thread.current.object_id
    depth = @runtime_anchor_marker_depth[thread_id]
    @runtime_anchor_marker_depth[thread_id] = depth - 1 if depth.positive?
    true
  end

  def self.runtime_exact_anchor_callsite(callsite, selector)
    return callsite unless callsite

    entry = @runtime_anchor_execution_stack[Thread.current.object_id]
      .reverse_each
      .find { |candidate| candidate.fetch(:selector) == selector.to_s }
    return callsite.merge(anchor_symbol: entry.fetch(:symbol)) if entry

    symbol = runtime_evidence_anchor_by_callsite[
      [abs_path(callsite[:path]), callsite[:line].to_i, selector.to_s]
    ]
    return callsite unless symbol

    @runtime_exact_anchor_executions[symbol] += 1
    callsite.merge(anchor_symbol: symbol)
  end

  # Bind unique events directly from FactMine's opaque trace-plan coordinates.
  # NilKill neither parses the expression nor resolves flow here. Duplicate
  # keys are deliberately omitted and are disambiguated by the expression
  # execution markers installed by the language adapter.
  def self.runtime_evidence_anchor_by_callsite
    @runtime_evidence_anchor_by_callsite ||= begin
      grouped = Array(trace_plan&.dig("runtime_evidence", "requests")).each_with_object(
        Hash.new { |hash, key| hash[key] = [] }
      ) do |request, by_callsite|
        anchor = request["anchor"]
        next unless anchor.is_a?(Hash)
        next unless %w[
          CALL_SELECTOR COLLECTION_OPERATION BRANCH_PREDICATE
        ].include?(anchor["kind"])

        range = request["execution_range"]
        next unless range.is_a?(Hash)

        (range.fetch("start_line").to_i..range.fetch("end_line").to_i).each do |line|
          key = [
            abs_path(anchor.fetch("relative_path")),
            line + 1,
            anchor.fetch("display_name").to_s,
          ]
          by_callsite[key] << anchor.fetch("symbol").to_s
        end
      end
      grouped.each_with_object({}) do |(key, symbols), unique|
        unique[key] = symbols.first if symbols.length == 1
      end.freeze
    end
  end

  def self.record_runtime_scip_line(tp)
    raw_path = tp.path
    selected_source = target_path?(raw_path)
    frame = selected_source ? @runtime_scip_frames[Thread.current.object_id].last : nil
    if @runtime_scip_native_call_armed && !frame
      @runtime_scip_native_call_armed = false
      @runtime_scip_native_selector_filter = nil
      runtime_scip_native_call_trace.disable
    end
    # A prior line can arm result capture without executing a native call.
    # Its window ends at the next Ruby line event, unless a native call is
    # still suspended across a yielding callback.
    if @runtime_scip_native_result_armed && !@runtime_scip_native_result_depth.to_i.positive?
      @runtime_scip_native_result_armed = false
      runtime_scip_native_result_trace.disable
    end
    return unless frame

    path = abs_path(raw_path)

    frame[:callsite] = {
      path: path,
      line: src_line(path, tp.lineno),
    }
    arm_runtime_scip_native_callsite(frame[:callsite])
  end

  def self.arm_runtime_scip_native_callsite(callsite)
    native_activation = if runtime_scip_native_calls_enabled?
                          runtime_scip_native_activation(callsite)
                        end
    activate_native_calls = !!native_activation
    @runtime_scip_native_selector_filter =
      native_activation.is_a?(Array) ? native_activation : nil
    if @runtime_scip_native_call_armed &&
       !activate_native_calls &&
       !@runtime_scip_native_result_depth.to_i.positive?
      @runtime_scip_native_call_armed = false
      runtime_scip_native_call_trace.disable
    elsif activate_native_calls && !@runtime_scip_native_call_armed
      # Native calls expose their caller location, but Ruby offers no
      # target-filtered C-call TracePoint. Scope the expensive listener to the
      # interval after a selected-source line and disable it at the very next
      # Ruby line, including a line in a dependency entered by that source.
      @runtime_scip_native_call_armed = true
      runtime_scip_native_call_trace.enable
    end
    _capture_call, capture_result, _receiver_shape = runtime_scip_captures_for(callsite)
    return unless capture_result && runtime_scip_native_calls_enabled?

    # Enable c_return before the requested c_call starts. Enabling it from
    # inside c_call can expose a VM housekeeping return that has no matching
    # c_call frame, corrupting the requested result.
    @runtime_scip_native_result_armed = true
    runtime_scip_native_result_trace.enable
  end

  def self.enter_runtime_scip_ruby_call(tp, selected_target: nil)
    thread_id = Thread.current.object_id
    frames = @runtime_scip_frames[thread_id]
    raw_path = tp.path
    target = selected_target.nil? ? target_path?(raw_path) : selected_target
    # Global Ruby call TracePoints also fire throughout Bundler, the test
    # framework, dependencies, and the VM's Ruby helpers. Outside a selected
    # production call tree there is no caller identity FactMine could consume.
    # A single depth counter balances an external subtree below a selected
    # caller without allocating one sentinel and resolving metadata for every
    # dependency call in that subtree. Selected callbacks still get a normal
    # frame and retain the nearest selected caller.
    unless target
      return if frames.empty?

      selected_frame = frames.last
      external_depth = selected_frame.fetch(:runtime_scip_external_depth, 0)
      fallback_callsite = selected_frame.fetch(:callsite, nil)
      if external_depth.zero? && fallback_callsite
        callsite = if runtime_scip_callsite_captures_selector?(fallback_callsite, tp.method_id)
                     fallback_callsite
                   else
                     runtime_scip_ruby_callsite(tp, fallback_callsite)
                   end
        callsite = runtime_exact_anchor_callsite(callsite, tp.method_id)
        capture_call, capture_result, receiver_shape =
          runtime_scip_captures_for(callsite, tp.method_id)
        observed_call = if capture_call || capture_result || receiver_shape
                          record_runtime_scip_call(
                            tp,
                            receiver_shape: receiver_shape,
                            deduplicate: !capture_result && !receiver_shape,
                            callsite: callsite,
                          )
                        end
        selected_frame[:runtime_scip_external_call] = {
          observed_call: observed_call,
          capture_result: capture_result && !observed_call.nil?,
        }
        if callsite && target_path?(callsite[:path])
          @runtime_executed_callsites[
            [callsite[:path], callsite[:line], tp.method_id.to_s]
          ] += 1
        end
      end
      selected_frame[:runtime_scip_external_depth] = external_depth + 1
      @runtime_scip_external_depth[thread_id] += 1
      return
    end

    path = abs_path(raw_path)
    parent = frames.last
    fallback_callsite = parent&.fetch(:callsite, nil)
    if fallback_callsite && target_path?(fallback_callsite[:path])
      @runtime_executed_callsites[
        [fallback_callsite[:path], fallback_callsite[:line], tp.method_id.to_s]
      ] += 1
    end
    # A Ruby :line event is emitted for the outer expression of a multiline
    # literal/call, not necessarily for a nested Ruby call inside it.  The
    # demand-driven trace plan is keyed by the nested call's real source line,
    # so treating that stale outer line as authoritative silently drops an
    # observation FactMine explicitly requested.  Avoid the comparatively
    # expensive stack lookup on the usual planned path; recover the caller
    # location only when the current line has no requested capture.
    callsite = if fallback_callsite.nil?
                 nil
               elsif runtime_scip_callsite_captures_selector?(fallback_callsite, tp.method_id)
                 fallback_callsite
               else
                 runtime_scip_ruby_callsite(tp, fallback_callsite)
               end
    callsite = runtime_exact_anchor_callsite(callsite, tp.method_id)
    capture_call, capture_result, receiver_shape =
      callsite ? runtime_scip_captures_for(callsite, tp.method_id) : [false, false, false]
    observed_call = if capture_call || capture_result || receiver_shape
                      record_runtime_scip_call(
                        tp,
                        receiver_shape: receiver_shape,
                        deduplicate: !capture_result && !receiver_shape,
                        callsite: callsite,
                      )
                    end
    owner = method_owner(tp.defined_class)
    if owner && target
      @runtime_function_entries[
        [path, owner[0], tp.method_id.to_s, owner[1], src_line(path, tp.lineno)]
      ] += 1
    end
    frames << {
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
    thread_id = Thread.current.object_id
    unless target_path?(tp.path)
      depth = @runtime_scip_external_depth[thread_id]
      @runtime_scip_external_depth[thread_id] = depth - 1 if depth.positive?
      selected_frame = @runtime_scip_frames[thread_id].last
      frame_depth = selected_frame&.fetch(:runtime_scip_external_depth, 0).to_i
      if frame_depth.positive?
        selected_frame[:runtime_scip_external_depth] = frame_depth - 1
        if frame_depth == 1
          external_call = selected_frame.delete(:runtime_scip_external_call)
          if external_call&.fetch(:capture_result, false) && !external_call[:raised]
            record_runtime_scip_result(external_call[:observed_call], tp.return_value)
          end
          # Collector-owned transparent helpers can run between the source
          # line event and a requested native call. Their non-selected line
          # events deliberately suspend the native listener; restore the
          # selected caller's exact demand window when that helper returns.
          parent_callsite = selected_frame[:callsite]
          arm_runtime_scip_native_callsite(parent_callsite) if parent_callsite
        end
      end
      return
    end

    frames = @runtime_scip_frames[thread_id]
    return if frames.empty?

    frame = frames.pop
    if frame&.fetch(:capture_result, false) && !frame[:raised]
      record_runtime_scip_result(frame[:observed_call], tp.return_value)
    end

    # Ruby emits no second :line event when evaluation resumes after a nested
    # Ruby call in the middle of one expression. Restore the parent's exact
    # native selector window here so calls in the remainder of that expression
    # are neither lost nor attributed to the callee's last source line.
    parent_callsite = frames.last&.fetch(:callsite, nil)
    arm_runtime_scip_native_callsite(parent_callsite) if parent_callsite
  end

  def self.record_runtime_scip_raise
    thread_id = Thread.current.object_id
    frame = @runtime_scip_frames[thread_id].last
    return unless frame

    if @runtime_scip_external_depth[thread_id].positive?
      frame[:runtime_scip_external_call][:raised] = true if frame[:runtime_scip_external_call]
    else
      frame[:raised] = true
    end
  end

  def self.enter_runtime_scip_native_call(tp)
    frame = @runtime_scip_frames[Thread.current.object_id].last
    # :c_call is the dominant event stream in a Ruby process. A native call
    # outside an active selected-source line cannot contribute a source
    # callsite, receiver, or result to FactMine, so reject it before path
    # normalization, trace-plan lookup, receiver inspection, or allocation.
    return unless frame&.fetch(:caller, nil) && frame[:callsite]
    selector_filter = @runtime_scip_native_selector_filter
    if selector_filter && !selector_filter.include?(tp.method_id.to_s)
      if @runtime_scip_native_result_depth.to_i.positive?
        @runtime_scip_native_calls[Thread.current.object_id] << {
          observed_call: nil,
          capture_result: false,
          defined_class: tp.defined_class,
          method_id: tp.method_id,
        }
      end
      return
    end

    callsite = runtime_scip_native_callsite(tp, frame&.fetch(:callsite, nil))
    callsite = runtime_exact_anchor_callsite(callsite, tp.method_id)
    capture_call, capture_result, receiver_shape =
      runtime_scip_captures_for(callsite, tp.method_id)
    unless capture_call || capture_result || receiver_shape
      if @runtime_scip_native_result_depth.to_i.positive?
        @runtime_scip_native_calls[Thread.current.object_id] << {
          observed_call: nil,
          capture_result: false,
          defined_class: tp.defined_class,
          method_id: tp.method_id,
        }
      end
      return
    end

    if callsite && target_path?(callsite[:path])
      @runtime_executed_callsites[[callsite[:path], callsite[:line], tp.method_id.to_s]] += 1
    end
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
    frame = frames.last
    # Some VM-generated C returns (notably Struct construction) have no
    # corresponding c_call event. They must not consume the outer requested
    # frame that is still suspended across the callback. Traced C calls are
    # strictly nested and every nested event gets a sentinel while a requested
    # result is in flight, so only the top frame can be a valid match. Keeping
    # this check O(1) also prevents unmatched VM events from turning a hot
    # c_return stream into repeated scans of a retained stack.
    return unless frame &&
      frame[:method_id] == tp.method_id &&
      frame[:defined_class].equal?(tp.defined_class)

    frames.pop
    record_runtime_scip_result(frame[:observed_call], tp.return_value) if frame[:capture_result]
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

  def self.runtime_scip_native_call_trace
    @runtime_scip_native_call_trace ||= TracePoint.new(:c_call) do |trace|
      enter_runtime_scip_native_call(trace)
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
        default_stubs = Gem::Specification.default_stubs
        spec = Gem.loaded_specs.values.find do |candidate|
          root = File.expand_path(candidate.full_gem_path)
          absolute == root || absolute.start_with?("#{root}#{File::SEPARATOR}")
        end
        spec ||= default_stubs.find do |candidate|
          root = File.expand_path(candidate.full_gem_path)
          absolute == root || absolute.start_with?("#{root}#{File::SEPARATOR}")
        end
        if spec
          stdlib = default_stubs.any? { |stub| stub.name == spec.name }
          {
            # Ruby ships a growing portion of its standard library as default
            # gems. Bundler may activate a newer vendored copy, but that does
            # not turn StringIO, JSON, etc. into third-party APIs.
            package_manager: stdlib ? "ruby" : "rubygems",
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

    declared_path = klass.instance_variable_get(:@__nil_kill_struct_path)
    declared_line = klass.instance_variable_get(:@__nil_kill_struct_line)
    name = klass.name.to_s
    location =
      if declared_path && declared_line
        [declared_path, declared_line]
      else
        name.empty? ? nil : Object.const_source_location(name)
      end
    path = location && location.first
    absolute = path && !path.start_with?("<") ? abs_path(path) : nil
    value = absolute && File.file?(absolute) ? { path: absolute, line: location.last.to_i } : nil
    @runtime_native_receiver_source_locations[klass] = value
  rescue StandardError
    @runtime_native_receiver_source_locations[klass] = nil if defined?(klass) && klass
    nil
  end

  def self.runtime_nonproduction_source_path?(path)
    runtime_nonproduction_source_paths.include?(File.expand_path(path, ROOT))
  rescue StandardError
    false
  end

  def self.runtime_nonproduction_source_paths
    source_roles_path = ENV["NIL_KILL_SOURCE_ROLES"].to_s
    cached = @runtime_nonproduction_source_paths
    return cached[:paths] if cached && cached[:source] == source_roles_path

    paths =
      if !source_roles_path.empty? && File.file?(source_roles_path)
        Array(JSON.parse(File.read(source_roles_path))["nonproduction"]).map do |path|
          File.expand_path(path, ROOT)
        end
      else
        []
      end
    @runtime_nonproduction_source_paths = {
      source: source_roles_path,
      paths: paths.to_set.freeze,
    }
    @runtime_nonproduction_source_paths[:paths]
  rescue StandardError
    @runtime_nonproduction_source_paths = {
      source: source_roles_path,
      paths: Set.new.freeze,
    }
    @runtime_nonproduction_source_paths[:paths]
  end

  def self.runtime_value_source_location(value)
    klass = value.is_a?(Module) ? value : value.class
    return unless klass.is_a?(Module)

    @runtime_value_source_locations ||= {}
    return @runtime_value_source_locations[klass] if
      @runtime_value_source_locations.key?(klass)

    name = safe_module_name(klass).to_s
    location = name.empty? ? nil : Object.const_source_location(name)
    if !location && name.empty?
      locations = klass.instance_methods(false).filter_map do |method_name|
        klass.instance_method(method_name).source_location
      rescue StandardError
        nil
      end
      location = locations.first
    end
    path = location && location.first
    absolute = path && !path.start_with?("<") ? abs_path(path) : nil
    @runtime_value_source_locations[klass] =
      absolute && File.file?(absolute) ? absolute : nil
  rescue StandardError
    @runtime_value_source_locations[klass] = nil if defined?(klass) && klass
    nil
  end

  def self.runtime_nonproduction_value?(value)
    path = runtime_value_source_location(value)
    path && runtime_nonproduction_source_path?(path)
  end

  def self.record_runtime_scip_call(tp, receiver_shape: true, deduplicate: false, callsite: nil)
    return if Thread.current[:__nil_kill_runtime_scip] ||
      Thread.current[:__nil_kill_collection_hook]
    # Existing NilKill recorders also use this mutex. When this thread already
    # owns it, the shared evidence maps are protected, but trying to acquire it
    # again would deadlock. The runtime-SCIP recursion guard below prevents
    # metadata discovery from re-entering this recorder, so merge directly
    # under the lock already held instead of dropping the demanded call.
    lock_owned = @lock.respond_to?(:owned?) && @lock.owned?

    Thread.current[:__nil_kill_runtime_scip] = true
    transparent_target =
      @runtime_transparent_wrapper_targets[[tp.defined_class, tp.method_id.to_sym]]
    owner = if transparent_target
              [
                transparent_target[:owner] || safe_module_name(tp.self),
                transparent_target.fetch(:kind),
              ]
            else
              method_owner(tp.defined_class)
            end
    return unless owner && owner[0]
    return if owner[0] == "NilKillRuntimeTrace"

    native = transparent_target ? transparent_target.fetch(:native) : tp.event == :c_call
    generated_wrapper = @runtime_generated_wrapper_methods.include?(
      [tp.defined_class, tp.method_id.to_sym]
    )
    frame = @runtime_scip_frames[Thread.current.object_id].last
    return unless frame
    caller = frame[:caller]
    callsite ||= frame[:callsite]
    return unless caller && callsite

    # Keep the trusted CRuby/generated-accessor identity for production
    # classes. The source-location override exists solely to prevent a test
    # double with a C-backed accessor from masquerading as CRuby stdlib.
    native_source =
      if native || generated_wrapper
        native_receiver_source_location(tp.self)
      end
    receiver_class = tp.self.is_a?(Module) ? tp.self : tp.self.class
    # A C event on a directly generated workspace method (Struct accessors
    # are the common case) has no method source_location, but its defining
    # class does. Preserve that declaration provenance. Do not apply the
    # receiver's source to inherited CRuby methods such as Array#each on a
    # project subclass: TracePoint's defined_class is authoritative there.
    native_source = nil unless native_source && tp.defined_class.equal?(receiver_class)
    raw_callee_path =
      if transparent_target
        transparent_target[:path].to_s
      elsif native || generated_wrapper
        native_source&.fetch(:path, "").to_s
      else
        tp.path.to_s
      end
    # Keep TracePoint's pseudo-file identity long enough for package
    # attribution, then omit it from the declaration locator entirely. It is
    # Ruby-core implementation metadata, not a repository source path.
    virtual_core_path = raw_callee_path.start_with?("<internal:")
    callee_path = if virtual_core_path || raw_callee_path.empty?
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
      name: transparent_target&.fetch(:name, nil) || tp.method_id.to_s,
      kind: owner[1],
      path: callee_path,
      line: native_source ? native_source.fetch(:line) : (native ? nil : src_line(callee_path, tp.lineno)),
      native: native,
      receiver_type: class_name(tp.self),
      source_role: (
        "nonproduction" if callee_path && runtime_nonproduction_source_path?(callee_path)
      ),
    }.merge(package)
    receiver_domain =
      if callee[:source_role] == "nonproduction"
        # A test double is still a real observed target. Preserve only its
        # nominal runtime identity so the protocol can report that the
        # production callsite was replaced; FactMine will exclude the
        # NON_PRODUCTION value and target from semantic inference.
        runtime_nonproduction_type_domain(tp.self)
      elsif receiver_shape
        runtime_value_domain(tp.self)
      else
        runtime_type_domain(tp.self)
      end
    return if runtime_value_domain_empty?(receiver_domain)

    key = [
      caller[:class], caller[:method], caller[:kind], caller[:path], caller[:line],
      callsite[:path], callsite[:line], callsite[:anchor_symbol],
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

    if lock_owned
      merge_runtime_scip_call!(key, caller, callsite, callee, receiver_domain)
    else
      @lock.synchronize do
        merge_runtime_scip_call!(key, caller, callsite, callee, receiver_domain)
      end
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

  def self.merge_runtime_scip_call!(key, caller, callsite, callee, receiver_domain)
    record = (@runtime_calls[key] ||= {
      schema_version: 1,
      event: "runtime_call",
      language: "ruby",
      run_id: ENV.fetch("NIL_KILL_RUN_ID", ""),
      caller: caller,
      callsite: {
        path: callsite[:path],
        line: callsite[:line],
        anchor_symbol: callsite[:anchor_symbol],
      },
      callee: callee,
      receiver_domain: receiver_domain,
      result_truths: [],
      count: 0,
    })
    merge_runtime_value_domain!(record[:receiver_domain], receiver_domain)
    record[:count] += 1
  end

  def self.record_runtime_scip_result(key, value)
    return unless key
    return if Thread.current[:__nil_kill_runtime_scip]

    Thread.current[:__nil_kill_runtime_scip] = true
    observed = runtime_value_domain(value)
    return if runtime_value_domain_empty?(observed)
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
      singletons: [],
      elements: [],
      keys: [],
      values: [],
      shapes: [],
    }
  end

  def self.runtime_type_domain(value)
    return empty_runtime_value_domain if runtime_nonproduction_value?(value)

    runtime_type = class_name(value)
    record_type = runtime_record_type_name(value)
    runtime_type = record_type if runtime_type == "T.untyped" && record_type
    domain = empty_runtime_value_domain.merge(types: [runtime_type])
    singleton = semantic_value_type_name(value)
    domain[:singletons] << singleton if singleton
    domain
  end

  def self.runtime_nonproduction_type_domain(value)
    domain = empty_runtime_value_domain.merge(types: [class_name(value)])
    singleton = semantic_value_type_name(value)
    domain[:singletons] << singleton if singleton
    domain
  end

  def self.runtime_value_domain(value)
    return empty_runtime_value_domain if runtime_nonproduction_value?(value)

    domain = empty_runtime_value_domain
    domain[:types] << class_name(value)
    singleton = semantic_value_type_name(value)
    domain[:singletons] << singleton if singleton
    record_key = runtime_record_shape_key(value)
    if record_key
      record_shape = shape_payload(record_key)
      domain[:shapes] << record_shape
      record_name = record_shape[:name] || record_shape["name"]
      domain[:types] = [record_name] if record_name && domain[:types] == ["T.untyped"]
    end
    shape = container_shape(value)
    if shape
      if shape[0] == :array
        domain[:elements].concat(
          shape[1].reject { |type| runtime_nonproduction_type_name?(type) }.to_a
        )
      else
        domain[:keys].concat(
          shape[1][0].reject { |type| runtime_nonproduction_type_name?(type) }.to_a
        )
        domain[:values].concat(
          shape[1][1].reject { |type| runtime_nonproduction_type_name?(type) }.to_a
        )
      end
      production_shape = runtime_production_shape(shape_payload(collection_type_shape_key(value)))
      domain[:shapes] << production_shape if production_shape
    end
    %i[types singletons elements keys values].each { |field| domain[field].sort! }
    domain[:shapes].sort_by! { |value_shape| JSON.generate(value_shape) }
    domain
  end

  def self.runtime_value_domain_empty?(domain)
    %i[types singletons elements keys values shapes].all? { |field| Array(domain[field]).empty? }
  end

  def self.runtime_nonproduction_type_name?(name)
    return false if name.to_s.empty? || name == "T.untyped" ||
      name.start_with?("AnonymousStruct(")

    constant = name.split("::").reject(&:empty?).reduce(Object) do |scope, part|
      break unless scope.is_a?(Module) && scope.const_defined?(part, false)

      scope.const_get(part, false)
    end
    constant.is_a?(Module) && runtime_nonproduction_value?(constant)
  rescue StandardError
    false
  end

  def self.runtime_production_shape(shape)
    return shape unless shape.is_a?(Hash)

    kind = shape[:kind] || shape["kind"]
    name = shape[:name] || shape["name"]
    return nil if %w[class record].include?(kind) &&
      runtime_nonproduction_type_name?(name)

    filtered = shape.each_with_object({}) do |(key, value), out|
      if %w[elements keys values].include?(key.to_s)
        out[key] = Array(value).filter_map { |member| runtime_production_shape(member) }
      elsif key.to_s == "members"
        out[key] = value.each_with_object({}) do |(member_name, member_shape), members|
          production = runtime_production_shape(member_shape)
          members[member_name] = production if production
        end
      else
        out[key] = value
      end
    end
    filtered
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

    name = runtime_record_type_name(value, fields)
    signature = members.map { |member, shape| "#{member}=#{JSON.generate(shape)}" }.join("\\0")
    key = "record:#{name}:#{signature}".freeze
    remember_shape(key, { kind: "record", name: name, members: members })
  rescue StandardError
    nil
  end

  def self.runtime_record_type_name(value, fields = nil)
    return unless value.is_a?(Struct)

    name = class_name(value)
    return name unless name == "T.untyped"

    # Anonymous Struct classes all lack a Ruby constant name. Treating every
    # layout as the same `T.untyped` record makes FactMine intersect unrelated
    # member sets and blocks generated-accessor proofs. The field schema is a
    # stable structural runtime identity; it claims no source-level nominal
    # type and is sufficient for the generic record contract.
    fields ||= ORIG_STRUCT_MEMBERS.bind_call(value)
    "AnonymousStruct(#{fields.map(&:to_s).join(",")})"
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
  def self.runtime_scip_result_capture?(callsite, selector = nil)
    runtime_scip_value_capture?("runtime_result_call_sites", callsite, selector)
  end

  def self.runtime_scip_call_capture?(callsite, selector = nil)
    runtime_scip_value_capture?("runtime_call_sites", callsite, selector)
  end

  def self.runtime_scip_callsite_captures_selector?(callsite, selector)
    return false unless callsite

    plan = trace_plan
    return true unless plan
    sites = plan["runtime_call_sites"]
    return true unless sites

    value = sites[[callsite[:path], callsite[:line]].join("\0")]
    value == true || Array(value).include?(selector.to_s)
  end

  def self.runtime_scip_receiver_shape_capture?(callsite, selector = nil)
    runtime_scip_value_capture?("runtime_collection_receiver_sites", callsite, selector)
  end

  def self.runtime_scip_native_activation(callsite)
    plan = trace_plan
    return true unless plan

    sites = plan["runtime_native_activation_sites"]
    return true unless sites

    sites[[callsite[:path], callsite[:line]].join("\0")]
  end

  def self.runtime_scip_native_activation?(callsite)
    !!runtime_scip_native_activation(callsite)
  end

  # The active source line can produce many native TracePoint events. Resolve
  # all three generic demands together and memoize them on that line anchor so
  # the hot path performs neither repeated plan parsing nor string allocation.
  def self.runtime_scip_captures_for(callsite, selector = nil)
    return [true, true, true] unless callsite
    if (anchor_symbol = callsite[:anchor_symbol])
      required = runtime_evidence_required_by_anchor[anchor_symbol.to_s]
      if required
        return [
          required.include?("RECEIVER_VALUE") || required.include?("CALL_TARGET"),
          required.include?("RESULT_VALUE") || required.include?("BOOLEAN_RESULT"),
          required.include?("COLLECTION_VALUE"),
        ]
      end
    end
    cache = (callsite[:runtime_scip_capture_cache] ||= {})
    cache_key = selector&.to_s
    return cache[cache_key] if cache.key?(cache_key)
    unless RUNTIME_SCIP_SOURCE_SLICE.empty? ||
        RUNTIME_SCIP_SOURCE_SLICE.include?(File.expand_path(callsite[:path]))
      return cache[cache_key] = [false, false, false]
    end

    plan = trace_plan
    return cache[cache_key] = [true, true, true] unless plan

    key = [callsite[:path], callsite[:line]].join("\0")
    cache[cache_key] = %w[
      runtime_call_sites
      runtime_result_call_sites
      runtime_collection_receiver_sites
    ].map do |field|
      sites = plan[field]
      value = sites && sites[key]
      sites.nil? || value == true || if selector
                                       Array(value).include?(selector.to_s)
                                     else
                                       !Array(value).empty?
                                     end
    end
  end

  def self.runtime_evidence_required_by_anchor
    @runtime_evidence_required_by_anchor ||= Array(
      trace_plan&.dig("runtime_evidence", "requests")
    ).to_h do |request|
      [
        request.dig("anchor", "symbol").to_s,
        Array(request["required"]).map(&:to_s).to_set.freeze,
      ]
    end
  end

  def self.runtime_scip_value_capture?(field, callsite, selector = nil)
    plan = trace_plan
    return true unless plan
    sites = plan[field]
    return true unless sites
    return false unless callsite

    value = sites[[callsite[:path], callsite[:line]].join("\0")]
    value == true || if selector
                       Array(value).include?(selector.to_s)
                     else
                       !Array(value).empty?
                     end
  end

  def self.install_runtime_scip_trace
    TracePoint.new(:line, :call, :return, :raise) do |trace|
      thread_id = Thread.current.object_id
      frames = @runtime_scip_frames[thread_id]
      case trace.event
      when :line
        next if @runtime_anchor_marker_depth[thread_id].positive?
        next if frames.empty? &&
          !@runtime_scip_native_call_armed &&
          !@runtime_scip_native_result_armed

        record_runtime_scip_line(trace)
      when :call
        next if record_runtime_anchor_marker_call(trace)
        selected_target = target_path?(trace.path)
        next if frames.empty? && !selected_target

        enter_runtime_scip_ruby_call(trace, selected_target: selected_target)
      when :return
        next if record_runtime_anchor_marker_return(trace)
        next if frames.empty? && !@runtime_scip_external_depth[thread_id].positive?

        leave_runtime_scip_ruby_call(trace)
      when :raise
        next if frames.empty?

        record_runtime_scip_raise
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
    File.open(File.join(OUT_DIR, "function-entries-#{pid}.jsonl"), "w") do |file|
      @runtime_function_entries.sort_by { |key, _count| key.map(&:to_s) }.each do |key, count|
        file.puts JSON.generate(
          path: key[0],
          owner: key[1],
          name: key[2],
          kind: key[3],
          line: key[4],
          count: count
        )
      end
    end
    File.open(File.join(OUT_DIR, "executed-callsites-#{pid}.jsonl"), "w") do |file|
      @runtime_executed_callsites.sort_by { |key, _count| key.map(&:to_s) }.each do |key, count|
        file.puts JSON.generate(
          path: key[0],
          line: key[1],
          selector: key[2],
          count: count
        )
      end
    end
    File.open(File.join(OUT_DIR, "exact-anchor-executions-#{pid}.jsonl"), "w") do |file|
      @runtime_exact_anchor_executions.sort.each do |symbol, count|
        file.puts JSON.generate(symbol: symbol, count: count)
      end
    end
  end
end
