# frozen_string_literal: true

require "minitest/autorun"
require "tempfile"
require_relative "../lib/decomplex"

class Type3CloneTest < Minitest::Test
  def scan(ruby)
    f = Tempfile.new(["t3", ".rb"])
    f.write(ruby)
    f.close
    Decomplex::Type3Clone.scan([f.path])
  ensure
    f
  end

  def test_missed_rename_in_a_pasted_block_is_flagged
    # ref binds abstract var to `src`; the paste renamed src->dst but
    # MISSED one occurrence (still `src`) -> inconsistent rename.
    out = scan(<<~RB)
      def original
        src = fetch(1)
        check(src)
        store(src)
        finalize(src)
      end
      def pasted
        dst = fetch(2)
        check(dst)
        store(src)
        finalize(dst)
      end
      def pasted2
        dst = fetch(3)
        check(dst)
        store(dst)
        finalize(dst)
      end
    RB
    hit = out.find { |h| h[:defn] == "pasted" }
    refute_nil hit, "the missed-rename copy must be flagged"
    assert_equal "src", hit[:ref_name]
    assert_includes hit[:divergent], "src"
    assert_includes hit[:divergent], "dst"
  end

  def test_consistent_rename_is_not_flagged
    out = scan(<<~RB)
      def a
        src = fetch(1)
        check(src)
        store(src)
        finalize(src)
      end
      def b
        dst = fetch(2)
        check(dst)
        store(dst)
        finalize(dst)
      end
    RB
    assert_empty out
  end

  def test_non_clones_are_not_grouped
    out = scan(<<~RB)
      def a
        x = fetch(1)
        check(x)
        store(x)
        done(x)
      end
      def b
        y = build
        y.flush
        y.commit
        y.close
      end
    RB
    assert_empty out
  end

  def test_short_blocks_below_threshold_ignored
    out = scan(<<~RB)
      def a; x = 1; y = x; end
      def b; x = 1; y = z; end
    RB
    assert_empty out
  end
end
