require "rspec"
require "tmpdir"
require "fileutils"
require "stringio"

require_relative "../ruby/tools/clear_fix_support" unless defined?(ClearFixSupport::LocationToken)

RSpec.describe ClearFixSupport do
  def messages_for(source, only: nil)
    described_class.preview_source(source, only_set: only).map(&:message)
  end

  def descriptions_for(source, only: nil)
    described_class.preview_source(source, only_set: only).flat_map { |finding| finding.fixes.map(&:description) }
  end

  def apply_fix(source, take_first: false, only: nil)
    rewritten, count, findings = described_class.apply_to_source(source, take_first: take_first, only_set: only)
    [rewritten, count, findings.map(&:message)]
  end

  def expect_rewrite(source, expected, take_first: false, only: nil, count: 1)
    rewritten, edits, = apply_fix(source, take_first: take_first, only: only)
    expect(edits).to eq(count)
    expect(rewritten).to eq(expected)
  end

  it "parses CLI options and rejects invalid combinations" do
    options = described_class.parse_args(["--yes", "--auto", "--loop=3", "--only=lint,ownership", "a.clear", "b.rb"])
    expect(options.take_first).to be(true)
    expect(options.auto_only).to be(true)
    expect(options.loop_until_clean).to be(true)
    expect(options.loop_max).to eq(3)
    expect(options.propagate_fallibility).to be(false)
    expect(options.only_set).to eq(Set[:lint, :ownership])
    expect(options.paths).to eq(["a.clear", "b.rb"])

    expect(described_class.parse_args(["--loop", "a.clear"]).loop_max).to eq(20)
    expect(described_class.parse_args(["--propagate-fallible", "a.clear"]).propagate_fallibility).to be(true)
    expect { described_class.parse_args([]) }.to raise_error(described_class::UsageError, /Usage: clear fix/)
    expect { described_class.parse_args(["--unknown", "a.clear"]) }.to raise_error(described_class::UsageError, /Unknown flag/)
    expect { described_class.parse_args(["--loop", "--dry-run", "a.clear"]) }.to raise_error(
      described_class::UsageError,
      /mutually exclusive/
    )
  end


  it "optionally makes fallibility explicit through the caller chain" do
    source = <<~CLEAR
      FN parseValue(text: String) RETURNS Int64 ->
        RETURN text.toInt();
      END

      FN addOne(text: String) RETURNS Int64 ->
        RETURN parseValue(text) + 1_i64;
      END
    CLEAR
    expected = <<~CLEAR
      FN parseValue(text: String) RETURNS !Int64 ->
        RETURN TRY (text.toInt());
      END

      FN addOne(text: String) RETURNS !Int64 ->
        RETURN TRY (parseValue(text)) + 1_i64;
      END
    CLEAR

    rewritten, edits, = described_class.apply_to_source(
      source, take_first: true, propagate_fallibility: true
    )
    expect(edits).to eq(6)
    expect(rewritten).to eq(expected)
  end

  it "reports no findings for clean source and supports category filtering" do
    clean = "FN main() RETURNS Int64 ->\n  x = 42;\n  RETURN x;\nEND\n"
    expect(described_class.preview_source(clean)).to be_empty

    linty = "FN main() RETURNS Int64 ->\n  MUTABLE x = 42;\n  RETURN x;\nEND\n"
    expect(messages_for(linty, only: Set[:lint]).join("\n")).to include("MUTABLE 'x' is never reassigned")
    expect(messages_for(linty, only: Set[:ownership])).to be_empty
  end

  it "offers explicit asynchronous binding choices" do
    future_source = <<~CLEAR
      FN main() RETURNS Void ->
        future = BG { 7; };
        RETURN;
      END
    CLEAR
    stream_source = <<~CLEAR
      FN produce() RETURNS [~]Int64 ->
        RETURN BG STREAM { YIELD 7; CLOSE; };
      END
      FN main() RETURNS Void ->
        result = produce();
        RETURN;
      END
    CLEAR

    future_findings = described_class.preview_source(future_source)
    expect(future_findings.map(&:message).join("\n")).to include("Cannot infer `future` from an asynchronous value.")
    expect(future_findings.flat_map { |finding| finding.fixes.map(&:description) })
      .to include("Consume the future with NEXT.", "Retain the future deliberately.")

    stream_findings = described_class.preview_source(stream_source)
    expect(stream_findings.map(&:message).join("\n")).to include("Cannot infer `result` from an asynchronous value.")
    expect(stream_findings.flat_map { |finding| finding.fixes.map(&:description) })
      .to include("Retain the stream deliberately.")
  end

  it "wraps an optional pipeline before inserting UNWRAP" do
    source = <<~CLEAR
      FN main() RETURNS Void ->
        nums: []Float64 = [1.0, 4.0];
        found = nums |> FIND _ > 3.0;
        ASSERT found == 4.0;
      END
    CLEAR

    rewritten, edits, = apply_fix(source, take_first: true, only: Set[:type])

    expect(edits).to eq(2)
    expect(rewritten).to include("found = UNWRAP (nums |> FIND _ > 3.0);")
    expect(described_class.preview_source(rewritten, only_set: Set[:type])).to be_empty
  end

  it "applies lint and ownership fixes to exact golden source" do
    expect_rewrite(
      "FN main() RETURNS Int64 ->\n  MUTABLE x = 42;\n  RETURN x;\nEND\n",
      "FN main() RETURNS Int64 ->\n  x = 42;\n  RETURN x;\nEND\n"
    )

    expect_rewrite(
      "FN main() RETURNS Int64 ->\n  x = 1;\n  x = 2;\n  RETURN x;\nEND\n",
      "FN main() RETURNS Int64 ->\n  MUTABLE x = 1;\n  x = 2;\n  RETURN x;\nEND\n"
    )

    source = <<~CLEAR
      FN main() RETURNS Int64 ->
        x = 1;
        x = 2;
        y = 10;
        y = 20;
        RETURN x + y;
      END
    CLEAR
    expected = <<~CLEAR
      FN main() RETURNS Int64 ->
        MUTABLE x = 1;
        x = 2;
        MUTABLE y = 10;
        y = 20;
        RETURN x + y;
      END
    CLEAR
    expect_rewrite(source, expected, count: 2)
  end

  it "applies registry, member, and binding typo fixes to exact golden source" do
    registry_source = <<~CLEAR
      FN bad() RETURNS !Int64 -> RAISE Transient, "oops"; RETURN 0; END

      FN main() RETURNS Int64 ->
        x = bad() OR_ELSE EXIT "boom";
        RETURN x;
      CATCH LockTimout
        RETURN -1;
      END
    CLEAR
    registry_expected = registry_source.sub("LockTimout", "LockTimeout")
    expect_rewrite(registry_source, registry_expected)

    method_source = <<~CLEAR
      FN main() RETURNS Int64 ->
        m: HashMap<Int64> = {"a": 1};
        RETURN m.coutn();
      END
    CLEAR
    method_expected = method_source.sub("HashMap<Int64>", "{String}Int64").sub("coutn", "count")
    expect_rewrite(method_source, method_expected, count: 2)

    var_source = <<~CLEAR
      FN main() RETURNS Int64 ->
        message = "hi";
        RETURN messaje.length();
      END
    CLEAR
    expect(descriptions_for(var_source).join("\n")).to include("Replace 'messaje' with 'message'")

    fn_source = <<~CLEAR
      FN doThing() RETURNS Int64 -> RETURN 42; END
      FN main() RETURNS Int64 ->
        RETURN doTing();
      END
    CLEAR
    expect(descriptions_for(fn_source).join("\n")).to include("Replace 'doTing' with 'doThing'")
  end

  it "applies capability, mutable-argument, and moved-value fixes" do
    local_source = <<~CLEAR
      STRUCT Counter {value: Int64}
      FN main() RETURNS Int64 ->
        MUTABLE c = Counter {value: 0} @local;
        c.value = c.value + 1;
        RETURN c.value;
      END
    CLEAR
    local_expected = local_source.sub(" @local", "")
    expect_rewrite(local_source, local_expected)

    legacy_bang = "!"
    arg_source = <<~CLEAR
      FN bump#{legacy_bang}(MUTABLE x: Int64) RETURNS Int64 ->
        x = x + 1;
        RETURN x;
      END

      FN main() RETURNS Int64 ->
        y = 5;
        RETURN bump#{legacy_bang}(y);
      END
    CLEAR
    # apply_to_source is deliberately one pass: lexical repair makes the
    # program parseable; `clear fix --loop` performs the signature-aware
    # MUTABLE/& rewrite on its next pass (covered by the Markdown test).
    arg_expected = arg_source.gsub("bump!", "bump")
    expect_rewrite(arg_source, arg_expected, count: 2)

    moved_source = <<~CLEAR
      STRUCT Config {id: Float64, data: HashMap<Float64>}

      FN main() RETURNS Void ->
        a = Config {id: 1.0, data: {"x": 1.0}};
        b = a;
        c = a;
        RETURN;
      END
    CLEAR
    expected = moved_source.sub("HashMap<Float64>", "{String}Float64").sub("b = a;", "b = (COPY a);")
    expect_rewrite(moved_source, expected, take_first: true, count: 2)
    expect(descriptions_for(moved_source).join("\n")).to include("Change 'a' to `@shared`")
  end

  it "applies type, struct-field, enum, and union variant fixes" do
    expect_rewrite(
      "FN main() RETURNS UInt16 ->\n  x: Byte = 1000;\n  RETURN x;\nEND\n",
      "FN main() RETURNS UInt16 ->\n  x: UInt16 = 1000;\n  RETURN x;\nEND\n"
    )

    struct_source = <<~CLEAR
      STRUCT Point {x: Int64, y: Int64}
      FN main() RETURNS Int64 ->
        p = Point{x: 1, yy: 2};
        RETURN p.x;
      END
    CLEAR
    expect_rewrite(struct_source, struct_source.sub("yy: 2", "y: 2"))

    enum_source = "ENUM Shape { Circle, Square }\nFN main() RETURNS Shape ->\n  RETURN Shape.Squar;\nEND\n"
    expect_rewrite(enum_source, enum_source.sub("Shape.Squar", "Shape.Square"))

    union_source = <<~CLEAR
      UNION Shape {
        Circle { radius: Float64 },
        Square { side: Float64 }
      }

      FN main() RETURNS Shape ->
        RETURN Shape.Circl{radius: 2.0};
      END
    CLEAR
    expect_rewrite(union_source, union_source.sub("Shape.Circl", "Shape.Circle"))
  end

  it "applies operator and parser syntax fixes without flagging strings or comments" do
    pipe_source = <<~CLEAR
      FN main() RETURNS Int64 ->
        total = [1, 2, 3] s> SUM _;
        RETURN total;
      END
    CLEAR
    expect_rewrite(pipe_source, pipe_source.sub("s>", "|>"))

    arrow_source = <<~CLEAR
      FN greet(n: Int64) RETURNS Int64 => RETURN n; END
      FN main() RETURNS Int64 -> RETURN greet(5); END
    CLEAR
    expect_rewrite(arrow_source, arrow_source.sub("=>", "->"))

    concat_source = <<~CLEAR
      FN main() RETURNS String ->
        RETURN "left" + "right";
      END
    CLEAR
    expect_rewrite(concat_source, concat_source.sub(" + ", " $+ "))

    safe_source = <<~CLEAR
      FN main() RETURNS Void ->
        # pipeline: s> and arrow: =>
        msg = "s> and => in a string";
        RETURN;
      END
    CLEAR
    expect(messages_for(safe_source).join("\n")).not_to include("Unknown operator")

    semicolon_source = "FN main() RETURNS Int64 ->\n  x = 42\n  RETURN x;\nEND\n"
    expect_rewrite(semicolon_source, "FN main() RETURNS Int64 ->\n  x = 42;\n  RETURN x;\nEND\n")

    then_source = <<~CLEAR
      FN main() RETURNS Int64 ->
        x = 5;
        IF x > 0
          RETURN 1;
        END
        RETURN 0;
      END
    CLEAR
    expect_rewrite(then_source, then_source.sub("IF x > 0", "IF x > 0 THEN"))
  end

  it "dedupes overlapping edits and clamps out-of-range edit spans" do
    overlapping = [
      Edit.new(span: Span.new(file: nil, line: 1, col: 3, length: 2), replacement: "X"),
      Edit.new(span: Span.new(file: nil, line: 1, col: 4, length: 1), replacement: "Y"),
      Edit.new(span: Span.new(file: nil, line: 1, col: 8, length: 0), replacement: "!")
    ]
    deduped = described_class.dedupe_overlapping_edits(overlapping)
    expect(deduped.map(&:replacement)).to eq(["X", "!"])

    edits = [
      Edit.new(span: Span.new(file: nil, line: 0, col: 1, length: 1), replacement: "skip"),
      Edit.new(span: Span.new(file: nil, line: 1, col: -2, length: 1), replacement: "A"),
      Edit.new(span: Span.new(file: nil, line: 1, col: 99, length: 2), replacement: "Z")
    ]
    expect(described_class.apply_edits("cat\n", edits)).to eq("AatZ\n")
  end

  it "extracts and rewrites CLEAR heredocs in Ruby files" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "fixture.rb")
      source = <<~RUBY
        source = <<~CLEAR
          FN main() RETURNS Int64 ->
            MUTABLE x = 1;
            RETURN x;
          END
        CLEAR
      RUBY
      File.write(path, source)

      heredocs = described_class.extract_clear_heredocs(source)
      expect(heredocs.map { |heredoc| [heredoc.start_line, heredoc.indent] }).to eq([[2, 2]])

      out = StringIO.new
      result = described_class.run_args([path], out: out, err: StringIO.new, input: StringIO.new)
      expect(result.edits_applied).to eq(1)
      expect(File.read(path)).to include("  x = 1;")
      expect(File.read(path)).not_to include("MUTABLE x = 1;")

      no_heredoc = File.join(dir, "plain.rb")
      File.write(no_heredoc, "puts 'none'\n")
      described_class.run_args([no_heredoc], out: out, err: StringIO.new, input: StringIO.new)
      expect(out.string).to include("no CLEAR code blocks found")

      raw_source = "source = <<CLEAR\nFN main() RETURNS Void ->\n  RETURN;\nEND\nCLEAR\n"
      raw_heredoc = described_class.extract_clear_heredocs(raw_source).first
      expect(raw_heredoc.content).to start_with("FN main()")
      expect(raw_heredoc.indent).to eq(0)

      expect(described_class.extract_clear_heredocs("source = <<CLEAR\nFN main() RETURNS Void ->\n")).to be_empty
    end
  end

  it "ignores CLEAR heredoc examples inside Ruby comments" do
    source = <<~RUBY
      # Example: run(<<~CLEAR)
      #   FN demo!() RETURNS Void -> PASS END
      # CLEAR
      ast = SemanticAnnotator.new.annotate!(program)
      actual = <<~CLEAR
        FN live!() RETURNS Void -> PASS END
      CLEAR
    RUBY

    blocks = described_class.extract_clear_heredocs(source)
    expect(blocks.length).to eq(1)
    expect(blocks.first.content).to include("FN live!()")
    expect(blocks.first.content).not_to include("annotate!")
  end

  it "extracts and rewrites labelled CLEAR Markdown fences only" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "guide.md")
      source = <<~MARKDOWN
        # Guide

        ```clear
        FN update!(MUTABLE value: Int64) RETURNS Void -> value = value + 1; END
        FN main() RETURNS Void ->
          value = 1;
          update!(value);
        END
        ```

        ```ruby
        update!(value)
        ```
      MARKDOWN
      File.write(path, source)

      blocks = described_class.extract_clear_markdown_fences(source)
      expect(blocks.map { |block| [block.start_line, block.indent] }).to eq([[4, 0]])

      described_class.run_args(["--loop", "--auto", "--only=mutability", path],
        out: StringIO.new, err: StringIO.new, input: StringIO.new)
      rewritten = File.read(path)
      expect(rewritten).to include("FN update(MUTABLE value: Int64)")
      expect(rewritten).to include("MUTABLE value = 1;")
      expect(rewritten).to include("update(&value);")
      expect(rewritten).to include("```ruby\nupdate!(value)")
    end
  end

  it "restores type migrations after warming REQUIRE imports" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "helper.clear"), "STRUCT Helper { value: Int64 }\n")
      source = <<~CLEAR
        REQUIRE "helper.clear";
        FN main() RETURNS Void ->
          values: Int64[]@list = [];
          RETURN;
        END
      CLEAR

      findings = described_class.collect_findings(source, source_dir: dir)
      migration = findings.find { |finding| finding.category == :type_migration }
      expect(migration&.fixes&.map(&:description)).to include("Rewrite as `[]Int64`.")
    end
  end

  it "still collects root migrations when an external package is unavailable" do
    source = <<~CLEAR
      REQUIRE "pkg:not-installed";
      values: Int64[]@list = [];
    CLEAR

    findings = described_class.collect_findings(source)
    migration = findings.find { |finding| finding.category == :type_migration }
    expect(migration&.fixes&.map(&:description)).to include("Rewrite as `[]Int64`.")
  end

  it "isolates REQUIRE warmup diagnostics and direct non-Ruby findings" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "helper.clear"), "STRUCT Helper { value: Int64 }\n")
      source = <<~CLEAR
        REQUIRE "helper.clear";
        values: Int64[]@list = [];
        missing = unknownName;
      CLEAR

      findings = described_class.collect_findings(source, source_dir: dir)
      expect(findings.map(&:category)).to include(:type_migration)

      direct = described_class.send(
        :findings_for_path,
        File.join(dir, "sample.clear"),
        "values: Int64[]@list = [];\n",
        out: StringIO.new,
        only_set: nil,
      )
      expect(direct.map(&:category)).to include(:type_migration)
    end
  end

  it "always restores collectors after malformed full and migration-only input" do
    expect(described_class.collect_findings('value = "unterminated')).to eq([])
    expect(described_class.collect_type_migrations('value = "unterminated')).to eq([])
    expect(FixCollector.enabled?).to be(false)
  end

  it "skips malformed CLEAR heredocs without aborting a bulk fix run" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "negative_spec.rb")
      File.write(path, <<~RUBY)
        source = <<~CLEAR
          value = "unterminated;
        CLEAR
      RUBY

      result = described_class.run_args(
        ["--only=type_migration", path],
        out: StringIO.new,
        err: StringIO.new,
        input: StringIO.new,
      )
      expect(result.edits_applied).to eq(0)
    end
  end

  it "drains findings when a pre-parser lint encounters malformed tokens" do
    expect(described_class.collect_findings('"unterminated')).to eq([])
  end

  it "runs isolated type migrations without invoking semantic annotation" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "legacy.clear")
      File.write(path, "values: Int64[]@list = [];\n")
      allow(SemanticAnnotator).to receive(:new).and_raise("annotation must not run")

      result = described_class.run_args(
        ["--only=type_migration", path],
        out: StringIO.new,
        err: StringIO.new,
        input: StringIO.new,
      )
      expect(result.edits_applied).to eq(1)
      expect(File.read(path)).to eq("values: []Int64 = [];\n")
    end
  end

  it "prints dry-run findings, prompts for interactive choices, and loops until clean" do
    source = "FN main() RETURNS Int64 ->\n  MUTABLE x = 1;\n  RETURN x;\nEND\n"
    findings = described_class.preview_source(source)
    out = StringIO.new
    described_class.describe_finding(findings.first, out: out)
    expect(out.string).to include("[lint] MUTABLE 'x' is never reassigned")
    expect(out.string).to include("* [1] Remove MUTABLE keyword")

    manual = FixableFinding.new(
      level: :warning,
      message: "manual",
      token: ClearFixSupport::LocationToken.new(line: 1, column: 1),
      category: :lint,
      fixes: [
        Fix.new(description: "first", confidence: :interactive, edits: [Edit.new(span: Span.new(file: nil, line: 1, col: 1, length: 0), replacement: "a")]),
        Fix.new(description: "second", confidence: :interactive, edits: [Edit.new(span: Span.new(file: nil, line: 1, col: 1, length: 0), replacement: "b")])
      ]
    )
    expect(described_class.prompt_choice(manual, err: StringIO.new, input: StringIO.new("2\n"))&.description).to eq("second")
    expect(described_class.prompt_choice(manual, err: StringIO.new, input: StringIO.new("0\n"))).to be_nil
    expect(described_class.prompt_choice(manual, err: StringIO.new, input: StringIO.new("\n"))).to be_nil

    Dir.mktmpdir do |dir|
      path = File.join(dir, "loop.clear")
      File.write(path, source)
      loop_out = StringIO.new
      result = described_class.run_args(["--loop=3", path], out: loop_out, err: StringIO.new, input: StringIO.new)
      expect(result.edits_applied).to eq(1)
      expect(result.passes).to eq(2)
      expect(loop_out.string).to include("[fix --loop] converged after 2 pass(es)")
      expect(File.read(path)).to include("  x = 1;")

      dry_path = File.join(dir, "dry.clear")
      File.write(dry_path, source)
      dry_out = StringIO.new
      described_class.run_args(["--dry-run", dry_path], out: dry_out, err: StringIO.new, input: StringIO.new)
      expect(dry_out.string).to include("Remove MUTABLE keyword")
      expect(File.read(dry_path)).to include("MUTABLE x = 1")

      max_path = File.join(dir, "max.clear")
      File.write(max_path, source)
      max_out = StringIO.new
      max_result = described_class.run_args(["--loop=1", max_path], out: max_out, err: StringIO.new, input: StringIO.new)
      expect(max_result.passes).to eq(1)
      expect(max_out.string).to include("[fix --loop] hit loop_max=1")

      moved_path = File.join(dir, "moved.clear")
      File.write(moved_path, <<~CLEAR)
        STRUCT Config {id: Float64, data: {String}Float64}

        FN main() RETURNS Void ->
          a = Config {id: 1.0, data: {"x": 1.0}};
          b = a;
          c = a;
          RETURN;
        END
      CLEAR
      prompt_out = StringIO.new
      described_class.run_args([moved_path], out: prompt_out, err: StringIO.new, input: StringIO.new("1\n"))
      expect(prompt_out.string).to include("Wrap the consuming reference with COPY")
      expect(File.read(moved_path)).to include("b = (COPY a);")
    end
  end

  it "surfaces missing files through the shared runner" do
    expect {
      described_class.run_args(["missing.clear"], out: StringIO.new, err: StringIO.new, input: StringIO.new)
    }.to raise_error(described_class::FileMissingError, /No such file/)
  end
end
