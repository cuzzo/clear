# frozen_string_literal: true

require_relative "spec_helper"
require_relative "../lib/nil_kill/tree_sitter_adapter"

RSpec.describe NilKill::TreeSitterAdapter do
  def parse_first_statement(code)
    context = NilKill::TreeSitterAdapter.parse(code)
    context.value.statements.child_nodes.first
  end

  it "handles unary operators" do
    node = parse_first_statement("-x")
    expect(node).to be_a(NilKill::TreeSitterAdapter::CallNode)
    expect(node.name).to eq(:"-")
    expect(node.receiver).to be_a(NilKill::TreeSitterAdapter::LocalVariableReadNode)
    expect(node.arguments).to be_nil
  end

  it "handles element reference assignment" do
    node = parse_first_statement("foo[1] = 2")
    expect(node).to be_a(NilKill::TreeSitterAdapter::CallNode)
    expect(node.name).to eq(:[]=)
    expect(node.receiver).to be_a(NilKill::TreeSitterAdapter::CallNode)
    expect(node.arguments.child_nodes.size).to eq(2) # 1, 2
  end
  
  it "handles element reference operator assignment" do
    node = parse_first_statement("foo[1] += 2")
    # TreeSitter might parse this as operator_assignment
    expect(node).to be_a(NilKill::TreeSitterAdapter::CallNode)
    expect(node.name).to eq(:[]=)
    expect(node.receiver).to be_a(NilKill::TreeSitterAdapter::CallNode)
    expect(node.arguments.child_nodes.size).to eq(2)
  end

  it "handles element reference read" do
    node = parse_first_statement("foo[1]")
    expect(node).to be_a(NilKill::TreeSitterAdapter::CallNode)
    expect(node.name).to eq(:[])
    expect(node.receiver).to be_a(NilKill::TreeSitterAdapter::CallNode) # foo
    expect(node.arguments.child_nodes.size).to eq(1) # 1
  end

  it "handles safe navigation" do
    node = parse_first_statement("foo&.bar")
    expect(node).to be_a(NilKill::TreeSitterAdapter::CallNode)
    expect(node.safe_navigation?).to be(true)
  end
  
  it "handles IndexOperatorWriteNode (index and write)" do
    node = parse_first_statement("foo[1] &&= 2")
    expect(node).to be_a(NilKill::TreeSitterAdapter::IndexAndWriteNode)
    expect(node.value).not_to be_nil
  end
  
  it "handles IndexOperatorWriteNode (index or write)" do
    node = parse_first_statement("foo[1] ||= 2")
    expect(node).to be_a(NilKill::TreeSitterAdapter::IndexOrWriteNode)
    expect(node.value).not_to be_nil
  end
  
  it "handles operator assignment on locals" do
    node = parse_first_statement("x += 2")
    expect(node.name).to eq(:x)
    expect(node.value).not_to be_nil
  end

  describe "Node Fallbacks" do
    let(:context) { double("Context", source: "foo") }
    let(:raw) { double("RawNode", start_byte: 0, end_byte: 3) }

    it "handles ParameterNode fallbacks" do
      child1 = double("Child", type: "identifier", start_byte: 0, end_byte: 3)
      child2 = double("Child", type: "integer", start_byte: 0, end_byte: 3)
      
      allow(raw).to receive(:child_by_field_name).with("name").and_return(nil)
      allow(raw).to receive(:child_by_field_name).with("value").and_return(nil)
      allow(raw).to receive(:named_children).and_return([child1, child2])
      
      allow(context).to receive(:wrap).with(child2).and_return(:value_node)
      
      node = NilKill::TreeSitterAdapter::ParameterNode.new(context, raw)
      expect(node.name).to eq(:foo)
      expect(node.value).to eq(:value_node)
    end
    
    it "handles ParameterNode root identifier fallback" do
      allow(raw).to receive(:child_by_field_name).with("name").and_return(nil)
      allow(raw).to receive(:named_children).and_return([])
      allow(raw).to receive(:type).and_return("identifier")
      
      node = NilKill::TreeSitterAdapter::ParameterNode.new(context, raw)
      expect(node.name).to eq(:foo)
    end

    it "handles IfNode condition and else_clause aliases" do
      allow(raw).to receive(:child_by_field_name).and_return(nil)
      allow(raw).to receive(:named_children).and_return([double("cond", type: "cond"), double("then", type: "then"), double("else", type: "else")])
      allow(context).to receive(:wrap).and_return(:wrapped)
      
      node = NilKill::TreeSitterAdapter::IfNode.new(context, raw)
      expect(node.condition).to eq(:wrapped)
      expect(node.else_clause).to eq(:wrapped)
    end
    
    it "handles WhileNode condition and statements aliases" do
      allow(raw).to receive(:child_by_field_name).and_return(nil)
      allow(raw).to receive(:named_children).and_return([double("cond", type: "cond"), double("then", type: "then")])
      allow(context).to receive(:wrap).and_return(:wrapped)
      
      node = NilKill::TreeSitterAdapter::WhileNode.new(context, raw)
      allow(node).to receive(:statement_node).and_return(:statements)
      
      expect(node.condition).to eq(:wrapped)
      expect(node.statements).to eq(:statements)
    end
  end
end
