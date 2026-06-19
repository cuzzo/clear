# frozen_string_literal: true

require "minitest/autorun"
require "tempfile"
require "json"
require_relative "../lib/decomplex"
require_relative "../lib/decomplex/state_mesh"

class StateMeshTest < Minitest::Test
  # Keep tempfiles alive during the test so SemanticAlias (re-reads from
  # disk) and any other re-scans can find them. Teardown cleans up.
  def setup
    @tempfiles = []
  end

  def teardown
    @tempfiles.each(&:unlink)
  end

  # Scan: write ruby to a tempfile, keep it alive, return the StateMesh.
  def scan(ruby, min_writes: 2, custom_fields: nil)
    f = Tempfile.new(["sm", ".rb"])
    f.write(ruby)
    f.close
    @tempfiles << f
    sm = Decomplex::StateMesh.scan([f.path],
                                   min_writes: min_writes,
                                   custom_fields: custom_fields)
    sm.run
    sm
  end

  # Build reification miss fixtures for Phase 4 testing.
  def reification_misses(field_name, raw_text, canon_text, predicate: "frame?")
    [{ predicate: predicate, canon: canon_text, raw: raw_text,
       at: "test.rb:check:5" }]
  end

  # ---- Phase 1+2: write discovery --------------------------------------

  def test_discover_attr_writes
    sm = scan(<<~RB)
      def a(x); x.storage = :heap; end
      def b(x); x.storage = :frame; end
      def c(x); x.storage = :heap; end
    RB
    refute_empty sm.writes
    assert_equal 3, sm.writes.size
    sm.writes.each { |w| assert_equal "storage", w.norm }
  end

  def test_scan_uses_syntax_facts_for_writes_and_reads
    f = Tempfile.new(["sm", ".rb"])
    f.write(<<~RB)
      def a(x); x.storage = :heap; end
      def b(x); x.storage = :frame; end
      def c(x); use(x.storage); end
    RB
    f.close
    @tempfiles << f
    no_misses = Struct.new(:reification_misses).new([])

    Decomplex::Ast.stub(:parse, ->(*) { raise "legacy Ast.parse should not be used" }) do
      Decomplex::SemanticAlias.stub(:scan, ->(*) { no_misses }) do
        sm = Decomplex::StateMesh.scan([f.path])
        sm.run

        assert_equal 2, sm.writes.size
        assert_equal 1, sm.reads.size
      end
    end
  end

  def test_discover_ivar_writes
    sm = scan(<<~RB)
      def a; @storage = :heap; end
      def b; @storage = :frame; end
    RB
    assert_equal 2, sm.writes.size
    sm.writes.each { |w| assert_equal "storage", w.norm }
  end

  def test_discover_mixed_attr_and_ivar
    sm = scan(<<~RB)
      def a(x); x.storage = :heap; end
      def b; @storage = :frame; end
      def c(x); x.storage = :heap; end
    RB
    assert_equal 3, sm.writes.size
    norms = sm.writes.map(&:norm).uniq
    assert_equal ["storage"], norms
  end

  def test_single_write_is_below_threshold
    sm = scan(<<~RB)
      def a; @storage = :heap; end
    RB
    assert sm.writes.size >= 1
    assert sm.known_field_norms.empty?
  end

  def test_custom_fields_bypass_threshold
    sm = scan(<<~RB, custom_fields: ["storage"])
      def a; @storage = :heap; end
    RB
    refute_empty sm.known_field_norms
    assert_includes sm.known_field_norms, "storage"
  end

  # ---- Phase 3: read discovery -----------------------------------------

  def test_discover_attr_reads
    sm = scan(<<~RB)
      def a(x); x.storage = :heap; end
      def b(x); x.storage = :frame; end
      def c(x); use(x.storage); end
      def d; x = @storage; use(x); end
    RB
    assert_equal 2, sm.reads.size
    norms = sm.reads.map(&:norm)
    assert_includes norms, "storage"
  end

  def test_discover_ivar_reads
    sm = scan(<<~RB)
      def a; @storage = :heap; end
      def b(x); x.storage = :heap; end
      def c; use(@storage); end
    RB
    refute_empty sm.reads
    assert_equal 1, sm.reads.size
    assert_equal "self", sm.reads.first.recv
  end

  def test_method_call_same_name_is_not_a_read
    sm = scan(<<~RB)
      def a; x.storage = :heap; end
      def b; x.storage = :frame; end
      def c; storage(:arg); end
    RB
    assert sm.reads.empty?,
           "method call with args should not be counted as read"
  end

  def test_vcall_not_counted_as_read
    sm = scan(<<~RB)
      def a; x.storage = :heap; end
      def b; x.storage = :frame; end
      def c; storage; end
    RB
    assert sm.reads.empty?,
           "receiverless VCALL should not be counted as read"
  end

  def test_reads_in_multiple_methods
    sm = scan(<<~RB)
      def a(x); x.storage = :heap; end
      def b; x.storage = :heap; end
      def c(x); use(x.storage); end
      def d; use(@storage); end
    RB
    assert_equal 2, sm.reads.size
  end

  # ---- Phase 4: re-derivation via reification misses -------------------

  def test_re_derivation_detected
    sm = scan(<<~RB, min_writes: 1, custom_fields: ["provenance"])
      def frame?; @provenance == :frame; end
      def check(x)
        x.provenance = :heap
      end
    RB
    # Inject pre-computed reification misses.
    misses = reification_misses("provenance",
                                "x.provenance == :frame",
                                "provenance == :frame")
    sm.find_re_derivations!(misses)
    assert sm.re_derivations.size >= 1,
           "expected at least one re-derivation, got #{sm.re_derivations.size}"
    if sm.re_derivations.size >= 1
      rd = sm.re_derivations.first
      assert_equal "provenance", rd.field
    end
  end

  def test_re_derivation_no_match_when_field_not_involved
    sm = scan(<<~RB, min_writes: 1, custom_fields: ["storage"])
      def frame?; @provenance == :frame; end
      def check(x)
        x.storage = :heap
      end
    RB
    # Reification miss about "provenance", but we track "storage".
    misses = reification_misses("provenance",
                                "x.provenance == :frame",
                                "provenance == :frame")
    sm.find_re_derivations!(misses)
    assert sm.re_derivations.empty?,
           "re-derivation should not match if field name not in raw/canon"
  end

  # ---- Phase 5: metrics ------------------------------------------------

  def test_metrics_computed
    sm = scan(<<~RB)
      def a(x); x.storage = :heap; end
      def b(x); x.storage = :frame; end
      def c(x); use(x.storage); end
    RB
    metrics = sm.metrics
    refute_empty metrics
    m = metrics.find { |m| m.name == "storage" }
    refute_nil m
    assert_equal 2, m.writes
    assert_equal 1, m.reads
    assert m.messiness > 0
    assert_equal 1, m.rank
  end

  def test_multiple_fields_ranked
    sm = scan(<<~RB, min_writes: 1)
      def a(x); x.storage = :heap; end
      def b(x); x.storage = :frame; end
      def c(x); x.provenance = :heap; end
      def d(x); x.provenance = :frame; end
      def e(x); use(x.storage); use(x.storage); end
    RB
    metrics = sm.metrics
    assert_equal 2, metrics.size
    storage_m = metrics.find { |m| m.name == "storage" }
    prov_m    = metrics.find { |m| m.name == "provenance" }
    refute_nil storage_m
    refute_nil prov_m
    # storage has more reads, should rank higher
    assert storage_m.rank < prov_m.rank,
           "storage (#{storage_m.writes}w+#{storage_m.reads}r) should rank "\
           "higher than provenance (#{prov_m.writes}w+#{prov_m.reads}r)"
  end

  # ---- Phase 6: JSON graph ---------------------------------------------

  def test_json_graph_structure
    sm = scan(<<~RB)
      def a(x); x.storage = :heap; end
      def b(x); x.storage = :frame; end
      def c(x); use(x.storage); end
    RB
    graph = sm.to_json_graph

    assert graph.key?("state_mesh")
    assert graph.key?("fields")
    assert graph.key?("hierarchy")

    smeta = graph["state_mesh"]
    assert smeta["total_fields"] >= 1
    assert smeta["total_writes"] >= 2
    assert smeta["total_reads"] >= 1

    assert graph["fields"].key?("storage")
    f = graph["fields"]["storage"]
    assert f.key?("messiness")
    assert f.key?("writers")
    assert f.key?("readers")
    assert f.key?("re_derivations")
    assert f.key?("metrics")
  end

  def test_json_graph_hierarchy_has_dir_file_defn
    sm = scan(<<~RB)
      def a(x); x.storage = :heap; end
      def b(x); x.storage = :frame; end
      def c(x); use(x.storage); end
    RB
    graph = sm.to_json_graph
    hierarchy = graph["hierarchy"]
    refute_empty hierarchy

    dir = hierarchy.first
    assert dir.key?("name")
    assert dir.key?("files")
    refute_empty dir["files"]

    file = dir["files"].first
    assert file.key?("name")
    assert file.key?("defns")

    defn = file["defns"].first
    assert defn.key?("name")
    assert defn.key?("writers")
    assert defn.key?("readers")
    assert defn.key?("fields")
    assert defn["fields"].key?("written")
    assert defn["fields"].key?("read")
  end

  def test_json_graph_counts_aggregate_up
    sm = scan(<<~RB)
      def a(x); x.storage = :heap; end
      def b(x); x.storage = :frame; end
      def c(x); use(x.storage); end
    RB
    graph = sm.to_json_graph
    hierarchy = graph["hierarchy"]

    total_w = hierarchy.sum { |d| d["files"].sum { |f| f["writers"] } }
    total_r = hierarchy.sum { |d| d["files"].sum { |f| f["readers"] } }

    assert total_w >= 2
    assert total_r >= 1
  end

  # ---- Edge cases ------------------------------------------------------

  def test_no_writes_means_no_fields
    sm = scan(<<~RB)
      def a(x); use(x.storage); end
    RB
    assert sm.known_field_norms.empty?
    assert sm.metrics.empty?
  end

  def test_indexed_assignment_not_mined
    sm = scan(<<~RB)
      def a; h = {}; h[:k] = 1; h[:k] = 2; end
      def b; h = {}; h[:k] = 3; end
    RB
    refute_includes sm.known_field_norms, "k"
    refute_includes sm.known_field_norms, "[]"
  end

  def test_empty_file
    sm = scan("")
    assert sm.writes.empty?
    assert sm.reads.empty?
    assert sm.known_field_norms.empty?
  end

  def test_top_level_writes
    sm = scan(<<~RB)
      @storage = :heap
      @storage = :frame
    RB
    refute_empty sm.writes
    assert_equal 2, sm.writes.size
    assert_includes sm.known_field_norms, "storage"
  end

  # ---- JSON output contains full reader/writer detail per field --------

  def test_json_graph_field_reader_writer_detail
    sm = scan(<<~RB)
      def a(x); x.storage = :heap; end
      def b(x); x.storage = :frame; end
      def c(x); use(x.storage); end
    RB
    graph = sm.to_json_graph
    f = graph["fields"]["storage"]
    assert_equal 2, f["writers"].size
    assert_equal 1, f["readers"].size
    assert f["writers"].all? { |w| w.key?("file") && w.key?("defn") && w.key?("line") }
    assert f["readers"].all? { |r| r.key?("file") && r.key?("defn") && r.key?("line") }
    assert f["metrics"].key?("writes")
    assert f["metrics"].key?("reads")
    assert f["metrics"].key?("scatter")
    assert f["metrics"].key?("percentiles")
  end

  # ---- Normalization ----------------------------------------------------

  def test_normalize_strips_at
    sm = Decomplex::StateMesh.new({})
    assert_equal "storage", sm.normalize("@storage")
    assert_equal "storage", sm.normalize("storage")
    assert_equal "provenance", sm.normalize("@provenance")
  end
end
