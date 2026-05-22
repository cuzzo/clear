require "rspec"

# Static-analysis guard for the placement-field architecture.
#
# Storage / allocator decisions flow through a staged pipeline, and EACH
# field has exactly ONE sanctioned writer. A write from anywhere else is
# a renegade escape/placement decision -- the architectural defect that
# produces the allocator-mismatch bug class (leaks, double-frees,
# invalid frees). This test fails the build if such a write exists.
#
#   node.storage        <- annotation ONLY
#   symbol.storage      <- escape analysis ONLY
#   CleanupEntry#alloc  <- cleanup classification ONLY
#
# These invariants are non-negotiable: fixing the compiler means making
# every placement decision in its one sanctioned pass, never beside it.
RSpec.describe "architecture invariants: placement-field writers" do
  SRC = File.expand_path("../src", __dir__)

  # ── the ONE sanctioned writer of each field ─────────────────────────

  # node.storage is derived from the type during annotation.
  NODE_STORAGE_OK = lambda do |rel|
    rel == "annotator.rb" ||
      rel.start_with?("annotator-helpers/") ||
      rel == "ast/ast.rb" ||           # finalize_storage! -- the annotation mechanism
      rel == "ast/parser.rb" ||        # parse-time literal storage
      rel == "mir/alloc.rb"            # downgrade_frame_to_stack: mixed into SemanticAnnotator
  end

  # symbol.storage is made DEFINITIVE by escape analysis.
  SYMBOL_STORAGE_OK = lambda do |rel|
    rel == "mir/escape_graph.rb" || rel == "mir/escape_analysis.rb"
  end

  # CleanupEntry#alloc is set once, by cleanup classification.
  CLEANUP_ALLOC_OK = lambda do |rel|
    rel == "mir/promotion_plan.rb" || rel == "mir/cleanup_entry.rb"
  end

  # ── scan every source file for placement-field writes ───────────────

  def self.scan
    node_w = []
    sym_w = []
    cleanup_w = []
    Dir[File.join(SRC, "**", "*.rb")].sort.each do |path|
      rel = path.sub(SRC + "/", "")
      File.readlines(path).each_with_index do |line, idx|
        next if line.strip.start_with?("#")          # skip comment lines
        loc = "#{rel}:#{idx + 1}"
        code = line.strip

        if (m = line.match(/([\w.\[\]]*)\.storage\s*=(?![=~])/))
          recv = m[1]
          symbol_write = recv.end_with?(".symbol") ||
                         %w[sym symbol node_sym decl_sym entry sym_entry].include?(recv)
          (symbol_write ? sym_w : node_w) << [loc, code]
        end

        # CleanupEntry is a typed Hash-subclass written via [:alloc]=.
        # Restrict to entry/cleanup-named receivers so plain Hashes
        # (effects[:alloc], resolved_allocs[:alloc]) are not flagged.
        if line.match(/\b\w*(?:entry|cleanup)\w*\[:alloc\]\s*=(?![=~])/i)
          cleanup_w << [loc, code]
        end
      end
    end
    { node: node_w, symbol: sym_w, cleanup: cleanup_w }
  end

  WRITES = scan

  def renegades(list, sanctioned)
    list.reject { |loc, _| sanctioned.call(loc.split(":").first) }
  end

  def report(label, bad)
    "#{bad.size} renegade #{label} write(s) -- must move to the sanctioned pass:\n" +
      bad.map { |loc, code| "  #{loc}\n      #{code}" }.join("\n")
  end

  it "node.storage is written ONLY by annotation" do
    bad = renegades(WRITES[:node], NODE_STORAGE_OK)
    expect(bad).to be_empty, report("node.storage", bad)
  end

  it "symbol.storage is written ONLY by escape analysis" do
    bad = renegades(WRITES[:symbol], SYMBOL_STORAGE_OK)
    expect(bad).to be_empty, report("symbol.storage", bad)
  end

  it "CleanupEntry#alloc is written ONLY by cleanup classification" do
    bad = renegades(WRITES[:cleanup], CLEANUP_ALLOC_OK)
    expect(bad).to be_empty, report("CleanupEntry#alloc", bad)
  end
end
