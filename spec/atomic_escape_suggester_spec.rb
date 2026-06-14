require "rspec"
require_relative "../src/tools/atomic_escape_suggester" unless defined?(AtomicEscapeSuggester)

# Atomics M2.9 -- doctor-side static detector for @shared:atomic
# escape patterns. Runs the annotator with FixCollector enabled
# and surfaces the M2.8 fixable findings in a plain-language
# format the doctor section can render. Tests cover (1) every
# supported escape kind produces a finding, (2) compiling sources
# return empty, (3) parse errors are swallowed.
RSpec.describe "AtomicEscapeSuggester (M2.9 static escape diagnosis)" do
  def findings(src)
    AtomicEscapeSuggester.analyze(src)
  end

  describe "positive cases" do
    it "flags RETURN of a BG handle that captured @shared:atomic without RETURNS x:T" do
      fs = findings(<<~CLEAR)
        FN spawnBumper() RETURNS ~Void ->
          counter: Int64 = 0 @shared:atomic;
          bg = BG { v = counter; print(v.toString()); };
          RETURN bg;
        END
      CLEAR
      expect(fs).not_to be_empty
      expect(fs.first[:kind]).to eq(:return)
      expect(fs.first[:message]).to match(/RETURN.*lifetime is tied/i)
    end

    it "flags RETURN escape even when the BG handle is bound to an explicit name" do
      fs = findings(<<~CLEAR)
        FN spawn() RETURNS ~Void ->
          c: Int64 = 0 @shared:atomic;
          handle = BG { x = c; print(x.toString()); };
          RETURN handle;
        END
      CLEAR
      expect(fs.size).to be >= 1
      expect(fs.first[:kind]).to eq(:return)
    end

    it "carries a line number and message text from the underlying finding" do
      fs = findings(<<~CLEAR)
        FN spawn() RETURNS ~Void ->
          c: Int64 = 0 @shared:atomic;
          bg = BG { v = c; print(v.toString()); };
          RETURN bg;
        END
      CLEAR
      expect(fs.first[:line]).to be > 0
      expect(fs.first[:message]).to be_a(String)
      expect(fs.first[:message]).to include("Lifetime Error")
    end

    it "classifies non-RETURN escape findings as stores" do
      token = Struct.new(:line, :column).new(7, 11)
      finding = Struct.new(:message, :token).new("Lifetime Error: captured value escapes through a field store", token)

      expect(AtomicEscapeSuggester.to_hash(finding)).to include(
        line: 7,
        col: 11,
        kind: :store,
      )
    end
  end

  describe "negative cases" do
    it "returns empty for a bare @shared:atomic with no escape" do
      fs = findings(<<~CLEAR)
        FN bump() RETURNS Void ->
          c: Int64 = 0 @shared:atomic;
          c.fetchAdd(1);
          RETURN;
        END
      CLEAR
      expect(fs).to be_empty
    end

    it "returns empty for code with no @shared:atomic at all" do
      fs = findings(<<~CLEAR)
        FN noAtomic() RETURNS Int64 ->
          x = 1 + 2;
          RETURN x;
        END
      CLEAR
      expect(fs).to be_empty
    end

    it "swallows parse errors and returns []" do
      expect(findings("INVALID CLEAR SOURCE !!!")).to eq([])
    end

    it "swallows lex errors and returns []" do
      expect(findings("\xff\xfe")).to eq([])
    end
  end
end
