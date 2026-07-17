require "rspec"
require_relative "../ruby/ast/lexer" unless defined?(Lexer)
require_relative "../ruby/ast/parser" unless defined?(ClearParser)
require_relative "../ruby/ast/ast" unless defined?(MIR::ReassignPlan)
require_relative "../ruby/ast/fixable_error" unless defined?(FixCollector)
require_relative "../ruby/backends/transpiler" unless defined?(ZigTranspiler)

# Effect / REQUIRES / reentrant-variant typos. Six parser sites that
# previously raised plain ParserErrors now offer typo suggestions:
#   :alloc / :safe                                   -> UNKNOWN_EFFECT
#   :alloc:frame / :alloc:heap                       -> UNKNOWN_ALLOC_QUALIFIER
#   EFFECTS REENTRANT                                -> UNKNOWN_FN_EFFECT
#   REQUIRES p: <FAMILY|KIND>                        -> UNKNOWN_REQUIRES_FAMILY
#   REQUIRES p: NON_REENTRANT                        -> UNKNOWN_REQUIRES_KIND
#   EFFECTS REENTRANT:THUNK|TAIL_CALL|NOT_LOGICAL... -> UNKNOWN_REENTRANT_VARIANT
RSpec.describe "Effect / REQUIRES / reentrant typo auto-fixes" do
  before { FixCollector.enable! }
  after  { FixCollector.disable! }

  def parse(source)
    tokens = Lexer.new(source).tokenize
    ClearParser.new(tokens, source).parse
  end

  describe "UNKNOWN_EFFECT — `:saf` typo for `:safe`" do
    let(:src) {
      'EXTERN FN sha(s: String) RETURNS String EFFECTS :saf FROM "std.crypto";'
    }
    it "suggests :safe" do
      parse(src) rescue nil
      finding = FixCollector.drain.find { |f| f.message =~ /:saf'/ }
      expect(finding).not_to be_nil
      expect(finding.fixes.first.edits.first.replacement).to eq("safe")
    end
  end

  describe "UNKNOWN_ALLOC_QUALIFIER — `:alloc:frme` typo" do
    let(:src) {
      'EXTERN FN x() RETURNS Int64 EFFECTS :alloc:frme FROM "std.x";'
    }
    it "suggests `frame`" do
      parse(src) rescue nil
      finding = FixCollector.drain.find { |f| f.message =~ /frme/ }
      expect(finding).not_to be_nil
      expect(finding.fixes.first.edits.first.replacement).to eq("frame")
    end
  end

  describe "UNKNOWN_FN_EFFECT — `EFFECTS RENTRANT` typo" do
    let(:src) {
      <<~CLEAR
        FN factorial(n: Int64) RETURNS Int64 EFFECTS RENTRANT ->
            RETURN n;
        END
        FN main() RETURNS Void -> END
      CLEAR
    }
    it "suggests REENTRANT" do
      parse(src) rescue nil
      finding = FixCollector.drain.find { |f| f.message =~ /RENTRANT/ }
      expect(finding).not_to be_nil
      expect(finding.fixes.first.edits.first.replacement).to eq("REENTRANT")
    end
  end

  describe "UNKNOWN_REQUIRES_FAMILY — `LOKKED` typo" do
    let(:src) {
      <<~CLEAR
        FN incr(MUTABLE c: Counter) REQUIRES c: LOKKED -> END
        FN main() RETURNS Void -> END
      CLEAR
    }
    it "suggests LOCKED" do
      parse(src) rescue nil
      finding = FixCollector.drain.find { |f| f.message =~ /LOKKED/ }
      expect(finding).not_to be_nil
      expect(finding.fixes.first.edits.first.replacement).to eq("LOCKED")
    end
  end

  describe "UNKNOWN_REENTRANT_VARIANT — `EFFECTS REENTRANT:THONK` typo" do
    let(:src) {
      <<~CLEAR
        FN factorial(n: Int64) RETURNS Int64 EFFECTS REENTRANT:THONK ->
            RETURN n;
        END
        FN main() RETURNS Void -> END
      CLEAR
    }
    it "suggests THUNK" do
      parse(src) rescue nil
      finding = FixCollector.drain.find { |f| f.message =~ /THONK/ }
      expect(finding).not_to be_nil
      expect(finding.fixes.first.edits.first.replacement).to eq("THUNK")
    end
  end
end
