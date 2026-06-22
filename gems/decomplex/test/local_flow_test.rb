# frozen_string_literal: true

require "minitest/autorun"
require "tempfile"
require_relative "../lib/decomplex/ast"
require_relative "../lib/decomplex/local_flow"

class LocalFlowTest < Minitest::Test
  def test_collects_statement_dependencies_and_structural_boundaries
    summary = scan(<<~RB).find { |method| method.name == "mixed" }
      class Billing
        def mixed(price, tax)
          subtotal = price + tax
          total = subtotal.round

          timestamp = Time.now
          buffer = []
          buffer << timestamp
          [total, buffer]
        end
      end
    RB

    refute_nil summary
    assert_equal "Billing", summary.owner
    assert_equal 6, summary.statements.size
    assert_equal [[1, 2]], summary.boundaries.map { |boundary| [boundary.before_index, boundary.after_index] }

    first = summary.statements.first
    assert_equal Set["price", "tax"], first.reads
    assert_equal Set["subtotal"], first.writes
    assert_includes first.dependencies, ["subtotal", "price"]
    assert_includes first.dependencies, ["subtotal", "tax"]

    terminal = summary.statements.last
    assert_equal Set["total", "buffer"], terminal.reads
    assert_includes terminal.co_uses.map(&:sort), ["buffer", "total"]
  end

  def test_collects_top_level_and_inline_private_methods
    summaries = scan(<<~RB)
      def top_level(value)
        result = value
      end

      class Worker
        private def helper(input)
          output = input
        end
      end
    RB

    top = summaries.find { |summary| summary.name == "top_level" }
    helper = summaries.find { |summary| summary.owner == "Worker" && summary.name == "helper" }

    refute_nil top
    refute_nil helper
    assert_equal "(top-level)", top.owner
    assert_equal Set["input"], helper.statements.first.reads
  end

  def test_scan_does_not_use_legacy_ast_parse
    Decomplex::Ast.stub(:parse, ->(*) { raise "legacy Ast.parse should not be used" }) do
      summaries = scan(<<~RB)
        def top_level(value)
          result = value
        end
      RB

      assert_equal ["top_level"], summaries.map(&:name)
    end
  end

  private

  def scan(code)
    file = Tempfile.new(["local_flow", ".rb"])
    file.write(code)
    file.close
    Decomplex::LocalFlow.scan([file.path])
  ensure
    file&.unlink
  end
end
