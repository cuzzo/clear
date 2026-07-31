# frozen_string_literal: true

# Drives the native observation loop in place of the Ruby :line/:call/:c_call
# handlers, then renders its records into the artifacts the evidence emitter
# already consumes. Only the per-event loop moves to C; run identity, package
# attribution, value-domain shapes for containers, and every output format stay
# here where they are already covered by tests.
module NilKillRuntimeTrace
  NATIVE_SCIP_EXT = File.expand_path("../../../../../ext/nil_kill_trace", __dir__)

  def self.native_scip_available?
    return @native_scip_available if defined?(@native_scip_available)

    @native_scip_available = begin
      $LOAD_PATH.unshift(NATIVE_SCIP_EXT) unless $LOAD_PATH.include?(NATIVE_SCIP_EXT)
      require "nil_kill_trace"
      true
    rescue LoadError
      false
    end
  end

  # The collector has no Ruby fallback any more, so a missing extension is a
  # broken install rather than a slower mode to degrade into.
  def self.require_native_scip!
    return if native_scip_available?

    abort "nil-kill: the native trace extension is not built. Run " \
      "`ruby extconf.rb && make` in #{NATIVE_SCIP_EXT}."
  end

  # "<abs path>\1<line>\1<selector>" => every anchor symbol the plan requests at
  # that coordinate. One observed event can satisfy several requests -- a
  # COLLECTION_OPERATION and a CALL_SELECTOR anchor routinely share a line and
  # selector -- so the collector reports coordinates and the fan-out happens here.
  def self.native_scip_anchors_by_key
    @native_scip_anchors_by_key ||=
      Array(trace_plan&.dig("runtime_evidence", "requests"))
        .each_with_object({}) do |request, map|
          anchor = request["anchor"]
          next unless anchor.is_a?(Hash)

          range = request["execution_range"] || anchor["range"]
          next unless range.is_a?(Hash)

          path = abs_path(anchor.fetch("relative_path"))
          selector = anchor.fetch("display_name").to_s
          symbol = anchor.fetch("symbol").to_s
          (range.fetch("start_line").to_i..range.fetch("end_line").to_i).each do |line|
            key = "#{path}\x01#{line + 1}\x01#{selector}"
            (map[key] ||= []) << symbol unless map[key]&.include?(symbol)
          end
        end
  end

  def self.native_scip_demand_map
    native_scip_anchors_by_key.transform_values(&:first)
  end

  # A state write is the one anchor kind with no event of its own: Ruby raises
  # nothing when an ivar is assigned. The collector therefore reads the member
  # back after the demanded line has run, which needs the member's own ivar name
  # as well as the bare name the plan asks under.
  def self.native_scip_state_demand_map
    @native_scip_state_demand_map ||=
      Array(trace_plan&.dig("runtime_evidence", "requests"))
        .each_with_object({}) do |request, map|
          anchor = request["anchor"]
          next unless anchor.is_a?(Hash) && anchor["kind"] == "STATE_WRITE"

          range = anchor["range"]
          next unless range.is_a?(Hash)

          name = anchor.fetch("display_name").to_s
          next if name.empty?

          path = abs_path(anchor.fetch("relative_path"))
          map["#{path}\x01#{range.fetch("start_line").to_i + 1}\x01#{name}"] = "@#{name}"
        end
  end

  def self.install_native_runtime_scip_trace
    require_native_scip!
    NilKillTraceNative.value_domain_root = ROOT
    NilKillTraceNative.configure(
      Array(TARGETS).map(&:to_s), native_scip_demand_map, native_scip_state_demand_map
    )
    NilKillTraceNative.start
  end

  # Both are pure functions of the callee path and are asked once per emitted
  # row, so they are memoised per path rather than per row.
  # A wrapper installed by the collector, and a pseudo-path such as
  # <internal:kernel>, are not the callee's definition site. Reporting them would
  # attribute a dependency call to NilKill's own source.
  def self.native_scip_definition_path(path)
    return nil unless path.is_a?(String)
    return nil if path.start_with?("<")
    return nil if path.include?("/gems/nil-kill/lib/")

    path
  end

  def self.native_scip_callee_facts(path, native)
    @native_scip_callee_facts ||= {}
    @native_scip_callee_facts[[path, native]] ||= {
      source_role: (path && runtime_nonproduction_source_path?(path) ? "nonproduction" : nil),
    }.merge(runtime_package(path, native: native))
  end
  # Everything the collector saw, written once so the shaping can happen
  # outside the traced program. The package table is the one part only this
  # process could produce: which gem or workspace file a path came from is a
  # fact about the VM that observed it.
  def self.dump_native_runtime_scip(pid)
    NilKillTraceNative.stop
    records = NilKillTraceNative.records
    write_json("collector-raw-#{pid}.json.gz", {
      pid: pid,
      run_id: ENV.fetch("NIL_KILL_RUN_ID", ""),
      records: records,
      domains: NilKillTraceNative.domains,
      executed_callsites: NilKillTraceNative.executed_callsites,
      function_entries: NilKillTraceNative.function_entries,
      state_values: NilKillTraceNative.state_values,
      method_edges: NilKillTraceNative.method_edges,
      collections: NilKillTraceNative.collection_observations,
      structs: NilKillTraceNative.struct_observations,
      tuples: NilKillTraceNative.tuple_observations,
      tlets: NilKillTraceNative.tlet_observations,
      packages: package_facts(records),
    })
  end

  # Asked once per distinct definition site rather than once per row.
  def self.package_facts(records)
    records.each_with_object({}) do |row, facts|
      callee = row.fetch(:callee)
      path = native_scip_definition_path(callee[:path])
      native = callee.fetch(:native) && path.nil?
      facts["#{path}\x01#{native ? 1 : 0}"] ||= native_scip_callee_facts(path, native)
    end
  end

  def self.write_json(name, payload)
    require "zlib"
    path = File.join(OUT_DIR, name)
    Zlib::GzipWriter.open(path) { |io| io.write(JSON.generate(payload)) }
    path
  end
end
