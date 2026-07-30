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
    production_dir = File.join(dir, "production")
    source = catalog.fetch("fixture").fetch("source")
    lib(production_dir, fixture(source), File.basename(source))
    catalog.dig("fixture", "support").each do |support|
      relative = support.sub(%r{\Aruby/}, "")
      lib(dir, fixture(support), relative)
    end
    driver = fixture(catalog.fetch("fixture").fetch("driver"))
      .sub('require_relative "capabilities"', 'require_relative "production/capabilities"')
    result = mini_collect(
      dir,
      File.join("production", File.basename(source)),
      driver,
      runtime_scip: true,
      targets: production_dir
    )
    plan = JSON.parse(File.read(NilKill::TRACE_PLAN_PATH)).fetch("runtime_evidence")
    # The production collector restores the source snapshot after the traced
    # process. The mini harness intentionally leaves its throwaway source
    # wrapped for instrumentation assertions, so restore it here before the
    # end-to-end FactMine snapshot check.
    File.write(File.join(production_dir, File.basename(source)), fixture(source))
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
      source: File.join(production_dir, File.basename(source)),
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
    exact_symbols = events.filter_map do |event|
      symbol = event.dig("callsite", "anchor_symbol").to_s
      symbol unless symbol.empty?
    end.uniq
    unless exact_symbols.empty?
      exact = plan.fetch("requests").select do |request|
        exact_symbols.include?(request.dig("anchor", "symbol"))
      end
      return exact.sort_by do |request|
        range = request.fetch("anchor").fetch("range")
        [
          range.fetch("start_line"),
          range.fetch("start_character"),
          range.fetch("end_line"),
          range.fetch("end_character"),
        ]
      end
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
      }.map { |event| [event["caller"], event["callee"]] }}; " \
      "all events=#{raw_events.map { |event|
        [event.dig("caller", "method"), event.dig("callee", "name"), event.dig("callsite", "line")]
      }}"
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
    matches.fetch(anchor.fetch("occurrence").to_i - 1) do
      raise(
        "no planned occurrence #{anchor.fetch('occurrence')} for " \
        "#{anchor.fetch('method')}##{anchor.fetch('selector')}; " \
        "matching requests=#{matches.map { |request| request.fetch('anchor') }}"
      )
    end
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
      "exact-execution-range",
      "nested-receiver",
      "multiline-call",
      "nested-argument",
      "assignment",
      "destructuring",
      "short-circuit-assignment",
      "native-call",
      "generated-accessor",
      "anonymous-class",
      "transparent-wrapper",
      "callback",
      "yield",
      "block-parameter",
      "block-local",
      "dynamic-dispatch",
      "alternative-targets",
      "safe-navigation",
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
    expect(matrix.fetch("request_contracts").keys)
      .to contain_exactly(*matrix.fetch("anchor_kinds"))
    expect(matrix.fetch("request_contracts").values.flatten.uniq)
      .to match_array(matrix.fetch("evidence_kinds"))
    planned = matrix.fetch("planner_anchor_kinds")
    reserved = matrix.fetch("reserved_anchor_kinds")
    expect(planned & reserved.keys).to be_empty
    expect(planned | reserved.keys).to match_array(matrix.fetch("anchor_kinds"))
    expect(reserved.values).to all(satisfy { |reason| !reason.to_s.empty? })
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
        "evidence=#{JSON.generate(row)}\n" \
        "events=#{JSON.generate(@collector.fetch(:runtime_calls).select { |event|
          event.dig("caller", "method") == test_case.dig("anchor", "method")
        })}"
      complete_kinds =
        if expected_status == "COMPLETE_FOR_RUNS"
          request.fetch("required")
        else
          expected.fetch("complete_kinds", [])
        end
      if expected_status != "COMPLETE_FOR_RUNS"
        expect(row.dig("capture", "reason")).not_to be_empty
        expect(row.dig("capture", "complete_kinds"))
          .to contain_exactly(*complete_kinds)
        next if row.fetch("executions").empty?
      else
        expect(row.dig("capture", "complete_kinds")).to include(*complete_kinds)
      end
      if expected["observed_executions"]
        expect(row.dig("capture", "observed_executions"))
          .to(
            satisfy { |count| count.to_i == expected.fetch("observed_executions") },
            "#{test_case.fetch('id')} observed the wrong execution count"
          )
      end
      expect(row.fetch("executions")).not_to be_empty
      row.fetch("executions").each do |bucket|
        complete_kinds.each do |kind|
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
      if expected["receiver_types"]
        observed = row.fetch("executions").flat_map { |bucket| type_names(bucket["receiver"]) }
        expect(observed).to include(*expected.fetch("receiver_types"))
      end
      if expected["result_type"]
        expect(type_names(first["result"])).to include(expected.fetch("result_type"))
      end
      if expected["result_element_type"]
        elements = first.dig(
          "result", "alternatives", 0, "value", "sequence", "elements"
        )
        expect(type_names(elements)).to include(expected.fetch("result_element_type"))
      end
      if expected["result_shape"]
        expect(first.dig("result", "alternatives", 0, "value"))
          .to have_key(expected.fetch("result_shape"))
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
      if expected["target_owners"]
        observed = matching_raw.map { |event| event.dig("callee", "owner") }
        expect(observed).to include(*expected.fetch("target_owners"))
        observed_targets = row.fetch("executions").filter_map do |bucket|
          bucket["target"]
        end
        identities = observed_targets.map do |target|
          definition_anchor = target.dig("definition", "anchor_symbol").to_s
          if definition_anchor.empty?
            target.fetch("symbol")
          else
            expect(@collector.fetch(:plan).fetch("requests").any? do |candidate|
              candidate.dig("anchor", "symbol") == definition_anchor
            end).to be(true)
            definition_anchor
          end
        end
        expect(identities.uniq.length).to be >= expected.fetch("target_owners").length
      end
      if expected["excluded_target_owner"]
        excluded = expected.fetch("excluded_target_owner")
        excluded_raw = matching_raw.select do |event|
          event.dig("callee", "owner") == excluded
        end
        expect(excluded_raw).not_to be_empty,
          "#{test_case.fetch("id")} did not preserve its nonproduction replacement"
        expect(row.fetch("executions").filter_map { |bucket|
          bucket["target"] if bucket.dig("target", "source_role") == "NON_PRODUCTION"
        }).not_to be_empty
      end
      if expected["source_role"]
        expect(first.dig("target", "source_role")).to eq(expected.fetch("source_role")),
          "#{test_case.fetch('id')} attributed the target to the wrong source role: " \
          "#{JSON.generate(first)} raw=#{JSON.generate(matching_raw)}"
      end
      unless expected["boolean_result"].nil?
        expect(first.fetch("boolean_result")).to eq(expected.fetch("boolean_result"))
      end
    end
  end

  it "collector oracle: FactMine supplies every call's closed execution range" do
    catalog.fetch("cases").each do |test_case|
      request = selected_request(@collector, test_case.fetch("anchor"))
      selector = request.fetch("anchor").fetch("range")
      execution = request.fetch("execution_range")
      start_before = ([
        execution.fetch("start_line"),
        execution.fetch("start_character"),
      ] <=> [
        selector.fetch("start_line"),
        selector.fetch("start_character"),
      ]) <= 0
      end_after = ([
        execution.fetch("end_line"),
        execution.fetch("end_character"),
      ] <=> [
        selector.fetch("end_line"),
        selector.fetch("end_character"),
      ]) >= 0
      expect(start_before && end_after).to be(true), test_case.fetch("id")
      next unless (
        test_case.fetch("capabilities") &
          %w[attached-block-range nested-attached-blocks]
      ).any?

      expect(([
        execution.fetch("end_line"),
        execution.fetch("end_character"),
      ] <=> [
        selector.fetch("end_line"),
        selector.fetch("end_character"),
      ])).to be_positive
    end
  end

  it "collector oracle: exact execution ranges disambiguate same-line calls" do
    test_cases = catalog.fetch("cases").select do |row|
      row.fetch("capabilities").include?("ambiguous-anchor")
    end
    requests = test_cases.map { |test_case| selected_request(@collector, test_case.fetch("anchor")) }
    symbols = requests.map { |request| request.dig("anchor", "symbol") }.sort
    rows = @collector.fetch(:evidence).fetch("anchors").select do |row|
      symbols.include?(row.fetch("anchor_symbol"))
    end
    expect(symbols.length).to eq(2)
    expect(rows.map { |row| row.dig("capture", "status") })
      .to contain_exactly("COMPLETE_FOR_RUNS", "COMPLETE_FOR_RUNS")
    expect(rows.map { |row| row.fetch("executions").length }).to eq([1, 1])
    expect(@collector.fetch(:evidence).fetch("correlations").none? do |row|
      row.fetch("candidate_anchor_symbols") == symbols
    end).to be(true)
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
        if expected_status == "NOT_EXECUTED"
          expect(row.dig("capture", "complete_kinds"))
            .to include(boundary.fetch("evidence_kind"))
        else
          expect(row.dig("capture", "complete_kinds")).to be_empty
        end
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

    mixed_case = catalog.fetch("cases").find do |candidate|
      candidate.fetch("id") == "direct_subprocess_result_with_anonymous_replacement"
    end
    mixed_request = selected_request(@collector, mixed_case.fetch("anchor"))
    mixed_events = @collector.fetch(:runtime_calls).select do |event|
      event.dig("caller", "method") == "direct_capture_status" &&
        event.dig("callee", "name") == "success?"
    end
    production, replacement = mixed_events.partition do |event|
      event.dig("callee", "owner") == "Process::Status"
    end
    expect(production).not_to be_empty
    expect(replacement).not_to be_empty
    split_paths = [
      ["production-run", production],
      ["replacement-run", replacement],
    ].map do |run_id, shard_events|
      NilKill::Runtime::ValueEvidenceEmitter.emit(
        root: NilKill::ROOT,
        runtime_dir: @collector.fetch(:runtime_dir),
        output: File.join(NilKill::TMP_DIR, "#{run_id}.json.gz"),
        events: shard_events.map { |event| event.merge("run_id" => run_id) },
        run_ids: [run_id],
        plan: @collector.fetch(:plan)
      ).fetch("path")
    end
    split = NilKill::Runtime::EvidenceMerger.merge(split_paths)
    split_contract = catalog.fetch("merge_cases").find do |candidate|
      candidate.fetch("id") == "production_and_replacement_shards_remain_complete"
    end
    expect(split.fetch("runs").map { |run| run.fetch("id") })
      .to eq(split_contract.fetch("expected_runs"))
    split_row = split.fetch("anchors").find do |candidate|
      candidate.fetch("anchor_symbol") == mixed_request.dig("anchor", "symbol")
    end
    expect(split_row.dig("capture", "status")).to eq("COMPLETE_FOR_RUNS")
    expect(split_row.fetch("executions").map { |bucket|
      bucket.dig("target", "source_role")
    }).to contain_exactly(*split_contract.fetch("expected_source_roles"))

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
      if test_case.dig("expect", "excluded_target_owner")
        excluded_suffix = test_case.dig("expect", "excluded_target_owner")
          .gsub("::", "/")
        expect(at_anchor.map(&:last).none? { |symbol|
          symbol.include?(excluded_suffix)
        }).to be(true),
          "#{test_case.fetch("id")} published a nonproduction replacement at the callsite"
      end
    end
    expect(index.dig("_runtimeEvidence", "observedCallSites")).to be_positive
    expect(index.dig("_runtimeEvidence", "inferredCallSites")).to be_positive
  end
end
