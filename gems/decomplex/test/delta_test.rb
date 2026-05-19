# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "tempfile"
require_relative "../lib/decomplex"
require_relative "../lib/decomplex/report"

class DeltaTest < Minitest::Test
  D = Decomplex::Delta
  RC = Decomplex::RootCause

  def shift_line(loc, by)
    f, m, l = loc.split(":")
    "#{f}:#{m}:#{l.to_i + by}"
  end

  def shift_findings(sections, by)
    sections.map do |title, tier, fs|
      [title, tier, fs.map do |f|
        g = f.dup
        g[:at] = shift_line(g[:at], by) if g[:at]
        g[:sites] = g[:sites].map { |s| shift_line(s, by) } if g[:sites]
        g
      end]
    end
  end

  def base_sections
    [
      ["Neglected Updates", 2,
       [{ pair: %w[provenance storage], at: "f.rb:lower:10" }]],
      ["Derived-State Staleness", 2,
       [{ derived: "storage", source: "raw", at: "f.rb:lower:14" }]],
      ["Decision Pressure", 1,
       [{ contract: ".storage", sites: ["f.rb:lower:20"] }]]
    ]
  end

  # ---- fingerprint: line-insensitive --------------------------------

  def test_fingerprint_ignores_line_number
    a = D.fingerprint("Neglected Updates", { pair: %w[xx yy], at: "f.rb:m:10" })
    b = D.fingerprint("Neglected Updates", { pair: %w[xx yy], at: "f.rb:m:999" })
    assert_equal a, b, "only the line differs -> same identity"
    c = D.fingerprint("Neglected Updates", { pair: %w[xx yy], at: "f.rb:other:10" })
    refute_equal a, c, "different method -> different identity"
  end

  # ---- snapshot -----------------------------------------------------

  def test_snapshot_shape_and_total
    s = D.snapshot(base_sections, RC.cluster(base_sections))
    assert_equal 3, s["total"]
    assert_equal 3, s["findings"].values.sum
    assert(s["clusters"].keys.any? { |k| k.include?("storage") },
           "the storage cluster is captured")
  end

  # ---- diff: resolved / added / persisted ---------------------------

  def test_diff_classifies_resolved_added_persisted
    base = D.snapshot(base_sections, RC.cluster(base_sections))
    # head: drop Derived-State (resolve 1), add a new False Simplicity.
    head_sections = [
      base_sections[0],
      base_sections[2],
      ["False Simplicity", 3, [{ kind: :hidden_mutation, detail: "cache=", at: "f.rb:lower:30" }]]
    ]
    head = D.snapshot(head_sections, RC.cluster(head_sections))
    d = D.diff(base, head)
    assert_equal 1, d["resolved"].size, "Derived-State finding gone"
    assert_equal 1, d["added"].size, "False Simplicity finding new"
    assert_equal 2, d["persisted"], "Neglected Updates + Decision Pressure"
    assert_equal(-1 + 1, d["totals"]["delta"])
  end

  # ---- diff: clusters ----------------------------------------------

  def test_diff_detects_cluster_collapse
    base = D.snapshot(base_sections, RC.cluster(base_sections))
    # head: storage now named by only ONE detector -> no cluster.
    head_sections = [["Neglected Updates", 2,
                      [{ pair: %w[provenance storage], at: "f.rb:lower:10" }]]]
    head = D.snapshot(head_sections, RC.cluster(head_sections))
    d = D.diff(base, head)
    assert(d["clusters"]["resolved"].any? { |k, _| k.include?("storage") },
           "the storage root-cause cluster collapsed")
  end

  # ---- THE correctness test: whole-file line shift = no churn -------

  def test_line_shift_is_entirely_persisted
    base = D.snapshot(base_sections, RC.cluster(base_sections))
    shifted = shift_findings(base_sections, 100)
    head = D.snapshot(shifted, RC.cluster(shifted))
    d = D.diff(base, head)
    assert_empty d["resolved"], "a pure line shift resolves NOTHING"
    assert_empty d["added"], "a pure line shift adds NOTHING"
    assert_equal base["total"], d["persisted"] +
                 d["added"].size, "all findings persisted across the shift"
    assert_equal 0, d["totals"]["delta"]
  end

  # ---- Report integration: real line shift through the pipeline ----

  def test_report_pipeline_line_shift_then_real_change
    src = <<~RB
      def a(n)
        case n
        when 1 then 10
        when 2 then 20
        else 30
        end
      end
      def b(n)
        case n
        when 1 then 11
        when 2 then 21
        else 31
        end
      end
    RB
    f = Tempfile.new(["dl", ".rb"])
    f.write(src)
    f.close
    rep1 = Decomplex::Report.new([f.path])
    base = D.snapshot(rep1.sections_data, rep1.root_clusters)

    # prepend blank lines -> every finding's line moves; identity must
    # hold through the whole Report pipeline.
    File.write(f.path, "\n\n\n\n\n" + src)
    rep2 = Decomplex::Report.new([f.path])
    head = D.snapshot(rep2.sections_data, rep2.root_clusters)
    d1 = D.diff(base, head)
    assert_empty d1["resolved"], "line shift through Report -> no resolve"
    assert_empty d1["added"], "line shift through Report -> no add"

    # now a REAL change: a third method with the same dispatch ->
    # genuine new finding / grown scatter.
    File.write(f.path, "\n\n\n\n\n" + src + <<~RB)
      def c(n)
        case n
        when 1 then 12
        when 2 then 22
        else 32
        end
      end
    RB
    rep3 = Decomplex::Report.new([f.path])
    head2 = D.snapshot(rep3.sections_data, rep3.root_clusters)
    d2 = D.diff(base, head2)
    assert(d2["totals"]["delta"].positive? || !d2["added"].empty?,
           "a real added duplication registers as new debt")
  ensure
    f
  end

  # ---- site-level precision: the multi-unit case the aggregate
  #      fingerprint cannot answer (added additively; total unchanged) --

  def test_site_delta_pinpoints_one_added_member
    base = [["Decision Pressure", 1,
             [{ contract: ".storage",
                sites: %w[f.rb:a:10 f.rb:b:20 f.rb:c:30] }]]]
    head = [["Decision Pressure", 1,
             [{ contract: ".storage",
                sites: %w[f.rb:a:10 f.rb:b:20 f.rb:c:30 f.rb:d:40] }]]]
    b = D.snapshot(base, RC.cluster(base))
    h = D.snapshot(head, RC.cluster(head))
    d = D.diff(b, h)

    # Aggregate findings delta is coarse here (one member changed ->
    # whole finding re-keys): the documented limitation.
    assert_equal 1, d["added"].size
    assert_equal 1, d["resolved"].size
    assert_equal 0, d["persisted"]

    # Site-level is precise: exactly ONE new (file#method); the other
    # three persisted; none resolved.
    assert_equal 1, d["site_added"].size, "exactly one member added"
    assert_equal 0, d["site_resolved"].size
    assert_equal 3, d["site_persisted"], "a/b/c persist; only d is new"
    assert_match(/f\.rb#d/, d["site_added"].first[0])

    # `total` semantics UNCHANGED (still finding-count, report-
    # reconciled): one finding each side, net 0.
    assert_equal 1, b["total"]
    assert_equal 1, h["total"]
    assert_equal 0, d["totals"]["delta"]
  end

  def test_site_delta_persists_pure_line_shift
    base = base_sections
    b = D.snapshot(base, RC.cluster(base))
    sh = shift_findings(base, 100)
    h = D.snapshot(sh, RC.cluster(sh))
    d = D.diff(b, h)
    assert_empty d["site_resolved"], "line shift -> no site resolved"
    assert_empty d["site_added"], "line shift -> no site added"
  end

  # ---- markdown -----------------------------------------------------

  def test_to_markdown_states_direction_and_clusters
    base = D.snapshot(base_sections, RC.cluster(base_sections))
    head = D.snapshot([["Neglected Updates", 2,
                        [{ pair: %w[provenance storage], at: "f.rb:lower:10" }]]],
                      [])
    md = D.to_markdown(D.diff(base, head))
    assert_includes md, "## Delta vs baseline"
    assert_includes md, "REDUCED"
    assert_match(/storage/, md)
  end
end
