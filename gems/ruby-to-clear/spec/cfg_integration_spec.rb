# frozen_string_literal: true

require "spec_helper"
require "json"
require "open3"
require "tmpdir"

RSpec.describe "FactMine CFG integration" do
  def fact_mine_binary
    root = File.expand_path("../../..", __dir__)
    [
      ENV["FACT_MINE_RUST_BINARY"],
      File.join(root, "gems/fact-mine/target/release/fact-mine-rust"),
      File.join(root, "gems/fact-mine/target/debug/fact-mine-rust")
    ].compact.find { |path| File.file?(path) && File.executable?(path) }
  end

  it "admits complete real CFG/dataflow facts and uses them for ownership" do
    binary = fact_mine_binary
    skip "build fact-mine-rust or set FACT_MINE_RUST_BINARY to run this contract test" unless binary

    source = <<~RUBY
      def choose(x)
        return 0 unless x
        x
      end

      def take
        a = [1]
        b = a
        return b
        a
      end
    RUBY

    Dir.mktmpdir do |dir|
      source_path = File.join(dir, "cfg_contract.rb")
      facts_path = File.join(dir, "cfg_contract.json")
      File.write(source_path, source)

      stdout, stderr, status = Open3.capture3(
        binary, "syntax-facts", "--language", "ruby", source_path
      )
      expect(status).to be_success, stderr
      File.write(facts_path, stdout)

      payload = JSON.parse(stdout)
      document = payload.fetch("documents").one? && payload.fetch("documents").first
      node_ids = document.fetch("control_flow_nodes").map { |node| node.fetch("id") }.sort
      expect(document.fetch("node_effects").map { |fact| fact.fetch("node_id") }.sort).to eq(node_ids)
      expect(document.fetch("node_effects")).to all(include("complete" => true))
      expect(document.fetch("liveness").map { |fact| fact.fetch("node_id") }.sort).to eq(node_ids)

      root = Prism.parse(source).value
      transpiler = RubyToClear::Transpiler.new(
        source, source_path: source_path, cfg_facts_path: facts_path
      )
      transpiler.transpile(root)

      functions = transpiler.typed_ir.functions.values.to_h { |function| [function.symbol.name, function] }
      expect(functions.fetch("choose").facts.complete).to be(true)
      expect(functions.fetch("take").facts.complete).to be(true)

      take_node = root.statements.body.find { |node| node.name == :take }
      assignment = take_node.body.body[1]
      expect(transpiler.typed_ir.storage_ownership_for(assignment).mode).to eq(:move)
    end
  end

  it "uses real liveness facts to retain a live Ruby identity and move its last use" do
    binary = fact_mine_binary
    skip "build fact-mine-rust or set FACT_MINE_RUST_BINARY to run this contract test" unless binary

    source = <<~RUBY
      class Item
        def initialize
          @name = T.let("item", String)
        end
      end

      sig { returns(Item) }
      def fan_out
        item = Item.new
        other = item
        item.to_s
        other
      end

      sig { returns(Item) }
      def move_last
        item = Item.new
        other = item
        other
      end
    RUBY

    Dir.mktmpdir do |dir|
      source_path = File.join(dir, "identity_liveness.rb")
      facts_path = File.join(dir, "identity_liveness.json")
      File.write(source_path, source)
      stdout, stderr, status = Open3.capture3(
        binary, "syntax-facts", "--language", "ruby", source_path
      )
      expect(status).to be_success, stderr
      File.write(facts_path, stdout)

      root = Prism.parse(source).value
      transpiler = RubyToClear::Transpiler.new(
        source, source_path: source_path, cfg_facts_path: facts_path
      )
      clear = transpiler.transpile(root)

      assignments = root.statements.body.grep(Prism::DefNode).to_h do |function|
        [function.name, function.body.body[1]]
      end
      expect(transpiler.typed_ir.storage_ownership_for(assignments.fetch(:fan_out)).mode).to eq(:retain)
      expect(transpiler.typed_ir.storage_ownership_for(assignments.fetch(:move_last)).mode).to eq(:move)
      expect(clear).to include("MUTABLE other: Item@multiowned = KEEP item;")
      expect(clear).to include("MUTABLE other = item;")
      expect(transpiler.typed_ir.analysis_report.dig("aggregate", "cfg_consumption"))
        .to include("liveness_ownership" => 2)
    end
  end

  it "does not let CFG identity facts turn a borrowed union projection into an owned local" do
    binary = fact_mine_binary
    skip "build fact-mine-rust or set FACT_MINE_RUST_BINARY to run this contract test" unless binary

    source = <<~RUBY
      class Signature
        LifetimeSource = T.type_alias { T.any(String, Symbol) }
        LifetimeInput = T.type_alias { T.nilable(T.any(LifetimeSource, T::Array[LifetimeSource])) }

        sig { params(val: LifetimeInput).returns(T::Array[LifetimeSource]) }
        def normalize(val)
          return [] if val.nil?
          raw = T.let([], T::Array[LifetimeSource])
          if val.is_a?(Array)
            raw = val
          else
            raw = [val]
          end
          out = T.let([], T::Array[LifetimeSource])
          i = T.let(0, Integer)
          while i < raw.length
            item = raw.fetch(i)
            if item.is_a?(Symbol)
              out << item.to_s
            else
              out << item
            end
            i += 1
          end
          out
        end
      end
    RUBY

    Dir.mktmpdir do |dir|
      source_path = File.join(dir, "borrowed_union_projection.rb")
      facts_path = File.join(dir, "borrowed_union_projection.json")
      File.write(source_path, source)
      stdout, stderr, status = Open3.capture3(
        binary, "syntax-facts", "--language", "ruby", source_path
      )
      expect(status).to be_success, stderr
      File.write(facts_path, stdout)

      root = Prism.parse(source).value
      transpiler = RubyToClear::Transpiler.new(
        source, source_path: source_path, cfg_facts_path: facts_path
      )
      clear = transpiler.transpile(root)

      function = root.statements.body.first.body.body.grep(Prism::DefNode).first
      loop_node = function.body.body.grep(Prism::WhileNode).first
      item_write = loop_node.statements.body.grep(Prism::LocalVariableWriteNode).first
      source_info = transpiler.typed_ir.value_for(item_write.value)
      expect(source_info.access).to eq(:borrowed)

      expect(clear).to include("MUTABLE item = COPY UNWRAP (raw[i]);")
      expect(clear).to include("&out.append(item);")
    end
  end

  it "admits every maintained Ruby CFG fixture through Prism identity" do
    binary = fact_mine_binary
    skip "build fact-mine-rust or set FACT_MINE_RUST_BINARY to run this contract test" unless binary

    root = File.expand_path("../../..", __dir__)
    fixtures = Dir[File.join(root, "gems/fact-mine/examples/syntax-facts/ruby/cfg_*.rb")].sort
    stdout, stderr, status = Open3.capture3(
      binary, "syntax-facts", "--language", "ruby", *fixtures
    )
    expect(status).to be_success, stderr

    Dir.mktmpdir do |dir|
      facts_path = File.join(dir, "ruby-cfg-fixtures.json")
      File.write(facts_path, stdout)
      failures = []

      fixtures.each do |source_path|
        source = File.read(source_path)
        root_node = Prism.parse(source).value
        class_node = root_node.statements.body.first
        owner = class_node.constant_path.location.slice
        functions = class_node.body.body.grep(Prism::DefNode)
        bundle = RubyToClear::TypedIR::CfgFacts::Bundle.load(
          source: source, source_path: source_path, facts_path: facts_path
        )

        expect(functions).not_to be_empty
        functions.each do |function|
          admission = bundle.admit_function(function, owner: owner)
          next if admission.complete

          failures << "#{File.basename(source_path)} #{owner}##{function.name}: #{admission.reason}"
        end
      end
      expect(failures).to be_empty, failures.join("\n")
    end
  end


  it "uses real Ruby alias and escape facts to materialize a borrowed return" do
    binary = fact_mine_binary
    skip "build fact-mine-rust or set FACT_MINE_RUST_BINARY to run this contract test" unless binary

    source = <<~RUBY
      class Inventory
        extend T::Sig

        sig { params(items: T::Array[String]).void }
        def initialize(items)
          @items = items
        end

        sig { returns(T::Array[String]) }
        def borrowed
          items = T.let(@items, T::Array[String])
          return items
        end

        sig { returns(T::Array[String]) }
        def copied
          copy = @items.dup
          return copy
        end
      end
    RUBY

    Dir.mktmpdir do |dir|
      source_path = File.join(dir, "alias_contract.rb")
      facts_path = File.join(dir, "alias_contract.json")
      File.write(source_path, source)
      stdout, stderr, status = Open3.capture3(
        binary, "syntax-facts", "--language", "ruby", source_path
      )
      expect(status).to be_success, stderr
      File.write(facts_path, stdout)

      document = JSON.parse(stdout).fetch("documents").first
      expect(document.fetch("aliases")).to include(
        include("function" => "borrowed", "relationship" => "must", "complete" => true)
      )
      expect(document.fetch("allocations")).to include(
        include("function" => "copied", "kind" => "copy", "fresh" => true)
      )
      expect(document.fetch("escapes")).to include(
        include("function" => "borrowed", "sink" => "return", "complete" => true),
        include("function" => "copied", "sink" => "return", "complete" => true)
      )

      root = Prism.parse(source).value
      transpiler = RubyToClear::Transpiler.new(
        source, source_path: source_path, cfg_facts_path: facts_path
      )
      clear = transpiler.transpile(root)

      expect(clear).to include("MUTABLE items: []String = COPY rtoc_self_view.items;")
      expect(clear).to include("RETURN items")
      expect(clear).to include("RETURN copy")
      expect(clear).not_to include("RETURN COPY copy")
      consumption = transpiler.typed_ir.analysis_report.dig("aggregate", "cfg_consumption")
      ownership_fact_reads = consumption.fetch("alias_ownership", 0) +
        consumption.fetch("reaching_definition_ownership", 0)
      expect(ownership_fact_reads).to be >= 2
      expect(consumption).to include("escape_ownership" => 2)
    end
  end
end
