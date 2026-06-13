require "rspec"
require_relative "../src/backends/transpiler"

# Tests that BORROWED/RESTRICT aliases (non_escaping bindings) cannot escape
# their WITH block in any of the three previously unguarded ways:
#   Gap 1: BG/DO/STREAM block capture
#   Gap 2: WITH BORROWED on @shared/@locked/@multiowned types
#   Gap 3: Field mutation assignment (s.field = ref)

RSpec.describe "BORROWED escape lockdown" do
  def annotate(src)
    tokens = Lexer.new(src).tokenize
    ast = ClearParser.new(tokens, src).parse
    PipelineRewriter.new.rewrite!(ast)
    SemanticAnnotator.new.annotate!(ast)
  end

  # =========================================================================
  # Gap 1: BG/DO/STREAM block capture
  # =========================================================================

  describe "Gap 1 - BG/DO/STREAM cannot capture WITH-scoped bindings" do
    it "BG block cannot capture a WITH BORROWED alias" do
      expect {
        annotate(<<~CLEAR)
          FN main() RETURNS Void ->
            name = "hello";
            WITH BORROWED name AS ref {
              NEXT BG { ref.length(); };
            }
            RETURN;
          END
        CLEAR
      }.to raise_error(/WITH.scoped|non.escaping|BORROWED.*fiber|fiber.*BORROWED/i)
    end

    it "BG block cannot capture a RESTRICT alias" do
      expect {
        annotate(<<~CLEAR)
          STRUCT Point { x: Float64, y: Float64 }
          FN main() RETURNS Void ->
            MUTABLE p = Point{ x: 1.0, y: 2.0 };
            WITH RESTRICT p AS MUTABLE ref {
              NEXT BG { ref.x; };
            }
            RETURN;
          END
        CLEAR
      }.to raise_error(/WITH.scoped|non.escaping|BORROWED.*fiber|fiber.*BORROWED/i)
    end

    it "DO block cannot capture a WITH BORROWED alias" do
      expect {
        annotate(<<~CLEAR)
          FN main() RETURNS Void ->
            name = "hello";
            WITH BORROWED name AS ref {
              DO { ref.length() }
            }
            RETURN;
          END
        CLEAR
      }.to raise_error(/WITH.scoped|non.escaping|BORROWED.*fiber|fiber.*DO/i)
    end

    it "BG STREAM block cannot capture a WITH BORROWED alias" do
      expect {
        annotate(<<~CLEAR)
          FN main() RETURNS Void ->
            name = "hello";
            WITH BORROWED name AS ref {
              s: ~Int64[INF] = BG STREAM { YIELD ref.length(); };
            }
            RETURN;
          END
        CLEAR
      }.to raise_error(/WITH.scoped|non.escaping|BORROWED.*fiber/i)
    end

    it "struct with BORROWED field cannot be captured by BG" do
      expect {
        annotate(<<~CLEAR)
          STRUCT SliceIter { pos: Int64, len: Int64, source: BORROWED String[] }
          FN main() RETURNS Void ->
            data: String[] = ["a", "b"];
            WITH BORROWED data AS ref {
              iter = SliceIter{ pos: 0, len: 2, source: ref };
              NEXT BG { iter.pos; };
            }
            RETURN;
          END
        CLEAR
      }.to raise_error(/WITH.scoped|non.escaping/i)
    end

    # Positive cases - BG without borrowed captures is fine
    it "BG block capturing a regular (non-borrowed) variable is still allowed" do
      expect { annotate(<<~CLEAR) }.not_to raise_error
        FN main() RETURNS Void ->
          name = "hello";
          n = NEXT BG { name.length(); };
          RETURN;
        END
      CLEAR
    end

    it "WITH BORROWED followed by BG after block exits is allowed" do
      expect { annotate(<<~CLEAR) }.not_to raise_error
        FN main() RETURNS Void ->
          name = "hello";
          WITH BORROWED name AS ref {
            n = ref.length();
          }
          m = NEXT BG { name.length(); };
          RETURN;
        END
      CLEAR
    end
  end

  # =========================================================================
  # Gap 2: BORROWED on @shared/@locked/@multiowned
  # =========================================================================

  describe "Gap 2 - BORROWED rejected on shared/synchronized types" do
    it "cannot WITH BORROWED a @shared variable" do
      expect {
        annotate(<<~CLEAR)
          STRUCT Counter { value: Int64 }
          FN main() RETURNS Void ->
            c: Counter = Counter{ value: 0 } @shared;
            WITH BORROWED c AS ref {
              n = ref.value;
            }
            RETURN;
          END
        CLEAR
      }.to raise_error(/@shared|BORROWED.*shared|shared.*BORROWED/i)
    end

    it "cannot WITH BORROWED a @locked variable" do
      expect {
        annotate(<<~CLEAR)
          STRUCT Counter { value: Int64 }
          FN main() RETURNS Void ->
            c: Counter = Counter{ value: 0 } @locked;
            WITH BORROWED c AS ref {
              n = ref.value;
            }
            RETURN;
          END
        CLEAR
      }.to raise_error(/@locked|BORROWED.*locked|locked.*BORROWED/i)
    end

    it "cannot WITH BORROWED a @multiowned variable" do
      expect {
        annotate(<<~CLEAR)
          STRUCT Node { value: Int64 }
          FN main() RETURNS Void ->
            n = Node{ value: 1 } @multiowned;
            WITH BORROWED n AS ref {
              x = ref.value;
            }
            RETURN;
          END
        CLEAR
      }.to raise_error(/@multiowned|BORROWED.*multiowned|multiowned.*BORROWED/i)
    end

    # Positive cases - plain and heap structs can still be BORROWED
    it "plain struct (frame) can still be BORROWED" do
      expect { annotate(<<~CLEAR) }.not_to raise_error
        STRUCT Point { x: Float64 }
        FN main() RETURNS Void ->
          p = Point{ x: 1.0 };
          WITH BORROWED p AS ref {
            n = ref.x;
          }
          RETURN;
        END
      CLEAR
    end

    it "heap struct can still be BORROWED" do
      expect { annotate(<<~CLEAR) }.not_to raise_error
        STRUCT Node { id: Int64 }
        FN main() RETURNS Void ->
          n: Node @indirect = Node{ id: 1 };
          WITH BORROWED n AS ref {
            x = ref.id;
          }
          RETURN;
        END
      CLEAR
    end

    it "string can still be BORROWED" do
      expect { annotate(<<~CLEAR) }.not_to raise_error
        FN main() RETURNS Void ->
          s = "hello";
          WITH BORROWED s AS ref {
            n = ref.length();
          }
          RETURN;
        END
      CLEAR
    end
  end

  # =========================================================================
  # Gap 3: Field mutation bypasses non_escaping check
  # =========================================================================

  describe "Gap 3 - field mutation cannot store a WITH-scoped alias" do
    it "cannot assign a BORROWED struct alias into a mutable struct field" do
      expect {
        annotate(<<~CLEAR)
          STRUCT Inner { x: Int64 }
          STRUCT Outer { inner: Inner }
          FN main() RETURNS Void ->
            MUTABLE o = Outer{ inner: Inner{ x: 1 } };
            inner2 = Inner{ x: 2 };
            WITH BORROWED inner2 AS ref {
              o.inner = ref;
            }
            RETURN;
          END
        CLEAR
      }.to raise_error(/WITH.scoped|non.escaping|cannot store|cannot move/i)
    end

    # Positive case - Copy-type field assignment of a borrowed scalar value is safe
    it "Copy-type field assignment of a borrowed Int64 value is allowed" do
      expect { annotate(<<~CLEAR) }.not_to raise_error
        STRUCT Counter { value: Int64 }
        FN main() RETURNS Void ->
          MUTABLE c = Counter{ value: 0 };
          n = 42;
          WITH BORROWED n AS ref {
            c.value = ref;
          }
          RETURN;
        END
      CLEAR
    end
  end
end
