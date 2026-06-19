# frozen_string_literal: true

require "minitest/autorun"
require "tempfile"
require_relative "../lib/decomplex"
require_relative "../lib/decomplex/report"

class FatUnionTest < Minitest::Test
  def scan(ruby, **opts)
    f = Tempfile.new(["fu", ".rb"])
    f.write(ruby)
    f.close
    @tmp ||= []
    @tmp << f
    Decomplex::FatUnion.scan([f.path], **opts).fat_unions
  end

  # ---- positive: a real fat union -----------------------------------

  def test_fat_union_with_dominant_common_core_is_flagged
    fu = scan(<<~RB)
      def lower(n)
        case n
        when AST::Call then n.line; n.col; n.ty; n.span; n.parent; n.recv
        when AST::Func then n.line; n.col; n.ty; n.span; n.parent; n.name
        when AST::Lit  then n.line; n.col; n.ty; n.span; n.parent; n.value
        end
      end
    RB
    assert_equal 1, fu.size
    h = fu.first
    assert_equal %w[AST::Call AST::Func AST::Lit], h[:variant_set]
    assert_equal %w[col line parent span ty], h[:common]
    assert_equal %w[name recv value], h[:variant]
    refute h[:degenerate]
  end

  def test_degenerate_no_variance_is_flagged_and_ranked_first
    # every arm reads ONLY common members -> the union carries no
    # structural variation: highest-precision case, sorts first.
    fu = scan(<<~RB)
      def a(n)
        case n
        when AST::Call then n.line; n.ty
        when AST::Func then n.line; n.ty
        when AST::Lit  then n.line; n.ty
        end
      end
      def b(n)
        case n
        when Heterogeneous::X then n.p; n.q
        when Heterogeneous::Y then n.r
        when Heterogeneous::Z then n.s
        end
      end
    RB
    deg = fu.find { |x| x[:degenerate] }
    refute_nil deg
    assert_equal %w[AST::Call AST::Func AST::Lit], deg[:variant_set]
    assert_empty deg[:variant]
    assert_equal deg, fu.first, "degenerate sorts to the top"
  end

  def test_member_used_outside_dispatch_counts_as_common
    # `n.ty` read OUTSIDE the case in the same method is the strongest
    # 'belongs in the common struct' tell -- common even though no arm
    # reads it. (relaxed thresholds to isolate the mechanic.)
    fu = scan(<<~RB, min_common: 1, ratio: 0.0)
      def lower(n)
        log(n.ty)
        case n
        when AST::Call then n.recv
        when AST::Func then n.name
        when AST::Lit  then n.value
        end
      end
    RB
    assert_includes fu.first[:common], "ty"
  end

  # ---- negatives / no false positives -------------------------------

  def test_heterogeneous_union_is_not_flagged
    # Result/Either: every variant reads a DISTINCT member, no common
    # core -> must NOT be flagged.
    assert_empty scan(<<~RB)
      def handle(r)
        case r
        when Ok    then r.value
        when Err   then r.error
        when Retry then r.attempts
        end
      end
    RB
  end

  def test_two_variant_dispatch_is_not_a_union
    assert_empty scan(<<~RB)
      def t(n)
        case n
        when AST::A then n.x; n.y; n.z
        when AST::B then n.x; n.y; n.z
        end
      end
    RB
  end

  def test_symbol_and_int_dispatch_are_not_unions
    assert_empty scan(<<~RB)
      def s(n)
        case n
        when :a then n.x; n.y
        when :b then n.x; n.y
        when :c then n.x; n.y
        end
      end
      def i(n)
        case n
        when 1 then n.x; n.y
        when 2 then n.x; n.y
        when 3 then n.x; n.y
        end
      end
    RB
  end

  def test_predicate_less_case_is_skipped
    assert_empty scan(<<~RB)
      def p(a, b, c)
        case
        when a then a.x; a.y; a.z
        when b then b.x; b.y; b.z
        when c then c.x; c.y; c.z
        end
      end
    RB
  end

  # ---- scatter aggregation ------------------------------------------

  def test_same_variant_set_aggregates_scatter
    h = scan(<<~RB).first
      def one(n)
        case n
        when AST::Call then n.line; n.col; n.ty; n.span; n.parent; n.recv
        when AST::Func then n.line; n.col; n.ty; n.span; n.parent; n.name
        when AST::Lit  then n.line; n.col; n.ty; n.span; n.parent; n.value
        end
      end
      def two(n)
        case n
        when AST::Call then n.line; n.col; n.ty; n.span; n.parent; n.recv
        when AST::Func then n.line; n.col; n.ty; n.span; n.parent; n.name
        when AST::Lit  then n.line; n.col; n.ty; n.span; n.parent; n.value
        end
      end
    RB
    assert_equal 2, h[:support]
    assert_equal 2, h[:scatter]
    assert_includes h[:common], "line"
  end

  # ---- Report integration + RootCause corroboration -----------------

  def test_report_section_and_rootcause_fat_union_corroborate
    src = <<~RB
      def lower_a(n)
        case n
        when AST::Call then n.line; n.col; n.ty; n.span; n.parent; n.recv
        when AST::Func then n.line; n.col; n.ty; n.span; n.parent; n.name
        when AST::Lit  then n.line; n.col; n.ty; n.span; n.parent; n.value
        end
      end
      def lower_b(n)
        case n
        when AST::Call then n.line; n.col; n.ty; n.span; n.parent; n.recv
        when AST::Func then n.line; n.col; n.ty; n.span; n.parent; n.name
        when AST::Lit  then n.line; n.col; n.ty; n.span; n.parent; n.value
        end
      end
    RB
    f = Tempfile.new(["fu", ".rb"])
    f.write(src)
    f.close
    rep = Decomplex::Report.new([f.path])
    md = rep.to_markdown
    assert_includes md, "## Fat Unions"
    assert_match(/union `AST::Call \| AST::Func \| AST::Lit`/, md)
    # repeated dispatch -> Missing Abstractions ALSO fires on the same
    # variant-set, so RootCause clusters it AND the #2 precursor flags
    # it fat_union (detector + precursor corroborate, no double-build).
    cl = rep.root_clusters.find do |c|
      c[:kind] == :tuple && c[:token].include?("AST::Call")
    end
    refute_nil cl
    assert cl[:fat_union], "RootCause precursor corroborates the detector"
  ensure
    f
  end

  def test_scan_does_not_use_legacy_ast_parse
    Decomplex::Ast.stub(:parse, ->(*) { raise "legacy Ast.parse should not be used" }) do
      fu = scan(<<~RB)
        def lower(n)
          case n
          when AST::Call then n.line; n.ty
          when AST::Func then n.line; n.ty
          when AST::Lit  then n.line; n.ty
          end
        end
      RB

      assert_equal 1, fu.size
    end
  end
end
