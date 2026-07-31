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

  def self.native_scip_symbols_for(path, line, selector)
    native_scip_anchors_by_key.fetch("#{path}\x01#{line}\x01#{selector}", [])
  end

  # Generated record accessors are installed as transparent wrappers, so the
  # class TracePoint reports is not the owner the evidence needs. Ruby already
  # holds that mapping; the collector asks for it once per record rather than
  # carrying a second copy of the rule.
  def self.native_callee_identity(defined_class, method_id, native = false)
    declared = native_declaration_site(defined_class)
    target = @runtime_transparent_wrapper_targets[[defined_class, method_id.to_sym]]
    if target
      return [target[:owner], target[:kind], target[:native], target[:path],
              target[:line] || declared&.fetch(:line)]
    end

    # A C-backed method has no Ruby definition site of its own, but the module
    # it is defined on does. Without it a Struct reader, or any C method a
    # dependency gem defines, exports as CRuby stdlib and is priced by the wrong
    # cost model entirely. Core classes have no declaration file at all, so this
    # stays nil for String#to_s and its peers.
    site = native ? declared : nil

    # A singleton class of a plain object -- ENV is the common one -- has no
    # useful class name, so resolve it to the constant that names the object.
    if defined_class.is_a?(Class) && defined_class.singleton_class? &&
        (attached = singleton_attached_object(defined_class))
      named = runtime_named_singleton_owner(attached)
      return [named[0], named[1], nil, site&.fetch(:path), site&.fetch(:line)] if named
    end

    owner = method_owner(defined_class) ||
            native_anonymous_record_owner(defined_class) ||
            native_anonymous_owner(defined_class, method_id)
    return [nil, "instance", nil, site&.fetch(:path), site&.fetch(:line)] unless owner

    [owner[0], owner[1], nil, site&.fetch(:path), site&.fetch(:line)]
  end

  # An anonymous Struct layout is identified by its members, not by where it was
  # declared: two anonymous Structs sharing a file and line are still the same
  # record contract only if they expose the same fields.
  def self.native_anonymous_record_owner(defined_class)
    return nil unless defined_class.is_a?(Class) && defined_class < Struct

    fields = defined_class.members
    return nil unless fields.is_a?(Array) && !fields.empty?

    ["AnonymousStruct(#{fields.map(&:to_s).join(",")})", "instance"]
  rescue StandardError
    nil
  end

  # An anonymous class has no name to report, but its methods still have a
  # declaration site, which is the identity FactMine joins on.
  def self.native_anonymous_owner(defined_class, method_id)
    return nil unless defined_class.is_a?(Module)

    singleton = defined_class.is_a?(Class) && defined_class.singleton_class?
    subject = singleton ? singleton_attached_object(defined_class) : defined_class
    return nil unless subject.is_a?(Module)

    location = (singleton ? subject.method(method_id) : subject.instance_method(method_id))
      .source_location
    return nil unless location && location[0] && location[1]

    ["#{singleton ? 'AnonymousSingleton' : 'AnonymousClass'}" \
     "(#{runtime_relative_declaration_path(location[0])}:#{location[1]})",
     singleton ? "class" : "instance"]
  rescue StandardError
    nil
  end

  def self.runtime_relative_declaration_path(path)
    absolute = abs_path(path)
    return "." if absolute == ROOT
    return absolute.delete_prefix("#{ROOT}#{File::SEPARATOR}") if
      absolute.start_with?("#{ROOT}#{File::SEPARATOR}")

    absolute
  end

  # `native_receiver_source_location` answers for a receiver; the collector asks
  # about the class a method is defined on, which for a singleton is the module
  # it is attached to.
  def self.native_declaration_site(defined_class)
    return nil unless defined_class.is_a?(Module)

    subject =
      if defined_class.is_a?(Class) && defined_class.singleton_class?
        singleton_attached_object(defined_class)
      else
        defined_class
      end
    return nil unless subject.is_a?(Module)

    # A constant defined in C reports its extension file with line 0. That is a
    # load location, not a declaration, and claiming it turns an opaque CRuby
    # method into apparent project source.
    site = native_receiver_source_location(subject)
    site if site && site.fetch(:line).positive?
  end

  def self.singleton_attached_object(singleton)
    singleton.attached_object if singleton.respond_to?(:attached_object)
  rescue TypeError
    nil
  end

  def self.install_native_runtime_scip_trace
    require_native_scip!
    NilKillTraceNative.value_domain_owner = self
    NilKillTraceNative.value_domain_root = ROOT
    NilKillTraceNative.configure(
      Array(TARGETS).map(&:to_s), native_scip_demand_map, native_scip_state_demand_map
    )
    NilKillTraceNative.start
  end

  def self.native_scip_domain(types, indices, production_only: false)
    domain = empty_runtime_value_domain
    Array(types).each { |type| merge_runtime_value_domain!(domain, types: [type]) }
    Array(indices).each do |index|
      observed = NilKillTraceNative.domains.fetch(index)
      next if production_only && observed[:nonproduction]

      merge_runtime_value_domain!(domain, observed.reject { |field, _| field == :nonproduction })
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
        # A known definition site outranks the C-implementation flag for package
        # attribution: a generated accessor on a workspace class is workspace
        # code, not CRuby, even though the VM reported it as a native call.
        callee: callee.merge(path: path, line: (path ? callee[:line] : nil))
          .merge(native_scip_callee_facts(path, callee.fetch(:native) && path.nil?)),
        receiver_domain: native_scip_domain(
          row.fetch(:receiver_types), row.fetch(:receiver_domain_indices),
          production_only: true
        ),
        result_domain: native_scip_domain(
          row.fetch(:result_types), row.fetch(:result_domain_indices),
          production_only: true
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

  # The same observations answer two questions: which classes a member holds
  # anywhere (ivars) and which it holds at one write site (state-values).
  def self.native_scip_state_rows
    NilKillTraceNative.state_values.map do |path, line, owner, name, classes, calls|
      { path: path, line: line, class: owner, name: name,
        classes: classes.compact.sort, calls: calls }
    end
  end

  # `dump` owns the ivars/state-values files for every tier, so the observations
  # are handed to the tables it serialises rather than written a second time.
  def self.publish_native_state_observations!
    native_scip_state_rows.each do |row|
      owner = row.fetch(:class)
      name = row.fetch(:name)
      classes = row.fetch(:classes)
      calls = row.fetch(:calls)
      field = (@ivar_runtime[[owner, "@#{name}"]] ||= { calls: 0, classes: NKSet.new })
      field[:calls] += calls
      classes.each { |type| field[:classes] << type }
      site = (
        @runtime_state_values[[row.fetch(:path), row.fetch(:line), owner, name]] ||=
          { calls: 0, classes: NKSet.new }
      )
      site[:calls] += calls
      classes.each { |type| site[:classes] << type }
    end
  end

  # An edge is a fact about the call graph, not evidence about a requested
  # value, so it is recorded for every call between two analyzed methods rather
  # than only for callsites the plan demanded. Both endpoints are function
  # entries, so their owner and name are read back from those.
  def self.native_scip_method_edge_rows
    entries = NilKillTraceNative.function_entries.to_h do |path, owner, name, line, _count|
      [[path, line], { class: owner, method: name, kind: "instance", path: path, line: line }]
    end
    NilKillTraceNative.method_edges.filter_map do |caller_path, caller_line, callee_path, callee_line, calls|
      from = entries[[caller_path, caller_line]]
      to = entries[[callee_path, callee_line]]
      next unless from && to

      { caller: from, callee: to, calls: calls, ok_calls: calls, raised_calls: 0 }
    end
  end

  # The shard writes its own trace. It already holds every observation in
  # memory, so having the collector read the JSONL back and re-encode it was the
  # same work done twice -- once here and once in a stage that could not start
  # until every shard had finished.
  # One trace per shard directory, covering every process that dumped into it,
  # which is what the collector-side stage this replaces produced. A workload
  # may fork; the children dump their jsonl and the process that started the
  # shard aggregates, so a fork does not turn into several partial traces.
  def self.write_native_trace(pid)
    # Read from the directory rather than from memory: a forked child's calls
    # live in the child's tables, and this process only ever saw its own. The
    # jsonl each process dumped is the one place all of them meet.
    calls = native_trace_jsonl("runtime-calls-*.jsonl").map do |event|
      row = NilKill::Languages::Providers::Ruby::RuntimeValueEvidence.call(
        event: event, root: ROOT
      )
      { "row" => row, "bucket" => native_trace_call_bucket(row, event) }.compact
    end
    observations =
      NilKill::Languages::Providers::Ruby::RuntimeValueEvidence
        .observations(runtime_dir: OUT_DIR, root: ROOT)
        .map { |row| row.merge("bucket" => native_trace_value_bucket(row)).compact }

    write_json(NilKill::Runtime::TraceArtifact::DEFAULT_NAME, {
      "trace_version" => 1,
      "producer" => { "name" => "nil-kill", "version" => "1" },
      "trace_plan_digest" => trace_plan_digest,
      "languages" => ["ruby"],
      "environment" => runtime_scip_environment(root: ROOT)
        .sort.map { |key, value| { "key" => key.to_s, "value" => value.to_s } },
      "run_ids" => [ENV.fetch("NIL_KILL_RUN_ID", "")].reject(&:empty?),
      "invalid_events" => 0,
      "observations" => observations,
      "calls" => calls,
      "executed_callsites" => native_trace_jsonl("executed-callsites-*.jsonl"),
      "exact_anchor_executions" => native_trace_jsonl("exact-anchor-executions-*.jsonl"),
      "function_entries" => native_trace_jsonl("function-entries-*.jsonl"),
      "coverage" => native_trace_jsonl("coverage-*.jsonl"),
    })
  end

  # The value encoder asks its provider how this language names a type. Inside
  # the traced process the collector is that provider.
  def self.runtime_evidence_type_symbol(type)
    NilKill::Languages::Providers::Ruby::RuntimeValueEvidence.runtime_type_symbol(type)
  end

  def self.runtime_evidence_singleton_symbol(type)
    NilKill::Languages::Providers::Ruby::RuntimeValueEvidence.runtime_singleton_symbol(type)
  end

  def self.runtime_evidence_provenance
    NilKill::Runtime::EnvironmentClaims.ruby_provenance
  end

  def self.runtime_scip_environment(root:)
    NilKill::Runtime::EnvironmentClaims.ruby(root: root)
  end

  # The evidence plan travels inside the same document the collector already
  # reads, so the shard can name the plan it was traced against without the
  # collector telling it. The digests must agree or the merge rejects the trace.
  def self.trace_plan_digest
    Hash(trace_plan&.fetch("runtime_evidence", nil)).fetch("plan_digest", "").to_s
  end

  def self.native_trace_value_bucket(row)
    values = NilKill::Runtime::ValueEncoding.value_set(
      row.fetch("domain"), count: row.fetch("count", 1),
      provider: self, source_role: "UNKNOWN_SOURCE"
    )
    return nil unless values

    {
      "count" => [row.fetch("count", 1).to_i, 1].max,
      "value" => values,
      "provenance" => runtime_evidence_provenance.merge("run_id" => ""),
    }
  end

  def self.native_trace_call_bucket(row, event)
    receiver = NilKill::Runtime::ValueEncoding.value_set(
      row["receiver_domain"], count: row.fetch("count", 1), provider: self,
      source_role: row.fetch("receiver_source_role", "UNKNOWN_SOURCE")
    )
    return nil unless receiver

    bucket = {
      "count" => [row.fetch("count", 1).to_i, 1].max,
      "receiver" => receiver,
      "target" => NilKill::Runtime::ValueEncoding.target(row),
      "target_definition" => row.dig("target", "definition"),
      "provenance" => runtime_evidence_provenance.merge(
        "run_id" => event["run_id"].to_s
      ),
    }
    result = NilKill::Runtime::ValueEncoding.value_set(
      row["result_domain"], count: row.fetch("count", 1), provider: self,
      source_role: "UNKNOWN_SOURCE"
    )
    bucket["result"] = result if result
    truths = Array(row["result_truths"]).uniq
    bucket["boolean_result"] = truths.first if truths.length == 1
    bucket
  end

  def self.native_trace_jsonl(glob)
    Dir[File.join(OUT_DIR, glob)].sort.flat_map do |path|
      File.readlines(path, chomp: true).filter_map do |line|
        JSON.parse(line)
      rescue JSON::ParserError
        nil
      end
    end
  end

  def self.write_json(name, payload)
    require "zlib"
    path = File.join(OUT_DIR, name)
    Zlib::GzipWriter.open(path) { |io| io.write(JSON.generate(payload)) }
    path
  end

  def self.dump_native_runtime_scip(pid)
    NilKillTraceNative.stop
    write_jsonl("runtime-calls-#{pid}.jsonl", native_scip_call_rows)
    write_jsonl("methods-#{pid}.jsonl", native_scip_method_rows)
    write_jsonl("collections-#{pid}.jsonl", native_scip_collection_rows)
    publish_native_state_observations!
    write_jsonl("method-edges-#{pid}.jsonl", native_scip_method_edge_rows)
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
