# frozen_string_literal: true

require_relative "spec_helper"
require_relative "../lib/nil_kill/util"

RSpec.describe NilKill do
  describe ".write_inplace_sentinel! and .restore_inplace_snapshot!" do
    it "writes sentinel and restores" do
      Dir.mktmpdir do |dir|
        stub_const("NilKill::RUNTIME_DIR", dir)
        stub_const("NilKill::ROOT", dir)
        
        snapshot = File.join(dir, "snapshot")
        FileUtils.mkdir_p(snapshot)
        File.write(File.join(snapshot, "test.rb"), "foo")
        
        NilKill.write_inplace_sentinel!(snapshot, ["test.rb"])
        expect(File.exist?(NilKill.inplace_sentinel_path)).to be(true)
        
        NilKill.ensure_src_restored!
        expect(File.exist?(NilKill.inplace_sentinel_path)).to be(false)
        expect(File.read(File.join(dir, "test.rb"))).to eq("foo")
      end
    end
    
    it "handles missing sentinel gracefully" do
      Dir.mktmpdir do |dir|
        stub_const("NilKill::RUNTIME_DIR", dir)
        expect(NilKill.restore_inplace_snapshot!).to be(false)
        NilKill.ensure_src_restored!
      end
    end
  end

  describe ".cached_parse_file" do
    it "caches parse result" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "test.rb")
        File.write(path, "def foo; end")
        parsed1 = NilKill.cached_parse_file(path)
        parsed2 = NilKill.cached_parse_file(path)
        expect(parsed1).to eq(parsed2)
      end
    end
  end

  describe "target resolution" do
    around do |example|
      original_targets = ENV["NIL_KILL_TARGETS"]
      original_exclude = ENV["NIL_KILL_EXCLUDE_TARGETS"]
      example.run
    ensure
      ENV["NIL_KILL_TARGETS"] = original_targets
      ENV["NIL_KILL_EXCLUDE_TARGETS"] = original_exclude
    end

    it "resolves target_files and source_index_target_files" do
      Dir.mktmpdir do |dir|
        stub_const("NilKill::ROOT", dir)
        
        src_dir = File.join(dir, "src")
        exclude_dir = File.join(src_dir, "exclude")
        FileUtils.mkdir_p(src_dir)
        FileUtils.mkdir_p(exclude_dir)
        
        file1 = File.join(src_dir, "a.rb")
        file2 = File.join(exclude_dir, "b.rb")
        File.write(file1, "1")
        File.write(file2, "2")
        
        ENV["NIL_KILL_TARGETS"] = "src"
        ENV["NIL_KILL_EXCLUDE_TARGETS"] = "src/exclude"
        
        expect(NilKill.target_files).to contain_exactly(file1)
        expect(NilKill.source_index_target_files).to contain_exactly(file1)
        expect(NilKill.usage_scan_files).to contain_exactly(file1)
        expect(NilKill.target_path?(file1)).to be(true)
        expect(NilKill.target_path?(file2)).to be(false)
        expect(NilKill.target_excluded?(file2)).to be(true)
      end
    end
    
    it "resolves usage_scan_files without explicit targets" do
      Dir.mktmpdir do |dir|
        stub_const("NilKill::ROOT", dir)
        ENV.delete("NIL_KILL_TARGETS")
        
        file = File.join(dir, "foo.rb")
        File.write(file, "")
        
        expect(NilKill.usage_scan_files).to include(file)
      end
    end
  end
  
  describe ".sorbet_type" do
    it "collapses nilclass" do
      expect(NilKill.sorbet_type(["NilClass"])).to eq("T.untyped")
      expect(NilKill.sorbet_type(["String", "NilClass"])).to eq("T.nilable(String)")
    end
    
    it "filters out internal sorbet types" do
      expect(NilKill.sorbet_type(["Sorbet::Private::Foo", "String"])).to eq("String")
    end
  end

  describe "shape and type helpers" do
    it "parses shape correctly" do
      expect(NilKill.parse_shape('{"kind":"class"}')).to eq({ "kind" => "class" })
      expect(NilKill.parse_shape('invalid')).to eq({ "kind" => "class", "name" => "invalid" })
    end

    it "resolves shape_type" do
      expect(NilKill.shape_type({ "kind" => "class", "name" => "String" })).to eq("String")
      expect(NilKill.shape_type({ "kind" => "array", "elements" => [{ "kind" => "class", "name" => "Integer" }] })).to eq("T::Array[Integer]")
      expect(NilKill.shape_type({ "kind" => "set", "elements" => [{ "kind" => "class", "name" => "Symbol" }] })).to eq("T::Set[Symbol]")
      expect(NilKill.shape_type({ "kind" => "hash", "keys" => [{ "kind" => "class", "name" => "String" }], "values" => [{ "kind" => "class", "name" => "Integer" }] })).to eq("T::Hash[String, Integer]")
    end

    it "resolves shape_union_type" do
      expect(NilKill.shape_union_type([{ "kind" => "class", "name" => "String" }])).to eq("String")
      expect(NilKill.shape_union_type([{ "kind" => "class", "name" => "AST::Foo" }, { "kind" => "class", "name" => "AST::Bar" }])).to eq("AST::Node")
      expect(NilKill.shape_union_type([{ "kind" => "class", "name" => "MIR::Foo" }, { "kind" => "class", "name" => "MIR::Bar" }])).to eq("MIR::Node")
      expect(NilKill.shape_union_type([{ "kind" => "class", "name" => "String" }, { "kind" => "class", "name" => "Integer" }])).to eq("T.any(Integer, String)")
      expect(NilKill.shape_union_type([{ "kind" => "array", "elements" => [{ "kind" => "class", "name" => "Integer" }] }, { "kind" => "array", "elements" => [{ "kind" => "class", "name" => "String" }] }])).to eq("T::Array[T.any(Integer, String)]")
    end

    it "evaluates acceptable_shape_candidate?" do
      expect(NilKill.acceptable_shape_candidate?("String")).to be(true)
      expect(NilKill.acceptable_shape_candidate?("T.any(String, Integer, Float, Symbol, Array, Hash, Date, Time, Thread)")).to be(false) # Too broad, assuming broad_union_type? returns true
    end

    it "calculates confidence" do
      expect(NilKill.confidence(100)).to eq("high")
      expect(NilKill.confidence(5)).to eq("review")
    end

    it "formats display_union" do
      expect(NilKill.display_union(["String"])).to eq("String")
      expect(NilKill.display_union(["String", "Integer"])).to eq("T.any(Integer, String)")
      expect(NilKill.display_union(["String", "NilClass"])).to eq("T.nilable(String)")
    end

    it "calls rbi_return_type" do
      allow(NilKill).to receive(:rbi_return_index).and_return(double("RbiReturnIndex", return_type: "String"))
      expect(NilKill.rbi_return_type("to_s")).to eq("String")
    end
    
    it "handles T.noreturn in static_sorbet_type" do
      expect(NilKill.static_sorbet_type(["T.noreturn", "NilClass"])).to eq("NilClass")
      expect(NilKill.static_sorbet_type(["T.noreturn"])).to eq("T.noreturn")
    end
    
    it "normalizes static sorbet types" do
      expect(NilKill.normalize_static_sorbet_type("Array")).to eq("T::Array[T.untyped]")
      expect(NilKill.normalize_static_sorbet_type("Hash")).to eq("T::Hash[T.untyped, T.untyped]")
      expect(NilKill.normalize_static_sorbet_type("Set")).to eq("T::Set[T.untyped]")
      expect(NilKill.normalize_static_sorbet_type("String")).to eq("String")
    end
    
    it "extracts call args with nested parens" do
      expect(NilKill.extract_call_args("foo(bar(1, 2))", "foo")).to eq("bar(1, 2)")
    end

    it "collapses node types" do
      expect(NilKill.collapse_node_types(["AST::CallNode", "AST::VariableNode"])).to match_array(["AST::Node"])
      expect(NilKill.collapse_node_types(["MIR::CallNode", "MIR::VariableNode"])).to match_array(["MIR::Node"])
      expect(NilKill.collapse_node_types(["AST::CallNode", "String"])).to match_array(["AST::Node", "String"])
    end

    it "strips stdlib owners" do
      expect(NilKill.strip_to_stdlib_owner("T::Range[Integer]")).to eq("Range")
      expect(NilKill.strip_to_stdlib_owner("T::Enumerator[String]")).to eq("Enumerator")
      expect(NilKill.strip_to_stdlib_owner("T::Enumerable[String]")).to eq("Enumerable")
    end

    it "strips nilable types" do
      expect(NilKill.strip_nilable_type("T.nilable(String)")).to eq("String")
      expect(NilKill.strip_nilable_type("String")).to eq("String")
    end

    it "resolves conservative element types for AST/MIR" do
      expect(NilKill.conservative_element_type(["AST::CallNode", "AST::VariableNode"])).to eq("AST::Node")
      expect(NilKill.conservative_element_type(["MIR::CallNode", "MIR::VariableNode", "NilClass"])).to eq("T.nilable(MIR::Node)")
    end

    it "merges set shapes in shape_union_type" do
      shapes = [
        { "kind" => "set", "elements" => [{ "kind" => "class", "name" => "String" }] },
        { "kind" => "set", "elements" => [{ "kind" => "class", "name" => "Integer" }] }
      ]
      expect(NilKill.shape_union_type(shapes)).to eq("T::Set[T.any(Integer, String)]")
    end
  end
end
