# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe NilKill::TracePlan do
  def plan_entry(method)
    tp = described_class.allocate
    tp.instance_variable_set(:@methods, {})
    tp.send(:add_method, method)
    tp.instance_variable_get(:@methods).values.first
  end

  def static_plan_entry(method)
    tp = described_class.allocate
    tp.instance_variable_set(:@methods, {})
    tp.send(:add_static_method, method)
    tp.instance_variable_get(:@methods).values.first
  end

  # The dangerous regression this whole investigation chased: if
  # TracePlan ever prunes a method that HAS a typeable (untyped
  # positional) slot, that method silently gets no runtime record and
  # inflates NoEvidence with a method that actually ran. Guard it.
  it "samples a method whose positional param is T.untyped (must not be pruned)" do
    e = plan_entry(
      "class" => "C", "method" => "run", "kind" => "instance", "line" => 1,
      "path" => "src/c.rb",
      "sig" => "sig { params(x: T.untyped).returns(String) }",
      "params" => [{ "name" => "x", "type" => "T.untyped" }]
    )
    expect(e["sample"]).to be(true)
    expect(e["frame"]).to be(true)
  end

  it "samples a method whose return is T.untyped even if params are typed" do
    e = plan_entry(
      "class" => "C", "method" => "calc", "kind" => "instance", "line" => 1,
      "path" => "src/c.rb",
      "sig" => "sig { params(x: Integer).returns(T.untyped) }",
      "params" => [{ "name" => "x", "type" => "Integer" }]
    )
    expect(e["sample"]).to be(true)
    expect(e["frame"]).to be(true)
  end

  it "prunes a method that is fully typed (nothing to learn) -- expected, not a bug" do
    e = plan_entry(
      "class" => "C", "method" => "typed", "kind" => "instance", "line" => 1,
      "path" => "src/c.rb",
      "sig" => "sig { params(x: Integer).returns(String) }",
      "params" => [{ "name" => "x", "type" => "Integer" }]
    )
    expect(e["sample"]).to be(false)
    expect(e["frame"]).to be(false)
  end

  it "prunes the block-form sig { void } spelling" do
    entry = static_plan_entry(
      "owner" => "Scope::Bindings",
      "name" => "initialize",
      "kind" => "class",
      "line" => 8,
      "path" => "src/scope.rb",
      "signature" => "sig { void }",
      "params" => []
    )

    expect(entry).to include("sample" => false, "frame" => false, "return" => false)
  end

  it "prunes a method whose ONLY untyped slot is a block param (block is ~always Proc; acceptable). The report must label such a slot arg_untraced, not never_run." do
    e = plan_entry(
      "class" => "C", "method" => "suffix", "kind" => "instance", "line" => 1,
      "path" => "src/c.rb",
      # StaticAnalysis omits the block param from `params`, so only the
      # typed positionals are seen -> sample=false (pruned, no record).
      "sig" => "sig { params(type: Symbol, value: String, block: T.untyped).returns(Prism::Token) }",
      "params" => [{ "name" => "type", "type" => "Symbol" }, { "name" => "value", "type" => "String" }]
    )
    expect(e["sample"]).to be(false)
    expect(e["frame"]).to be(false)
  end

  it "uses T.let facts to prune resolved ivars without pruning unresolved ivars" do
    plan = described_class.new
    path = File.expand_path("src/worker.rb", NilKill::ROOT)
    tlets = {
      [path, 5] => "String",
      [path, 6] => "T.untyped",
    }

    plan.send(:add_static_field, { "owner" => "Worker", "name" => "resolved", "path" => path, "line" => 5 }, tlets)
    plan.send(:add_static_field, { "owner" => "Worker", "name" => "unresolved", "path" => path, "line" => 6 }, tlets)

    fields = plan.instance_variable_get(:@struct_fields)
    expect(fields[["Worker", "resolved"].join("\0")]).to be(false)
    expect(fields[["Worker", "unresolved"].join("\0")]).to be(true)
  end

  it "carries final strong field decisions back to exact state-write sites" do
    plan = described_class.new
    path = File.expand_path("src/parser.rb", NilKill::ROOT)
    plan.send(:add_static_field, {
      "owner" => "Parser", "name" => "pos", "path" => path, "line" => 12
    }, {})
    plan.send(:add_static_type_definition, {
      "kind" => "state_field", "owner" => "Parser", "name" => "pos",
      "declared_type" => "Integer"
    })

    sites = plan.send(:state_write_sites)
    expect(sites[[path, 12, "pos"].join("\0")]).to be(false)
  end

  it "lets a strong field declaration override conservative flow records" do
    plan = described_class.new
    plan.send(:add_static_state_type, {
      "owner" => "TypeShape::GenericParts",
      "field" => "generic_args_raw",
      "declared_type" => "T::Array[T.untyped]"
    })
    plan.send(:add_static_type_definition, {
      "kind" => "state_field",
      "owner" => "TypeShape::GenericParts",
      "name" => "generic_args_raw",
      "declared_type" => "T::Array[Symbol]"
    })

    fields = plan.instance_variable_get(:@struct_fields)
    expect(fields[["TypeShape::GenericParts", "generic_args_raw"].join("\0")]).to be(false)
  end

  it "keeps weak declared fields sampled" do
    plan = described_class.new
    plan.send(:add_static_type_definition, {
      "kind" => "state_field",
      "owner" => "Payload",
      "name" => "values",
      "declared_type" => "T::Array[T.untyped]"
    })

    fields = plan.instance_variable_get(:@struct_fields)
    expect(fields[["Payload", "values"].join("\0")]).to be(true)
  end

  it "uses declared Struct/Data field types and samples undeclared types" do
    plan = described_class.new
    plan.send(:add_struct_decl, {
      "class" => "Payload",
      "fields" => %w[name metadata unknown],
      "field_types" => {
        "name" => "String",
        "metadata" => "T::Hash[Symbol, T.untyped]",
      },
    })

    fields = plan.instance_variable_get(:@struct_fields)
    expect(fields[["Payload", "name"].join("\0")]).to be(false)
    expect(fields[["Payload", "metadata"].join("\0")]).to be(true)
    expect(fields[["Payload", "unknown"].join("\0")]).to be(true)
  end

  it "builds its purpose-specific evidence without full CFG/DFG facts" do
    Dir.mktmpdir("nil-kill-trace-plan-profile", NilKill::ROOT) do |dir|
      path = File.join(dir, "worker.rb")
      File.write(path, <<~RUBY)
        class Worker
          class MutableState < T::Struct
            prop :items, T::Array[String], factory: -> { [] }
          end

          Payload = Data.define(:name, :metadata)
          sig { params(value: T.untyped).returns(T.untyped) }
          def call(value)
            @items = T.let([], T::Array[String])
            value
          end
        end
      RUBY

      evidence = NilKill::StaticEvidence.build_trace_plan([path], root: dir)

      expect(evidence.fetch("methods").map { |method| method["name"] }).to include("call")
      expect(evidence.fetch("facts").keys).to match_array(NilKill::StaticEvidence::TRACE_PLAN_FACT_KEYS)
      expect(evidence.dig("facts", "tlet_sites")).to include(a_hash_including(
        "type" => "T::Array[String]"
      ))
      expect(evidence.dig("facts", "struct_declarations")).to include(a_hash_including(
        "class" => "Worker::Payload",
        "fields" => %w[name metadata]
      ))
      expect(evidence.dig("facts", "struct_declarations")).to include(a_hash_including(
        "class" => "MutableState",
        "fields" => %w[items],
        "field_types" => { "items" => "T::Array[String]" }
      ))
      expect(evidence.dig("facts", "state_type_records")).to include(a_hash_including(
        "owner" => "Worker",
        "field" => "items",
        "declared_type" => "T::Array[String]"
      ))
      expect(evidence.dig("facts", "flow_local_types")).to be_nil
    end
  end
end
