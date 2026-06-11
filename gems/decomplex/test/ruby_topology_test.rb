# frozen_string_literal: true

require "minitest/autorun"
require "tempfile"
require_relative "../lib/decomplex/ruby_topology"

class RubyTopologyTest < Minitest::Test
  def test_scans_visibility_and_internal_edges
    with_ruby_file(<<~RB) do |path|
      class Worker
        def run(items)
          prepare
          if ready?
            validate
          end
          items.each do |item|
            helper(item)
          end
        end

        private
        def prepare; end
        def ready?; true; end
        def validate; end
        def helper(item); item; end

        public :validate
        protected
        def guarded; end

        private def inline_helper; end

        def self.build
          helper_class
        end

        def self.helper_class; end
      end
    RB
      graph = Decomplex::RubyTopology.scan([path])
      methods = graph.methods_for_owner("Worker").to_h { |method| [method.name, method] }

      assert_equal :public, methods.fetch("run").visibility
      assert_equal :private, methods.fetch("prepare").visibility
      assert_equal :private, methods.fetch("ready?").visibility
      assert_equal :public, methods.fetch("validate").visibility
      assert_equal :protected, methods.fetch("guarded").visibility
      assert_equal :private, methods.fetch("inline_helper").visibility
      assert_equal :public, methods.fetch("self.build").visibility

      edges = graph.edges_for_owner("Worker").map do |edge|
        [edge.caller_name, edge.callee_name, edge.type, edge.kind, edge.confidence]
      end

      assert_includes edges, ["run", "prepare", :always, :bare_internal, :high]
      assert_includes edges, ["run", "ready?", :conditional, :bare_internal, :high]
      assert_includes edges, ["run", "validate", :conditional, :bare_internal, :high]
      assert_includes edges, ["run", "helper", :iterates, :bare_internal, :high]
      assert_includes edges, ["self.build", "self.helper_class", :always, :bare_internal, :high]

      prepare_id = graph.method_id("Worker", "prepare")
      assert_equal ["run"], graph.internal_callers(prepare_id).map(&:caller_name)
      assert graph.single_internal_caller?(prepare_id)
      assert_equal "Worker", graph.owner(prepare_id)
      assert_equal methods.fetch("prepare").span, graph.span(prepare_id)
      assert_includes graph.call_sites(graph.method_id("Worker", "run")), "#{path}:run:3"
    end
  end

  def test_tracks_direct_self_edges_and_ignores_external_receivers
    with_ruby_file(<<~RB) do |path|
      class Runner
        def run(other)
          self.prepare
          other.prepare
          Helper.prepare
        end

        def prepare; end
      end
    RB
      graph = Decomplex::RubyTopology.scan([path])
      edges = graph.edges_for_owner("Runner")

      assert_equal 1, edges.size
      edge = edges.first
      assert_equal "run", edge.caller_name
      assert_equal "prepare", edge.callee_name
      assert_equal :direct_self, edge.kind
      assert_equal :always, edge.type
    end
  end

  def test_keeps_module_owners_and_skips_nested_call_bodies
    with_ruby_file(<<~RB) do |path|
      module Outer
        class Inner
          def run
            -> { hidden }
          end

          def hidden; end
        end
      end
    RB
      graph = Decomplex::RubyTopology.scan([path])

      assert graph.method_for("Outer::Inner", "run")
      assert graph.method_for("Outer::Inner", "hidden")
      assert_empty graph.edges_for_owner("Outer::Inner")
    end
  end

  def test_handles_defensive_ast_shapes_and_unresolved_calls
    with_ruby_file(<<~RB) do |path|
      class Empty; end

      class Single
        def only; end
      end

      class OddVisibility
        private()
        public :missing

        def run
          missing_call
          run
        end

        public "run"

        def OddVisibility.explicit; end
      end
    RB
      graph = Decomplex::RubyTopology.scan([path])

      assert_equal :public, graph.visibility(graph.method_id("OddVisibility", "run"))
      assert_nil graph.visibility(graph.method_id("OddVisibility", "missing"))
      assert_nil graph.owner(graph.method_id("OddVisibility", "missing"))
      assert_nil graph.span(graph.method_id("OddVisibility", "missing"))
      assert_empty graph.edges_for_owner("Empty")
      assert_empty graph.edges_for_owner("Single")
      assert_empty graph.edges_for_owner("OddVisibility")
      assert graph.method_for("OddVisibility", "OddVisibility.explicit")
    end
  end

  def test_groups_dangling_edge_under_nil_owner
    edge = Decomplex::RubyTopology::Edge.new(
      caller: "Missing#run",
      callee: "Missing#helper",
      caller_name: "run",
      callee_name: "helper",
      file: "missing.rb",
      line: 1,
      span: [1, 0, 1, 6],
      type: :always,
      kind: :bare_internal,
      confidence: :high
    )

    graph = Decomplex::RubyTopology::Graph.new([], [edge])

    assert_empty graph.edges_for_owner("Missing")
    assert_equal [edge], graph.edges_for_owner(nil)
  end

  private

  def with_ruby_file(code)
    file = Tempfile.new(["ruby_topology", ".rb"])
    file.write(code)
    file.close
    yield file.path
  ensure
    file&.unlink
  end
end
