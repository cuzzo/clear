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

  def self.native_scip_requested?
    ENV["NIL_KILL_NATIVE_SCIP"] == "1" && native_scip_available?
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

  def self.native_scip_symbols_for(path, line, selector)
    native_scip_anchors_by_key.fetch("#{path}\x01#{line}\x01#{selector}", [])
  end

  # Generated record accessors are installed as transparent wrappers, so the
  # class TracePoint reports is not the owner the evidence needs. Ruby already
  # holds that mapping; the collector asks for it once per record rather than
  # carrying a second copy of the rule.
  def self.native_callee_identity(defined_class, method_id)
    target = @runtime_transparent_wrapper_targets[[defined_class, method_id.to_sym]]
    return [target[:owner], target[:kind], target[:native], target[:path]] if target

    # A singleton class of a plain object -- ENV is the common one -- has no
    # useful class name, so resolve it to the constant that names the object.
    if defined_class.is_a?(Class) && defined_class.singleton_class? &&
        (attached = singleton_attached_object(defined_class))
      named = runtime_named_singleton_owner(attached)
      return [named[0], named[1], nil, nil] if named
    end

    owner = method_owner(defined_class)
    return [nil, "instance", nil, nil] unless owner

    [owner[0], owner[1], nil, nil]
  end

  def self.singleton_attached_object(singleton)
    singleton.attached_object if singleton.respond_to?(:attached_object)
  rescue TypeError
    nil
  end

  def self.install_native_runtime_scip_trace
    NilKillTraceNative.value_domain_owner = self
    NilKillTraceNative.configure(Array(TARGETS).map(&:to_s), native_scip_demand_map)
    NilKillTraceNative.start
  end

  def self.native_scip_domain(types, indices)
    domain = empty_runtime_value_domain
    Array(types).each { |type| merge_runtime_value_domain!(domain, types: [type]) }
    Array(indices).each do |index|
      merge_runtime_value_domain!(domain, NilKillTraceNative.domains.fetch(index))
    end
    domain
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

  def self.native_scip_call_rows
    run_id = ENV.fetch("NIL_KILL_RUN_ID", "")
    NilKillTraceNative.records.flat_map do |row|
      callee = row.fetch(:callee)
      path = native_scip_definition_path(callee[:path])
      callsite = row.fetch(:callsite)
      symbols = native_scip_symbols_for(
        callsite.fetch(:path), callsite.fetch(:line), callsite.fetch(:selector)
      )
      symbols = [nil] if symbols.empty?
      symbols.map do |anchor_symbol|
      {
        schema_version: 1,
        event: "runtime_call",
        language: "ruby",
        run_id: run_id,
        caller: row.fetch(:caller),
        callsite: callsite.slice(:path, :line).merge(anchor_symbol: anchor_symbol),
        callee: callee.merge(path: path, line: (path ? callee[:line] : nil))
          .merge(native_scip_callee_facts(path, callee.fetch(:native))),
        receiver_domain: native_scip_domain(
          row.fetch(:receiver_types), row.fetch(:receiver_domain_indices)
        ),
        result_domain: native_scip_domain(
          row.fetch(:result_types), row.fetch(:result_domain_indices)
        ),
        result_truths: row.fetch(:result_truths),
        count: row.fetch(:count),
      }
      end
    end
  end

  # The evidence emitter reads parameter and return domains from methods-*.jsonl,
  # which the Ruby type tier used to produce. The collector already observes both
  # -- parameters at analyzed method entry, returns under the "return" selector --
  # so this regroups those records per function in the shape the emitter expects.
  def self.native_scip_method_rows
    records = NilKillTraceNative.records
    by_site = records.group_by do |row|
      [row.dig(:callsite, :path), row.dig(:callsite, :line)]
    end
    NilKillTraceNative.function_entries.map do |path, owner, name, line, count|
      rows = by_site.fetch([path, line], [])
      params = rows.reject { |row| row.dig(:callsite, :selector) == "return" }
      returned = rows.find { |row| row.dig(:callsite, :selector) == "return" }
      row = {
        class: owner, method: name, kind: "instance", path: path, line: line,
        calls: count, ok_calls: count, raised_calls: 0,
        params_by_name: {}, param_singleton_types: {}, param_value_shapes: {},
        param_elem: {}, param_elem_shapes: {}, param_kv: {}, param_kv_shapes: {},
        params_ok: {}, params_raised: {}, param_sites: {},
        returns: [], return_singleton_types: [], return_value_shapes: [],
        return_elem: [], return_elem_shapes: [], return_kv: [[], []],
        return_kv_shapes: [[], []],
      }
      params.each do |param|
        slot = param.dig(:callsite, :selector)
        domain = native_scip_domain(
          param.fetch(:receiver_types), param.fetch(:receiver_domain_indices)
        )
        row[:params_by_name][slot] = domain.fetch(:types)
        row[:param_singleton_types][slot] = domain.fetch(:singletons)
        row[:param_value_shapes][slot] = domain.fetch(:shapes)
        row[:param_elem][slot] = domain.fetch(:elements)
        row[:param_elem_shapes][slot] = []
        row[:param_kv][slot] = [domain.fetch(:keys), domain.fetch(:values)]
        row[:param_kv_shapes][slot] = [[], []]
      end
      if returned
        domain = native_scip_domain(
          returned.fetch(:result_types), returned.fetch(:result_domain_indices)
        )
        row[:returns] = domain.fetch(:types)
        row[:return_singleton_types] = domain.fetch(:singletons)
        row[:return_value_shapes] = domain.fetch(:shapes)
        row[:return_elem] = domain.fetch(:elements)
        row[:return_kv] = [domain.fetch(:keys), domain.fetch(:values)]
      end
      row
    end
  end

  COLLECTION_KINDS = { "Array" => "array", "Hash" => "hash", "Set" => "set" }.freeze

  # A collection observation is keyed by the slot it came from, at that slot's
  # definition line, which is what FactMine links to a COLLECTION_OPERATION
  # anchor through its own flow facts. A reader whose result is a collection is
  # exactly such a slot, and the callee definition site the collector records is
  # its location.
  def self.native_scip_collection_rows
    NilKillTraceNative.records.filter_map do |row|
      callee = row.fetch(:callee)
      path = native_scip_definition_path(callee[:path])
      owner = callee[:owner]
      next unless path && owner && callee[:name]

      domain = native_scip_domain(
        row.fetch(:result_types), row.fetch(:result_domain_indices)
      )
      kind = domain.fetch(:types).filter_map { |type| COLLECTION_KINDS[type] }.first
      next unless kind

      {
        owner_kind: "struct_field",
        name: "#{owner}.#{callee[:name]}",
        path: path,
        line: callee[:line].to_i,
        kind: kind,
        calls: row.fetch(:count),
        classes: domain.fetch(:types),
        elem_classes: domain.fetch(:elements),
        key_classes: domain.fetch(:keys),
        value_classes: domain.fetch(:values),
        elem_shapes: [], key_shapes: [], value_shapes: [],
        mutation_sites: {},
      }
    end
  end

  def self.dump_native_runtime_scip(pid)
    NilKillTraceNative.stop
    write_jsonl("runtime-calls-#{pid}.jsonl", native_scip_call_rows)
    write_jsonl("methods-#{pid}.jsonl", native_scip_method_rows)
    write_jsonl("collections-#{pid}.jsonl", native_scip_collection_rows)
    write_jsonl(
      "executed-callsites-#{pid}.jsonl",
      NilKillTraceNative.executed_callsites.sort_by { |row| row.map(&:to_s) }.map do |path, line, selector, count|
        { path: path, line: line, selector: selector, count: count }
      end
    )
    write_jsonl(
      "exact-anchor-executions-#{pid}.jsonl",
      NilKillTraceNative.executed_callsites
        .each_with_object(Hash.new(0)) do |(path, line, selector, count), tally|
          native_scip_symbols_for(path, line, selector).each { |symbol| tally[symbol] += count }
        end
        .sort.map { |symbol, count| { symbol: symbol, count: count } }
    )
    write_jsonl(
      "function-entries-#{pid}.jsonl",
      NilKillTraceNative.function_entries.sort_by { |row| row.map(&:to_s) }.map do |path, owner, name, line, count|
        { path: path, owner: owner, name: name, kind: "instance", line: line, count: count }
      end
    )
  end

  def self.write_jsonl(name, rows)
    File.open(File.join(OUT_DIR, name), "w") do |file|
      rows.each { |row| file.puts JSON.generate(row) }
    end
  end
end
