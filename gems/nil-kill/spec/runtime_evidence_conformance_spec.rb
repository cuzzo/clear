# frozen_string_literal: true

require "yaml"
require_relative "spec_helper"

RSpec.describe "runtime evidence v1 shared executable conformance" do
  CONFORMANCE_ROOT = File.join(
    NilKill::ROOT,
    "protocol",
    "runtime-evidence",
    "v1",
    "conformance"
  )

  def catalog
    @catalog ||= YAML.safe_load(
      File.read(File.join(CONFORMANCE_ROOT, "capabilities.yml")),
      aliases: false
    )
  end

  def fixture(path)
    File.read(File.join(CONFORMANCE_ROOT, path))
  end

  def run_collector_oracle
    dir = Dir.mktmpdir("nk-runtime-conformance", NilKill::ROOT)
    source = catalog.fetch("fixture").fetch("source")
    lib(dir, fixture(source), File.basename(source))
    catalog.dig("fixture", "support").each do |support|
      relative = support.sub(%r{\Aruby/}, "")
      lib(dir, fixture(support), relative)
    end
    result = mini_collect(
      dir,
      File.basename(source),
      fixture(catalog.fetch("fixture").fetch("driver")),
      runtime_scip: true
    )
    plan = JSON.parse(File.read(NilKill::TRACE_PLAN_PATH)).fetch("runtime_evidence")
    # The production collector restores the source snapshot after the traced
    # process. The mini harness intentionally leaves its throwaway source
    # wrapped for instrumentation assertions, so restore it here before the
    # end-to-end FactMine snapshot check.
    File.write(File.join(dir, File.basename(source)), fixture(source))
    catalog.dig("fixture", "support").each do |support|
      relative = support.sub(%r{\Aruby/}, "")
      File.write(File.join(dir, relative), fixture(support))
    end
    emitted = NilKill::Runtime::ValueEvidenceEmitter.emit(
      root: NilKill::ROOT,
      runtime_dir: NilKill::RUNTIME_DIR,
      events: result.fetch(:runtime_calls),
      plan: plan
    )
    result.merge(
      fixture_root: dir,
      source: File.join(dir, File.basename(source)),
      runtime_dir: NilKill::RUNTIME_DIR,
      support: catalog.dig("fixture", "support").map do |support|
        File.join(dir, support.sub(%r{\Aruby/}, ""))
      end,
      plan: plan,
      evidence_path: emitted.fetch("path"),
      evidence: NilKill::Runtime::JsonIO.parse(emitted.fetch("path"))
    )
  rescue StandardError
    FileUtils.remove_entry(dir) if dir && File.directory?(dir)
    raise
  end

  def anchor_requests(plan, raw_events, anchor)
    events = raw_events.select do |event|
      event.dig("caller", "method") == anchor.fetch("method") &&
        event.dig("callee", "name") == anchor.fetch("selector")
    end
    if events.empty?
      selector_requests = plan.fetch("requests").select do |request|
        request.dig("anchor", "display_name") == anchor.fetch("selector") &&
          %w[CALL_SELECTOR COLLECTION_OPERATION BRANCH_PREDICATE]
            .include?(request.dig("anchor", "kind"))
      end
      return selector_requests if selector_requests.one?
    end
    expect(events).not_to be_empty,
      "collector emitted no raw event for #{anchor.fetch("method")}##{anchor.fetch("selector")}; " \
      "selector events=#{raw_events.select { |event|
        event.dig("callee", "name") == anchor.fetch("selector")
      }.map { |event| [event["caller"], event["callee"]] }}"
    lines = events.map { |event| event.dig("callsite", "line").to_i - 1 }.uniq
    plan.fetch("requests").select do |request|
      source_anchor = request.fetch("anchor")
      source_anchor.fetch("display_name") == anchor.fetch("selector") &&
        lines.include?(source_anchor.dig("range", "start_line").to_i)
    end.sort_by do |request|
      range = request.fetch("anchor").fetch("range")
      [
        range.fetch("start_line"),
        range.fetch("start_character"),
        range.fetch("end_line"),
        range.fetch("end_character"),
      ]
    end
  end

  def selected_request(result, anchor)
    matches = anchor_requests(result.fetch(:plan), result.fetch(:runtime_calls), anchor)
    matches.fetch(anchor.fetch("occurrence").to_i - 1)
  end

  def type_names(value_set)
    Array(value_set && value_set["alternatives"]).filter_map do |alternative|
      symbol = alternative.dig("value", "type_symbol").to_s
      next if symbol.empty?

      descriptor = symbol.split.last.to_s.delete_suffix("#").delete_suffix(".")
      descriptor.split("/").join("::").delete_prefix("`").delete_suffix("`")
    end
  end

  before(:context) do
    @collector = run_collector_oracle
  end

  after(:context) do
    root = @collector && @collector[:fixture_root]
    FileUtils.remove_entry(root) if root && File.directory?(root)
  end

  it "uses one shared catalog that covers the complete v1 behavior matrix" do
    capabilities = (
      catalog.fetch("cases").flat_map { |row| row.fetch("capabilities") } +
      catalog.fetch("merge_cases").flat_map { |row| row.fetch("capabilities") }
    ).to_set
    expect(capabilities).to include(
      "exact-anchor",
      "ambiguous-anchor",
      "nested-receiver",
      "assignment",
      "destructuring",
      "short-circuit-assignment",
      "native-call",
      "generated-accessor",
      "transparent-wrapper",
      "callback",
      "yield",
      "block-parameter",
      "dynamic-dispatch",
      "test-replacement",
      "container-shape",
      "exception",
      "non-returning-call",
      "subprocess",
      "result-object",
      "nonproduction-provenance",
      "dependency-provenance",
      "third-party-target",
      "repeated-run",
      "sharded-run",
      "incremental",
      "replacement"
    )
    matrix = catalog.fetch("wire_matrix")
    expect(matrix.fetch("anchor_kinds")).to contain_exactly(
      "FUNCTION_ENTRY",
      "FUNCTION_RETURN",
      "CALL_SELECTOR",
      "STATE_READ",
      "STATE_WRITE",
      "CALLBACK_ENTRY",
      "COLLECTION_OPERATION",
      "BRANCH_PREDICATE"
    )
    expect(matrix.fetch("evidence_kinds")).to contain_exactly(
      "PARAMETER_VALUE",
      "RETURN_VALUE",
      "RECEIVER_VALUE",
      "CALL_TARGET",
      "RESULT_VALUE",
      "BOOLEAN_RESULT",
      "STATE_VALUE",
      "COLLECTION_VALUE"
    )
    expect(matrix.fetch("capture_statuses").length).to eq(7)
    expect(matrix.fetch("source_roles").length).to eq(6)
    expect(matrix.fetch("value_shapes")).to contain_exactly(
      "sequence", "mapping", "record", "tuple"
    )
    expect(matrix.fetch("negative_controls").length).to be >= 10
  end

  it "negative control: cannot pass if an executed planned call has no raw event" do
    expect(@collector.fetch(:runtime_calls)).not_to be_empty
    exact = catalog.fetch("cases").find { |row| row.fetch("id") == "exact_ruby_call" }
    request = selected_request(@collector, exact.fetch("anchor"))
    without_exact = @collector.fetch(:runtime_calls).reject do |event|
      event.dig("caller", "method") == "exact_call" &&
        event.dig("callee", "name") == "normalize"
    end
    expect do
      anchor_requests(@collector.fetch(:plan), without_exact, exact.fetch("anchor"))
    end.to raise_error(RSpec::Expectations::ExpectationNotMetError, /no raw event/)
    expect(request.dig("anchor", "symbol")).not_to be_empty
  end

  it "collector oracle: every exact capability emits every requested field" do
    by_symbol = @collector.fetch(:evidence).fetch("anchors").to_h do |row|
      [row.fetch("anchor_symbol"), row]
    end
    catalog.fetch("cases").reject { |row| row.dig("expect", "correlation") }.each do |test_case|
      request = selected_request(@collector, test_case.fetch("anchor"))
      expected = test_case.fetch("expect")
      expect(request.fetch("required")).to include(*expected.fetch("required")),
        "#{test_case.fetch("id")} was not requested completely by FactMine"
      row = by_symbol.fetch(request.dig("anchor", "symbol"))
      expected_status = expected.fetch("allowed_status", "COMPLETE_FOR_RUNS")
      expect(row.dig("capture", "status")).to eq(expected_status),
        "#{test_case.fetch("id")}: #{row.dig("capture", "reason")}\n" \
        "request=#{JSON.generate(request)}\n" \
        "events=#{JSON.generate(@collector.fetch(:runtime_calls).select { |event|
          event.dig("caller", "method") == test_case.dig("anchor", "method")
        })}"
      if expected_status != "COMPLETE_FOR_RUNS"
        expect(row.dig("capture", "reason")).not_to be_empty
        expect(row.dig("capture", "complete_kinds")).to be_empty
        next
      end
      expect(row.dig("capture", "complete_kinds")).to include(*request.fetch("required"))
      expect(row.fetch("executions")).not_to be_empty
      row.fetch("executions").each do |bucket|
        request.fetch("required").each do |kind|
          field = {
            "RECEIVER_VALUE" => "receiver",
            "COLLECTION_VALUE" => "receiver",
            "CALL_TARGET" => "target",
            "RESULT_VALUE" => "result",
            "BOOLEAN_RESULT" => "boolean_result",
            "PARAMETER_VALUE" => "value",
            "RETURN_VALUE" => "value",
            "STATE_VALUE" => "value",
          }.fetch(kind)
          expect(bucket).to have_key(field),
            "#{test_case.fetch("id")} omitted requested #{kind}"
        end
      end
      first = row.fetch("executions").first
      matching_raw = @collector.fetch(:runtime_calls).select do |event|
        event.dig("caller", "method") == test_case.dig("anchor", "method") &&
          event.dig("callee", "name") == test_case.dig("anchor", "selector")
      end
      if expected["receiver_type"]
        expect(type_names(first["receiver"])).to include(expected.fetch("receiver_type"))
      end
      if expected["result_type"]
        expect(type_names(first["result"])).to include(expected.fetch("result_type"))
      end
      if expected["target_owner"]
        expect(matching_raw.map { |event| event.dig("callee", "owner") })
          .to include(expected.fetch("target_owner"))
        definition_anchor = first.dig("target", "definition", "anchor_symbol")
        if definition_anchor.to_s.empty?
          expect(first.dig("target", "symbol"))
            .to include(expected.fetch("target_owner").gsub("::", "/"))
        else
          expect(@collector.fetch(:plan).fetch("requests").any? do |candidate|
            candidate.dig("anchor", "symbol") == definition_anchor
          end).to be(true)
        end
      end
      if expected["source_role"]
        expect(first.dig("target", "source_role")).to eq(expected.fetch("source_role"))
      end
      unless expected["boolean_result"].nil?
        expect(first.fetch("boolean_result")).to eq(expected.fetch("boolean_result"))
      end
    end
  end

  it "collector oracle: same-line ambiguity is preserved once as a candidate correlation" do
    test_case = catalog.fetch("cases").find { |row| row.dig("expect", "correlation") }
    requests = test_case.fetch("anchors").map { |anchor| selected_request(@collector, anchor) }
    symbols = requests.map { |request| request.dig("anchor", "symbol") }.sort
    rows = @collector.fetch(:evidence).fetch("anchors").select do |row|
      symbols.include?(row.fetch("anchor_symbol"))
    end
    expect(rows.map { |row| row.dig("capture", "status") }).to eq(%w[PARTIAL PARTIAL])
    expect(rows.flat_map { |row| row.fetch("executions") }).to be_empty
    correlation = @collector.fetch(:evidence).fetch("correlations").find do |row|
      row.fetch("candidate_anchor_symbols") == symbols
    end
    expect(correlation).not_to be_nil
    expect(correlation.dig("capture", "status")).to eq("COMPLETE_FOR_RUNS")
    expect(correlation.fetch("executions")).not_to be_empty
  end

  it "collector oracle: function boundary parameters and returns satisfy the same requests" do
    by_symbol = @collector.fetch(:evidence).fetch("anchors").to_h do |row|
      [row.fetch("anchor_symbol"), row]
    end
    catalog.fetch("boundary_cases").each do |boundary|
      call_case = catalog.fetch("cases").find do |candidate|
        candidate.dig("anchor", "method") == boundary.fetch("method")
      end
      call_request = selected_request(@collector, call_case.fetch("anchor"))
      request = @collector.fetch(:plan).fetch("requests").find do |candidate|
        anchor = candidate.fetch("anchor")
        anchor.fetch("enclosing_symbol") == call_request.dig("anchor", "enclosing_symbol") &&
          anchor.fetch("kind") == boundary.fetch("anchor_kind") &&
          anchor.fetch("display_name") == boundary.fetch("display_name")
      end
      expect(request).not_to be_nil, boundary.fetch("id")
      expect(request.fetch("required")).to include(boundary.fetch("evidence_kind"))
      row = by_symbol.fetch(request.dig("anchor", "symbol"))
      expected_status = boundary.fetch("allowed_status", "COMPLETE_FOR_RUNS")
      expect(row.dig("capture", "status")).to eq(expected_status),
        "#{boundary.fetch("id")}: #{row.dig("capture", "reason")}"
      if expected_status != "COMPLETE_FOR_RUNS"
        expect(row.dig("capture", "reason")).not_to be_empty
        expect(row.dig("capture", "complete_kinds")).to be_empty
        expect(row.fetch("executions")).to be_empty
        next
      end
      expect(row.dig("capture", "complete_kinds")).to include(boundary.fetch("evidence_kind"))
      expect(type_names(row.dig("executions", 0, "value")))
        .to include(boundary.fetch("expected_type"))
    end
  end

  it "wire oracle: every declared value shape and source role round-trips canonically" do
    provider = NilKill::Languages.provider_for("ruby")
    domains = {
      "sequence" => {
        "types" => ["Array"],
        "shapes" => [{ "kind" => "array", "elements" => ["String"] }],
      },
      "mapping" => {
        "types" => ["Hash"],
        "shapes" => [{ "kind" => "hash", "keys" => ["Symbol"], "values" => ["String"] }],
      },
      "record" => {
        "types" => ["Record"],
        "shapes" => [{ "kind" => "record", "name" => "Record", "members" => { "id" => "Integer" } }],
      },
      "tuple" => {
        "types" => ["Array"],
        "shapes" => [{ "kind" => "tuple", "elements" => ["String", "Integer"] }],
      },
    }
    wire_fields = {
      "sequence" => "sequence",
      "mapping" => "mapping",
      "record" => "record",
      "tuple" => "tuple",
    }
    catalog.dig("wire_matrix", "value_shapes").each do |shape|
      value_set = NilKill::Runtime::EvidenceProtocol.value_set(
        domains.fetch(shape),
        count: 1,
        provider: provider
      )
      expect(value_set.dig("alternatives", 0, "value"))
        .to have_key(wire_fields.fetch(shape))
    end
    catalog.dig("wire_matrix", "source_roles").each do |source_role|
      value_set = NilKill::Runtime::EvidenceProtocol.value_set(
        { "types" => ["Object"] },
        count: 1,
        provider: provider,
        source_role: source_role
      )
      expect(value_set.dig("alternatives", 0, "value", "source_role")).to eq(source_role)
    end
  end

  it "generic invariant: every requested kind is complete or has a precise fail-closed explanation" do
    requests = @collector.fetch(:plan).fetch("requests").to_h do |request|
      [request.dig("anchor", "symbol"), request]
    end
    @collector.fetch(:evidence).fetch("anchors").each do |row|
      request = requests.fetch(row.fetch("anchor_symbol"))
      capture = row.fetch("capture")
      complete = capture.fetch("complete_kinds").to_set
      missing = request.fetch("required").to_set - complete
      if missing.empty?
        expect(%w[COMPLETE_FOR_RUNS NOT_EXECUTED]).to include(capture.fetch("status"))
      else
        expect(capture.fetch("status")).not_to eq("COMPLETE_FOR_RUNS")
        expect(capture.fetch("reason")).not_to be_empty,
          "#{row.fetch("anchor_symbol")} omitted #{missing.to_a.sort} without explanation"
      end
      row.fetch("executions").each do |bucket|
        complete.each do |kind|
          field = {
            "RECEIVER_VALUE" => "receiver",
            "COLLECTION_VALUE" => "receiver",
            "CALL_TARGET" => "target",
            "RESULT_VALUE" => "result",
            "BOOLEAN_RESULT" => "boolean_result",
            "PARAMETER_VALUE" => "value",
            "RETURN_VALUE" => "value",
            "STATE_VALUE" => "value",
          }.fetch(kind)
          expect(bucket).to have_key(field),
            "#{row.fetch("anchor_symbol")} claims complete #{kind} without #{field}"
        end
      end
    end
  end

  it "shared merge oracle: repeated shards add and a replaced shard owns no stale run" do
    exact = catalog.fetch("cases").find { |row| row.fetch("id") == "exact_ruby_call" }
    request = selected_request(@collector, exact.fetch("anchor"))
    paths = %w[run-a run-b].map do |run_id|
      events = @collector.fetch(:runtime_calls).map { |event| event.merge("run_id" => run_id) }
      NilKill::Runtime::ValueEvidenceEmitter.emit(
        root: NilKill::ROOT,
        runtime_dir: @collector.fetch(:runtime_dir),
        output: File.join(NilKill::TMP_DIR, "#{run_id}.json.gz"),
        events: events,
        run_ids: [run_id],
        plan: @collector.fetch(:plan)
      ).fetch("path")
    end
    merged = NilKill::Runtime::EvidenceMerger.merge(paths)
    repeated = catalog.fetch("merge_cases").find do |row|
      row.fetch("id") == "repeated_runs_are_additive"
    end
    expect(merged.fetch("runs").map { |run| run.fetch("id") })
      .to eq(repeated.fetch("expected_runs"))
    row = merged.fetch("anchors").find do |candidate|
      candidate.fetch("anchor_symbol") == request.dig("anchor", "symbol")
    end
    expect(row.dig("capture", "observed_executions"))
      .to eq(repeated.fetch("expected_count"))

    replacement = catalog.fetch("merge_cases").find do |candidate|
      candidate.fetch("id") == "changed_shard_replaces_owned_evidence"
    end
    replacement_run = replacement.fetch("expected_runs").fetch(0)
    replacement_events = @collector.fetch(:runtime_calls).map do |event|
      event.merge("run_id" => replacement_run)
    end
    replacement_path = NilKill::Runtime::ValueEvidenceEmitter.emit(
      root: NilKill::ROOT,
      runtime_dir: @collector.fetch(:runtime_dir),
      output: File.join(NilKill::TMP_DIR, "#{replacement_run}.json.gz"),
      events: replacement_events,
      run_ids: [replacement_run],
      plan: @collector.fetch(:plan)
    ).fetch("path")
    replaced = NilKill::Runtime::EvidenceMerger.merge([replacement_path])
    expect(replaced.fetch("runs").map { |run| run.fetch("id") })
      .to eq(replacement.fetch("expected_runs"))
    expect(replaced.fetch("runs").map { |run| run.fetch("id") })
      .not_to include(*replacement.fetch("forbidden_runs"))
  end

  it "collector output is accepted by FactMine's independent canonical validator" do
    binary = Espalier::StaticEvidence::FACT_MINE_RUST_BINARY
    plan_path = File.join(NilKill::TMP_DIR, "conformance-plan.json")
    FileUtils.mkdir_p(File.dirname(plan_path))
    File.write(plan_path, JSON.pretty_generate(@collector.fetch(:plan)))
    _stdout, stderr, status = Open3.capture3(
      binary,
      "runtime-evidence",
      "validate",
      "--plan",
      plan_path,
      "--evidence",
      @collector.fetch(:evidence_path)
    )
    expect(status).to be_success, stderr
  end

  it "end-to-end oracle: source, plan, real trace, validation, and FactMine join agree" do
    output = File.join(NilKill::TMP_DIR, "runtime-conformance.scip.json")
    FileUtils.mkdir_p(File.dirname(output))
    result = NilKill::Runtime::ScipEmitter.emit(
      root: NilKill::ROOT,
      runtime_dir: @collector.fetch(:runtime_dir),
      output: output,
      files: [@collector.fetch(:source), *@collector.fetch(:support)],
      value_evidence_path: @collector.fetch(:evidence_path),
      plan: @collector.fetch(:plan)
    )
    index = JSON.parse(File.read(result.fetch("index")))
    occurrences = index.fetch("documents").flat_map do |document|
      document.fetch("occurrences").map do |occurrence|
        [document.fetch("relativePath"), occurrence.fetch("range"), occurrence.fetch("symbol")]
      end
    end
    by_symbol = @collector.fetch(:evidence).fetch("anchors").to_h do |row|
      [row.fetch("anchor_symbol"), row]
    end

    catalog.fetch("cases").reject { |row| row.dig("expect", "correlation") }.each do |test_case|
      request = selected_request(@collector, test_case.fetch("anchor"))
      row = by_symbol.fetch(request.dig("anchor", "symbol"))
      next unless row.dig("capture", "status") == "COMPLETE_FOR_RUNS"

      target = row.dig("executions", 0, "target")
      next unless target

      anchor = request.fetch("anchor")
      range = anchor.fetch("range").values_at(
        "start_line",
        "start_character",
        "end_line",
        "end_character"
      )
      at_anchor = occurrences.select do |path, occurrence_range, _symbol|
        next false unless path == anchor.fetch("relative_path")

        occurrence_range =
          if occurrence_range.length == 3
            [
              occurrence_range[0],
              occurrence_range[1],
              occurrence_range[0],
              occurrence_range[2],
            ]
          else
            occurrence_range
          end
        start_before =
          occurrence_range[0] < range[0] ||
          (occurrence_range[0] == range[0] && occurrence_range[1] <= range[1])
        end_after =
          occurrence_range[2] > range[2] ||
          (occurrence_range[2] == range[2] && occurrence_range[3] >= range[3])
        start_before && end_after
      end
      if target.fetch("source_role") == "NON_PRODUCTION"
        expect(at_anchor.map(&:last)).not_to include(target.fetch("symbol")),
          "#{test_case.fetch("id")} published a test replacement as production SCIP"
      else
        expect(at_anchor.map(&:last)).to include(target.fetch("symbol")),
          "#{test_case.fetch("id")} was emitted correctly but FactMine did not join it; " \
          "target=#{target.fetch("symbol")} anchor=#{anchor} at_anchor=#{at_anchor} " \
          "same_path=#{occurrences.select { |path, _range, _symbol|
            path == anchor.fetch("relative_path")
          }}"
      end
    end
    expect(index.dig("_runtimeEvidence", "observedCallSites")).to be_positive
    expect(index.dig("_runtimeEvidence", "inferredCallSites")).to be_positive
  end
end
