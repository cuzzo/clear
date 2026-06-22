# frozen_string_literal: true

require "minitest/autorun"
require "tempfile"
require_relative "../lib/decomplex"

class InconsistentRenameCloneTest < Minitest::Test
  def scan(ruby)
    f = Tempfile.new(["rename-clone", ".rb"])
    f.write(ruby)
    f.close
    Decomplex::InconsistentRenameClone.scan([f.path])
  ensure
    @tmp ||= []
    @tmp << f if f
  end

  def test_missed_rename_in_a_pasted_block_is_flagged
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

  def test_same_method_branch_symmetry_is_not_a_missed_rename
    out = scan(<<~RB)
      def replace(parent, old_child, new_child)
        parent.class.members.each do |member|
          value = parent[member]
          if value.equal?(old_child)
            parent[member] = new_child
            refresh(parent, old_child, new_child)
          elsif value.is_a?(Array)
            idx = value.index { |item| item.equal?(old_child) }
            if idx
              value[idx] = new_child
              refresh(parent, old_child, new_child)
            end
          elsif value.is_a?(Hash)
            key = value.keys.find { |k| value[k].equal?(old_child) }
            if key
              value[key] = new_child
              refresh(parent, old_child, new_child)
            end
          end
        end
      end
    RB
    assert_empty out
  end

  def test_scan_does_not_use_legacy_ast_parse
    Decomplex::Ast.stub(:parse, ->(*) { raise "legacy Ast.parse should not be used" }) do
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
      RB

      refute_empty out
    end
  end
end
