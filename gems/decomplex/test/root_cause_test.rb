# frozen_string_literal: true

require "minitest/autorun"
require "tempfile"
require_relative "../lib/decomplex"
require_relative "../lib/decomplex/report"

class RootCauseTest < Minitest::Test
  RC = Decomplex::RootCause

  # ---- entities (generic projection) --------------------------------

  def test_name_tokens_normalize_to_the_shared_identifier
    # "@storage" / ".storage" / "storage=" / "storage" must all reduce
    # to "storage" -- that normalization IS the cross-detector link.
    %w[storage @storage .storage storage= node.storage storage?].each do |s|
      assert_includes RC.tokens(s), "storage", "#{s.inspect} -> storage"
    end
    refute_includes RC.tokens("a"), "a"          # too short
    refute_includes RC.tokens("nil"), "nil"      # stopword
  end

  def test_entities_split_name_vs_tuple_kinds
    name = RC.entities(pair: %w[provenance storage], at: "f.rb:m:1")
    assert_includes name, [:name, "provenance"]
    assert_includes name, [:name, "storage"]
    tup = RC.entities(members: ["x.is_a?(A)", "y.nil?"], sites: ["f.rb:m:1"])
    assert(tup.any? { |k, _| k == :tuple })
  end

  def test_tuple_token_is_field_name_agnostic
    # the SAME decision via Missing-Abstractions(:members),
    # Neglected-Conditions(:pattern), PathCondition(:guards) must
    # produce the SAME tuple token.
    a = RC.entities(members: %w[c a b])
    b = RC.entities(pattern: %w[a b c])
    g = RC.entities(guards: %w[b c a])
    tok = ->(e) { e.find { |k, _| k == :tuple }[1] }
    assert_equal tok.call(a), tok.call(b)
    assert_equal tok.call(b), tok.call(g)
  end

  # ---- cluster ------------------------------------------------------

  def test_two_detectors_naming_same_entity_form_one_cluster
    sections = [
      ["Neglected Updates", 2,
       [{ pair: %w[provenance storage], at: "f.rb:lower:10" }]],
      ["Derived-State Staleness", 2,
       [{ derived: "storage", source: "raw", at: "f.rb:lower:14" }]]
    ]
    cl = RC.cluster(sections)
    hit = cl.find { |c| c[:token] == "storage" && c[:kind] == :name }
    refute_nil hit
    assert_equal %w[Derived-State\ Staleness Neglected\ Updates],
                 hit[:detectors]
    assert_equal 2, hit[:n_detectors]
    assert_equal 2, hit[:support]
    assert_equal 1, hit[:scatter]               # both in (f.rb, lower)
    assert_match(/single-source/, hit[:fix])    # the invariant-#16 shape
  end

  def test_single_detector_entity_is_not_a_cluster
    sections = [
      ["False Simplicity", 3,
       [{ kind: :hidden_mutation, detail: "storage=", at: "f.rb:a:1" },
        { kind: :hidden_mutation, detail: "storage=", at: "f.rb:b:2" }]]
    ]
    # one detector, however often -> not a root cause (that is the
    # detector's own job). Needs >=2 DISTINCT detectors.
    assert_empty RC.cluster(sections)
    assert_equal 1, RC.cluster(sections, min_detectors: 1)
                      .count { |c| c[:token] == "storage" }
  end

  def test_ranked_by_distinct_detectors_then_score
    # all three NAME "big" via name-fields (contract / pair / pair) ->
    # 3 distinct detectors on the same :name entity. "small" by 2.
    sections = [
      ["Decision Pressure", 1, [{ contract: ".big", sites: ["f.rb:p:1"] }]],
      ["Broken Protocols", 3, [{ pair: %w[big aa], at: "f.rb:p:3" }]],
      ["Neglected Updates", 2, [{ pair: %w[big bb], at: "f.rb:p:4" }]],
      ["Derived-State Staleness", 2, [{ derived: "small", source: "qq", at: "f.rb:r:2" }]],
      ["Reification Misses", 1, [{ predicate: "small", at: "f.rb:r:3" }]]
    ]
    cl = RC.cluster(sections)
    top = cl.first
    # "big" is named by 3 distinct detectors; "small" by 2 -> "big"
    # ranks first regardless of tier weight.
    assert_equal "big", top[:token]
    assert_equal 3, top[:n_detectors]
  end

  def test_fix_shape_policy_is_specific_first
    # protocol rule must win over the generic predicate rule.
    assert_match(/pair the protocol/,
                 RC.fix_shape(["Broken Protocols", "Missing Abstractions"], :name))
    assert_match(/reify ONE named/,
                 RC.fix_shape(["Missing Abstractions"], :name))
    assert_match(/converging structural debt/,
                 RC.fix_shape(["Flay Similarity (Type-2/3)"], :name))
  end

  # ---- #2 precursor: fat-union label --------------------------------

  def test_class_dispatch_tuple_is_flagged_fat_union
    sections = [
      ["Missing Abstractions", 1,
       [{ kind: :case_dispatch, members: %w[AST::Call AST::Func],
          sites: ["f.rb:lower:1"] }]],
      ["Neglected Conditions", 2,
       [{ pattern: %w[AST::Call AST::Func], at: "f.rb:other:2" }]]
    ]
    hit = RC.cluster(sections).find { |c| c[:kind] == :tuple }
    refute_nil hit
    assert hit[:fat_union], "case dispatch over class consts -> fat union"
    assert_match(/product-vs-sum/, hit[:fix])
    assert_match(/nil-kill/, hit[:fix])
  end

  def test_conjunction_tuple_is_not_fat_union
    sections = [
      ["Missing Abstractions", 1,
       [{ kind: :conjunction, members: ["a > 0", "b.nil?"],
          sites: ["f.rb:m:1"] }]],
      ["Neglected Path Conditions", 3,
       [{ pattern: ["a > 0", "b.nil?"], at: "f.rb:n:2" }]]
    ]
    hit = RC.cluster(sections).find { |c| c[:kind] == :tuple }
    refute_nil hit
    refute hit[:fat_union], "a boolean conjunction is not a union"
  end

  def test_symbol_or_int_dispatch_is_not_fat_union
    # case over symbols/ints is enum-ish, NOT a union -> no fat-union.
    sections = [
      ["Missing Abstractions", 1,
       [{ kind: :case_dispatch, members: %w[:a :b], sites: ["f.rb:m:1"] }]],
      ["Neglected Conditions", 2,
       [{ pattern: %w[:a :b], at: "f.rb:n:2" }]]
    ]
    hit = RC.cluster(sections).find { |c| c[:kind] == :tuple }
    refute_nil hit
    refute hit[:fat_union]
  end

  def test_name_cluster_is_never_fat_union
    sections = [
      ["Neglected Updates", 2, [{ pair: %w[provenance storage], at: "f:m:1" }]],
      ["Derived-State Staleness", 2, [{ derived: "storage", source: "r", at: "f:m:2" }]]
    ]
    hit = RC.cluster(sections).find { |c| c[:token] == "storage" }
    refute hit[:fat_union]
  end

  # ---- Report integration -------------------------------------------

  def test_report_surfaces_storage_provenance_cluster
    # 3 methods co-write storage+provenance, a 4th writes only storage
    # -> Neglected Updates (pair) AND False Simplicity (hidden_mutation
    # `storage=`/`provenance=`) both NAME storage/provenance -> one
    # root-cause cluster with the single-source fix.
    src = <<~RB
      def a(n); n.storage = 1; n.provenance = 2; end
      def b(n); n.storage = 3; n.provenance = 4; end
      def c(n); n.storage = 5; n.provenance = 6; end
      def d(n); n.storage = 7; end
    RB
    f = Tempfile.new(["rc", ".rb"])
    f.write(src)
    f.close
    rep = Decomplex::Report.new([f.path])
    md = rep.to_markdown
    assert_includes md, "## Root-Cause Clusters"
    cl = rep.instance_variable_get(:@root)
    hit = cl.find { |c| c[:token] == "storage" }
    refute_nil hit, "storage must surface as a cross-detector cluster"
    assert_operator hit[:n_detectors], :>=, 2
    assert_match(/single-source|converging/, hit[:fix])
  ensure
    f
  end
end
