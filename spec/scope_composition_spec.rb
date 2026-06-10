require "spec_helper"

require_relative "../src/ast/ast"
require_relative "../src/ast/lexer"
require_relative "../src/ast/scope"
require_relative "../src/annotator"
require_relative "../src/annotator/helpers/function_signature"

RSpec.describe Scope do
  def entry(type = Type.new(:Int64), mutable: true, storage: :stack, capabilities: Set.new)
    SymbolEntry.new(reg: nil, type: type, mutable: mutable, storage: storage, capabilities: capabilities)
  end

  def tok(value = "x")
    Lexer::Token.new(:VAR_ID, value, 1, 1)
  end

  it "duplicates as an empty child that resolves through its parent" do
    parent = Scope.new
    parent.declare("x", nil, Type.new(:Int64), true)

    child = parent.dup

    expect(child.local_entries).to be_empty
    expect(child.resolve_entry("x")).to equal(parent.resolve_entry("x"))
    expect(child.visible_names).to eq(["x"])
    expect(child).not_to respond_to(:locals)
    expect(child).not_to respond_to(:locals=)
  end

  it "materializes a local SymbolEntry only when a visible binding is written" do
    parent = Scope.new
    original = parent.declare("x", nil, Type.new(:Int64), true, false, nil, :heap, Set[:READ])
    child = parent.dup

    materialized = child.entry_for_write!("x")
    materialized.mark_read!
    original.sync = :locked

    expect(materialized).not_to equal(original)
    expect(materialized.scope).to equal(child)
    expect(materialized.capabilities).to eq(Set[:READ])
    expect(materialized.sync).to eq(:locked)
    expect(original.read).to eq(false)
    expect(child.local_entries.keys).to eq(["x"])
  end

  it "keeps declarations and installed entries owned by the receiving scope" do
    scope = Scope.new
    declared = scope.declare("declared", nil, Type.new(:String), false)
    installed = scope.install_entry("installed", entry(Type.new(:Bool), mutable: false))

    expect(scope.local_entry!("declared")).to equal(declared)
    expect(scope.local_entry!("installed")).to equal(installed)
    expect(scope.owned_entries.map(&:first)).to contain_exactly("declared", "installed")
    expect(installed.scope).to equal(scope)
  end

  it "merges visible entries with child bindings shadowing parent bindings" do
    parent = Scope.new
    parent.install_entry("value", entry(Type.new(:String), mutable: false))
    parent.install_entry("parent_only", entry(Type.new(:Bool), mutable: false))
    child = parent.dup
    child.install_entry("value", entry(Type.new(:Int64), mutable: true))

    visible = child.visible_entries

    expect(visible.keys).to contain_exactly("value", "parent_only")
    expect(child.visible_names).to eq(["value", "parent_only"])
    expect(parent.local_entry_count).to eq(2)
    expect(child.local_entry_count).to eq(1)
    expect(child.visible_entry_count).to eq(2)
    expect(visible.fetch("value")).to equal(child.local_entry!("value"))
    expect(visible.fetch("parent_only")).to equal(parent.local_entry!("parent_only"))
  end

  it "resolves type declarations through the parent chain" do
    parent = Scope.new
    schema = Schemas::StructSchema.new(fields: {})
    parent.declare_type(:Counter, schema)
    child = parent.dup

    expect(child.resolve_type_definition(:Counter)).to equal(schema)
    expect(child.resolve_type_entry(:Counter)&.schema).to equal(schema)
    expect(child.visible_types.fetch(:Counter).schema).to equal(schema)
    expect(child.resolve_type_definition(:Missing)).to be_nil
  end

  it "marks reads on a materialized child entry without mutating the parent" do
    parent = Scope.new
    parent.declare("x", nil, Type.new(:Int64), true)
    child = parent.dup

    child.mark_read("x")
    child.mark_read("missing")

    expect(parent.resolve_entry!("x").read).to eq(false)
    expect(child.local_entry!("x").read).to eq(true)
    expect(child.local_entry("missing")).to be_nil
  end

  it "adds capability overlays in the child scope only" do
    parent = Scope.new
    parent.install_entry("guarded", entry(Type.new(:Counter), mutable: true, capabilities: Set[:READ]))
    child = parent.dup
    cap = AST::Capability.new(
      capability: :RESTRICT,
      var_node: AST::Identifier.new(Lexer::Token.new(:VAR_ID, "guarded", 1, 1), "guarded"),
      old_scope: parent
    )

    scoped = child.declare_with_new_capability(cap)

    expect(scoped).to equal(child.local_entry!("guarded"))
    expect(scoped.capabilities).to eq(Set[:READ, :RESTRICT])
    expect(parent.resolve_entry!("guarded").capabilities).to eq(Set[:READ])
    expect(child.declare_with_new_capability(cap.tap { |c| c[:var_node] = AST::Identifier.new(Lexer::Token.new(:VAR_ID, "missing", 1, 1), "missing") })).to be_nil
  end

  it "exposes typed binding and type stores without requiring hash-style scope access" do
    bindings = Scope::ScopeBindings.new
    installed = entry
    yielded = []

    bindings["x"] = installed
    bindings.each { |name, sym| yielded << [name, sym] }

    expect(bindings["x"]).to equal(installed)
    expect(bindings.key?("x")).to eq(true)
    expect(bindings.key?("missing")).to eq(false)
    expect(bindings.keys).to eq(["x"])
    expect(bindings.length).to eq(1)
    expect(bindings.pairs).to eq([["x", installed]])
    expect(yielded).to eq([["x", installed]])

    types = Scope::ScopeTypes.new
    schema = Schemas::StructSchema.new(fields: {})
    declared = types.declare(:Thing, schema)
    expect(declared.schema).to equal(schema)
    expect(types[:Thing]).to equal(declared)
    expect(types[:Missing]).to be_nil
    expect(types.keys).to eq([:Thing])

    root = Scope.new
    root.dependencies["main.cht"] = "lib.cht"
    copied = root.dup
    copied.dependencies["other.cht"] = "dep.cht"
    expect(root.dependencies["main.cht"]).to eq("lib.cht")
    expect(root.dependencies["other.cht"]).to be_nil
    expect(copied.dependencies["other.cht"]).to eq("dep.cht")
  end

  it "normalizes legacy hash struct fields into typed StructField values" do
    default = AST::Literal.new(tok("fallback"), :INT64, 1, :stack)
    schema = Schemas::StructSchema.new(fields: {
      count: {
        type: :Int64,
        default: default,
        borrowed: true,
      },
    })

    field = schema.fields.fetch("count")
    expect(field).to be_a(AST::StructField)
    expect(field.type.resolved).to eq(:Int64)
    expect(field.default).to equal(default)
    expect(field.borrowed).to eq(true)
    expect(schema.field_defaults.fetch("count")).to equal(default)
    expect(schema.borrowed_fields).to include("count")
  end

  it "returns the live function parameter symbols by name" do
    fn = AST::FunctionDef.new(tok("main"), "main", [
      AST::Param.new(name: "argc", type: Type.new(:Int64)),
      AST::Param.new(name: "argv", type: Type.new(:String)),
    ], [], Type.new(:Void), nil, [], [], nil, :pub, [], false)
    argc = entry(Type.new(:Int64))
    fn.params.first.symbol = argc

    no_symbols = AST::FunctionDef.new(tok("empty"), "empty", [], [], Type.new(:Void), nil, [], [], nil, :pub, [], false)
    expect(Scope.live_param_syms(no_symbols)).to eq({})
    expect(Scope.live_param_syms(fn)).to eq({ "argc" => argc })
  end

  it "answers type and mutability queries through composed bindings" do
    scope = Scope.new
    locked = scope.declare("locked", nil, Type.new(:Counter), true, false, nil, :heap, Set[:RESTRICT], sync: :locked)
    write_locked = scope.declare("write_locked", nil, Type.new(:Counter), false, false, nil, :heap, Set.new, sync: :write_locked)

    expect(scope.resolve_full_type("missing").resolved).to eq(:Any)
    expect(scope.resolve_full_type("locked")).to equal(locked.type)
    expect(scope.resolve_full_type("write_locked")).to equal(write_locked.type)
    expect(scope.resolve_type("locked")).to equal(locked.type)
    expect(scope.resolve_type("missing").resolved).to eq(:Any)
    expect(scope.is_mutable?("locked")).to eq(true)
    expect(scope.is_mutable?("write_locked")).to eq(false)
    expect(scope.is_mutable?("missing")).to eq(true)
    expect(scope.is_immutable?("write_locked")).to eq(true)
    expect(scope.is_restricted?("locked")).to eq(true)
    expect(scope.is_restricted?("missing")).to eq(false)
  end

  it "extracts root paths and validates visible entries" do
    scope = Scope.new
    invalid = scope.install_entry("bad", entry)
    invalid.invalidate!("moved")
    target = AST::Identifier.new(tok("root"), "root")
    field = AST::GetField.new(tok("."), target, "child")
    index = AST::GetIndex.new(tok("["), field, AST::Literal.new(tok("0"), :INT64, 0, :stack))

    expect(scope.get_path_to_root(index)).to eq([:root, :child, :*])
    expect(scope.get_path_to_root(field)).to eq([:root, :child])
    expect { scope.check_validity!("missing") }.not_to raise_error
    expect { scope.check_validity!("bad") }.to raise_error(RuntimeError, /moved/)
  end

  it "uses ScopeHelper over the composed scope stack" do
    host = Class.new do
      include ScopeHelper

      def initialize(scopes)
        @scope_stack = scopes
      end

      def expose_current_scope = current_scope
      def expose_lookup_scope_for(name) = lookup_scope_for(name)
      def expose_resolve_variable_scope(name) = resolve_variable_scope(name)
      def expose_lookup_type_schema(name) = lookup_type_schema(name)
      def expose_all_known_type_names = all_known_type_names
      def expose_with_new_scope(scope = nil, &blk) = with_new_scope(scope, &blk)
    end

    root = Scope.new
    schema = Schemas::StructSchema.new(fields: {})
    root.declare_type(:Pair, schema)
    fn_sig = FunctionSignature.new(params: [], return_type: Type.new(:Void))
    root.declare("callable", nil, fn_sig, false)
    child = root.dup
    child.declare("value", nil, Type.new(:Int64), true)
    helper = host.new([root, child])

    expect(helper.expose_current_scope).to equal(child)
    expect(helper.expose_lookup_scope_for("value")).to equal(child)
    expect(helper.expose_lookup_scope_for("callable")).to equal(child)
    expect(helper.expose_lookup_scope_for("missing")).to be_nil
    expect(helper.expose_resolve_variable_scope("value")).to equal(child)
    expect(helper.expose_resolve_variable_scope("callable")).to equal(child)
    expect(helper.expose_resolve_variable_scope("missing")).to be_nil
    expect(helper.expose_lookup_type_schema(:"Pair<Int64>")).to equal(schema)
    expect(helper.expose_lookup_type_schema(:Missing)).to be_nil
    expect(helper.expose_all_known_type_names).to eq(["Pair"])

    yielded_scope = nil
    helper.expose_with_new_scope(child) { yielded_scope = helper.expose_current_scope }
    expect(yielded_scope.parent).to equal(child)
    expect(helper.expose_current_scope).to equal(child)

    helper.expose_with_new_scope { yielded_scope = helper.expose_current_scope }
    expect(yielded_scope.parent).to be_nil
    expect(yielded_scope.depth).to eq(2)
  end

  it "collects branch drops from owned entries without dropping inherited bindings" do
    annotator = SemanticAnnotator.new
    root = annotator.send(:current_scope)

    outer = root.declare("outer", nil, Type.new(:String), false, false, nil, :heap)
    outer.ownership_kind = :affine
    annotator.send(:og_declare, "outer", nil, Type.new(:String))

    drops = nil
    annotator.send(:with_new_scope, root) do
      inner = annotator.send(:current_scope).declare("inner", nil, Type.new(:String), false, false, nil, :heap)
      inner.ownership_kind = :affine
      annotator.send(:og_declare, "inner", nil, Type.new(:String))

      drops = annotator.send(:collect_scope_drops, node: nil)
    end

    graph = annotator.send(:ownership_graph)
    expect(drops.map(&:name)).to eq(["inner"])
    expect(graph.live?("outer")).to eq(true)
    expect(graph.live?("inner")).to eq(false)
  end
end
