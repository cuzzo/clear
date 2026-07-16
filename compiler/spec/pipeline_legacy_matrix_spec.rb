require "rspec"
require "stringio"
require_relative "../ruby/mir/mir" unless defined?(MIR::StdlibDefFsCoercion)
require_relative "../ruby/mir/mir_lowering" unless defined?(MIRLowering::OwnershipSurfaceScan)
require_relative "../ruby/ast/std_lib" unless defined?(StdLibTypeBinding)
require_relative "../ruby/compiler/module_importer" unless defined?(ModuleImporter)
require_relative "../ruby/compiler/compiler_frontend" unless defined?(CompilerFrontend)

RSpec.describe "pipeline legacy matrix" do
  EXPECTED_CONCURRENT_STRUCTURAL_HITS = {}.freeze
  EXPECTED_INVALID_CASES = {}.freeze
  STRUCTURALIZED_OBSERVABLE_INLINE_REASONS = %w[
    obs_alloc
    obs_wg_init
    obs_set_completion
    obs_distinct_publish
  ].freeze

  def compile_and_lower(src)
    importer = ModuleImporter.new(base_dir: Dir.pwd, use_mir: true)
    result = nil
    begin
      old_stdout = $stdout
      old_stderr = $stderr
      $stdout = StringIO.new
      $stderr = StringIO.new
      result = CompilerFrontend.compile(src, importer: importer, source_dir: Dir.pwd)
    ensure
      $stdout = old_stdout
      $stderr = old_stderr
    end

    MIRLowering.new(input: MIRLoweringInput.new(
      struct_schemas: result.struct_schemas,
      enum_schemas: result.enum_schemas,
      union_schemas: result.union_schemas,
      fn_sigs: result.fn_sigs,
      moved_guard_info: result.moved_guard_info,
      importer: importer,
      source_dir: Dir.pwd,
      target: :zig
    )).lower_program(result.ast)
  end

  def collect_structural_pipeline_reasons(root)
    seen = {}
    reasons = []
    visit = nil
    visit = lambda do |obj|
      return if obj.nil?
      if obj.is_a?(Array)
        obj.each { |v| visit.call(v) }
        return
      end
      if obj.is_a?(Hash)
        obj.each { |k, v| visit.call(k); visit.call(v) }
        return
      end
      return unless obj.class.name&.start_with?("MIR::")
      oid = obj.object_id
      return if seen[oid]
      seen[oid] = true
      reasons << obj.reason.to_s if obj.is_a?(MIR::RegistryCall)
      reasons << "obs_consumer_spawn" if obj.is_a?(MIR::ObservableConsumerSpawn)
      obj.each_pair { |_name, value| visit.call(value) } if obj.respond_to?(:each_pair)
      obj.instance_variables.each { |ivar| visit.call(obj.instance_variable_get(ivar)) }
    end
    visit.call(root)
    reasons
  end

  SOURCE_SETUPS = {
    "array:item" => <<~CLEAR,
      items = [
        Item{ value: 1.0, other: 10.0, id: 1_i64 },
        Item{ value: 2.0, other: 20.0, id: 2_i64 },
        Item{ value: 3.0, other: 30.0, id: 3_i64 },
      ];
    CLEAR
    "list:item" => <<~CLEAR,
      MUTABLE items: []Item = [];
      items.append(Item{ value: 1.0, other: 10.0, id: 1_i64 });
      items.append(Item{ value: 2.0, other: 20.0, id: 2_i64 });
      items.append(Item{ value: 3.0, other: 30.0, id: 3_i64 });
    CLEAR
    "pool:item" => <<~CLEAR,
      MUTABLE items: [Pool(16)]Item = [];
      items.insert(Item{ value: 1.0, other: 10.0, id: 1_i64 });
      items.insert(Item{ value: 2.0, other: 20.0, id: 2_i64 });
      items.insert(Item{ value: 3.0, other: 30.0, id: 3_i64 });
    CLEAR
    "soa-list:item" => <<~CLEAR,
      MUTABLE items: []@soa Item = [];
      items.append(Item{ value: 1.0, other: 10.0, id: 1_i64 });
      items.append(Item{ value: 2.0, other: 20.0, id: 2_i64 });
      items.append(Item{ value: 3.0, other: 30.0, id: 3_i64 });
    CLEAR
    "soa-pool:item" => <<~CLEAR,
      MUTABLE items: [Pool(16)]@soa Item = [];
      items.insert(Item{ value: 1.0, other: 10.0, id: 1_i64 });
      items.insert(Item{ value: 2.0, other: 20.0, id: 2_i64 });
      items.insert(Item{ value: 3.0, other: 30.0, id: 3_i64 });
    CLEAR
    "sharded-list:item" => <<~CLEAR,
      MUTABLE items: []@sharded(2) Item = [];
      items.append(Item{ value: 1.0, other: 10.0, id: 1_i64 });
      items.append(Item{ value: 2.0, other: 20.0, id: 2_i64 });
      items.append(Item{ value: 3.0, other: 30.0, id: 3_i64 });
    CLEAR
    "sharded-pool:item" => <<~CLEAR,
      MUTABLE items: [Pool(16)]@sharded(2) Item = [];
      items.insert(Item{ value: 1.0, other: 10.0, id: 1_i64 });
      items.insert(Item{ value: 2.0, other: 20.0, id: 2_i64 });
      items.insert(Item{ value: 3.0, other: 30.0, id: 3_i64 });
    CLEAR
    "set:int" => <<~CLEAR,
      MUTABLE items: [Set]Int64 = Set[];
      items.insert(1_i64);
      items.insert(2_i64);
      items.insert(3_i64);
    CLEAR
  }.freeze

  ITEM_PIPELINES = {
    "sum" => "out = items |> SUM _.value;",
    "count" => "out = items |> COUNT _.value > 1.0;",
    "any" => "out = items |> ANY _.value > 2.0;",
    "all" => "out = items |> ALL _.value > 0.0;",
    "min" => "out = items |> MIN _.value;",
    "max" => "out = items |> MAX _.value;",
    "average" => "out = items |> AVERAGE _.value;",
    "find" => "out = items |> FIND _.id == 2_i64;",
    "where" => "out = items |> WHERE _.value > 1.0;",
    "select" => "out = items |> SELECT _.value + 1.0;",
    "take_while" => "out = items |> TAKE_WHILE _.value < 3.0;",
    "limit" => "out = items |> LIMIT 2;",
    "skip" => "out = items |> SKIP 1;",
    "distinct" => "out = items |> DISTINCT _.id;",
    "order_by" => "out = items |> ORDER_BY _.value;",
    "index" => "out = items |> INDEX _.id;",
    "reduce" => "out = items |> REDUCE(0.0) acc + _.value;",
    "tap" => "out = items |> TAP { _.value + 0.0; };",
    "each" => "items |> EACH { _.value = _.value + 1.0; };",
    "window" => "out = items |> WINDOW(2) _.length();",
    "batch_window" => "out = items |> WINDOW(size: 2) _.length();",
    "concurrent_select" => "out = items |> CONCURRENT(workers: 2) SELECT _.value;",
    "concurrent_where" => "out = items |> CONCURRENT(workers: 2) WHERE _.value > 1.0;",
    "concurrent_each" => "items |> CONCURRENT(workers: 2) EACH { _.value = _.value + 1.0; };",
    "concurrent_count" => "out = items |> CONCURRENT(workers: 2) COUNT _.value > 1.0;",
    "concurrent_sum" => "out = items |> CONCURRENT(workers: 2) SUM _.value;",
    "concurrent_average" => "out = items |> CONCURRENT(workers: 2) AVERAGE _.value;",
    "concurrent_min" => "out = items |> CONCURRENT(workers: 2) MIN _.value;",
    "concurrent_max" => "out = items |> CONCURRENT(workers: 2) MAX _.value;",
  }.freeze

  INT_PIPELINES = {
    "sum" => "out = items |> SUM _;",
    "count" => "out = items |> COUNT _ > 1_i64;",
    "any" => "out = items |> ANY _ > 2_i64;",
    "all" => "out = items |> ALL _ > 0_i64;",
    "min" => "out = items |> MIN _;",
    "max" => "out = items |> MAX _;",
    "average" => "out = items |> AVERAGE _;",
    "where" => "out = items |> WHERE _ > 1_i64;",
    "select" => "out = items |> SELECT _ + 1_i64;",
    "take_while" => "out = items |> TAKE_WHILE _ < 3_i64;",
    "limit" => "out = items |> LIMIT 2;",
    "skip" => "out = items |> SKIP 1;",
    "distinct" => "out = items |> DISTINCT _;",
    "order_by" => "out = items |> ORDER_BY _;",
    "reduce" => "out = items |> REDUCE(0_i64) acc + _;",
    "tap" => "out = items |> TAP { _ + 0_i64; };",
    "each" => "items |> EACH { seen = seen + _; };",
  }.freeze

  RANGE_PIPELINES = {
    "sum" => "out = (1..<4) |> SUM _;",
    "count" => "out = (1..<4) |> COUNT _ > 1_i64;",
    "any" => "out = (1..<4) |> ANY _ > 2_i64;",
    "all" => "out = (1..<4) |> ALL _ > 0_i64;",
    "min" => "out = (1..<4) |> MIN _;",
    "max" => "out = (1..<4) |> MAX _;",
    "average" => "out = (1..<4) |> AVERAGE _;",
    "where_sum" => "out = (1..<4) |> WHERE _ > 1_i64 |> SUM _;",
    "select_sum" => "out = (1..<4) |> SELECT _ + 1_i64 |> SUM _;",
    "each" => "(1..<4) |> EACH { seen = seen + _; };",
    "concurrent_select" => "out = (1..<4) |> CONCURRENT(workers: 2) SELECT _;",
    "concurrent_where" => "out = (1..<4) |> CONCURRENT(workers: 2) WHERE _ > 1_i64;",
    "concurrent_each" => "(1..<4) |> CONCURRENT(workers: 2) EACH { seen = seen + _; };",
    "concurrent_count" => "out = (1..<4) |> CONCURRENT(workers: 2) COUNT _ > 1_i64;",
    "concurrent_sum" => "out = (1..<4) |> CONCURRENT(workers: 2) SUM _;",
    "concurrent_average" => "out = (1..<4) |> CONCURRENT(workers: 2) AVERAGE _;",
    "concurrent_min" => "out = (1..<4) |> CONCURRENT(workers: 2) MIN _;",
    "concurrent_max" => "out = (1..<4) |> CONCURRENT(workers: 2) MAX _;",
  }.freeze

  def program(setup, pipeline)
    <<~CLEAR
      STRUCT Item { value: Float64, other: Float64, id: Int64 }

      FN main() RETURNS Void ->
        MUTABLE seen = 0_i64;
        #{setup}
        #{pipeline}
        RETURN;
      END
    CLEAR
  end

  def observable_program(binding_line)
    <<~CLEAR
      FN main() RETURNS Void ->
        gen: ~?Int64[] = BG STREAM {
          MUTABLE i: Int64 = 0_i64;
          WHILE i < 4_i64 DO YIELD i; i = i + 1_i64; END
        };
        #{binding_line}
        final = NEXT running;
        RETURN;
      END
    CLEAR
  end

  def matrix_cases
    cases = []
    SOURCE_SETUPS.each do |source_name, setup|
      pipelines = source_name == "set:int" ? INT_PIPELINES : ITEM_PIPELINES
      pipelines.each do |op_name, pipe|
        cases << ["#{source_name} |> #{op_name}", program(setup, pipe)]
      end
    end
    RANGE_PIPELINES.each do |op_name, pipe|
      cases << ["range |> #{op_name}", program("", pipe)]
    end
    cases << [
      "list:item |> join",
      program(SOURCE_SETUPS.fetch("list:item") + <<~CLEAR, "out = items |> JOIN(otherItems) %(a, b) -> a.id == b.id;")
        otherItems = [
          OtherItem{ id: 1_i64 },
          OtherItem{ id: 3_i64 },
        ];
      CLEAR
        .sub("STRUCT Item { value: Float64, other: Float64, id: Int64 }",
             "STRUCT Item { value: Float64, other: Float64, id: Int64 }\nSTRUCT OtherItem { id: Int64 }")
    ]
    cases
  end

  it "reports pipeline shapes that still lower through legacy opaque inline paths" do
    pipeline_legacy_hits = {}
    concurrent_structural_hits = {}
    invalid = {}

    matrix_cases.each do |name, src|
      begin
        reasons = collect_structural_pipeline_reasons(compile_and_lower(src))
        pipeline_reasons = reasons.select { |r| r == "pipeline_legacy_host" }
        concurrent_reasons = reasons.select { |r| r.start_with?("concurrent_") }
        pipeline_legacy_hits[name] = pipeline_reasons.uniq unless pipeline_reasons.empty?
        concurrent_structural_hits[name] = concurrent_reasons.uniq unless concurrent_reasons.empty?
      rescue StandardError => e
        invalid[name] = "#{e.class}: #{e.message.lines.first&.strip}"
      end
    end

    warn "\nPipeline legacy host hits:\n#{pipeline_legacy_hits.map { |k, v| "  #{k}: #{v.join(', ')}" }.join("\n")}"
    warn "\nConcurrent structural registry hits:\n#{concurrent_structural_hits.map { |k, v| "  #{k}: #{v.join(', ')}" }.join("\n")}"
    warn "\nPipeline legacy matrix invalid cases:\n#{invalid.map { |k, v| "  #{k}: #{v}" }.join("\n")}" unless invalid.empty?

    expect(invalid.keys.sort).to eq(EXPECTED_INVALID_CASES.keys.sort)
    EXPECTED_INVALID_CASES.each do |name, pattern|
      expect(invalid.fetch(name)).to match(pattern)
    end
    expect(pipeline_legacy_hits).to eq({})
    expect(concurrent_structural_hits).to eq(EXPECTED_CONCURRENT_STRUCTURAL_HITS)
  end

  it "keeps observable wiring on structural spawn nodes" do
    cases = {
      "sum" => observable_program("running: ~Int64@observable = gen |> SUM _;"),
      "distinct" => observable_program("running: ~Int64[]@set:observable = gen |> DISTINCT _;"),
      "reduce" => observable_program("running: ~Int64@observable = gen |> REDUCE(0_i64) acc + _;"),
    }

    reasons_by_case = cases.transform_values { |src| collect_structural_pipeline_reasons(compile_and_lower(src)) }

    reasons_by_case.each_value do |reasons|
      expect(reasons & STRUCTURALIZED_OBSERVABLE_INLINE_REASONS).to eq([])
      expect(reasons.select { |reason| reason.start_with?("obs_") }.uniq).to eq(["obs_consumer_spawn"])
    end
  end
end
