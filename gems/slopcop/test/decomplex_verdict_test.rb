# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "tempfile"
require "json"
require "coverage"
require "fileutils"
require_relative "../lib/slopcop"

# SlopCop's OPTIONAL decomplex consumer: the negative `spurious`
# filter (redundant decision -> refactor, not test) and the positive
# structural-deviance amplifier on genuine gaps. Mirrors the boobytrap
# consumer discipline: read decomplex's verdict, re-derive nothing,
# degrade cleanly if absent.
class DecomplexVerdictTest < Minitest::Test
  # ---- adapter unit -------------------------------------------------

  def write(src)
    f = Tempfile.new(["dv", ".rb"])
    f.write(src)
    f.close
    @tmp ||= []
    @tmp << f
    f.path
  end

  def test_index_empty_and_trivial_inputs
    v0 = SlopCop::DecomplexVerdict.index([])
    assert_equal :absent, v0[:status]
    assert_equal SlopCop::DecomplexVerdict.blank(:absent), v0
    # a file with no decision defects -> ok status, nothing flagged.
    p = write("def plain(x)\n  x + 1\nend\n")
    v = SlopCop::DecomplexVerdict.index([p])
    assert_equal :ok, v[:status]
    assert_nil SlopCop::DecomplexVerdict.lookup(v, p, "plain", 2)
  end

  def test_coarse_duplication_never_excludes_stays_genuine_flagged
    # method `lone` has a `send` (False Simplicity, deviance, point-like
    # -> its span will NOT contain the unrelated `if` arm) AND shares a
    # duplicated case with `twin` (Missing Abstraction, SPURIOUS-class).
    # The `if w` arm is in NEITHER flagged span -> method fallback. It
    # MUST stay genuine (coarse never excludes) but be flagged
    # coarse_dup so a human verifies, never silently deleted.
    p = write(<<~RB)
      def lone(n, w)
        case n
        when 1 then 10
        when 2 then 20
        end
        return 7 if w
        n
      end
      def twin(n)
        case n
        when 1 then 30
        when 2 then 40
        end
      end
    RB
    v = SlopCop::DecomplexVerdict.index([p])
    arm = SlopCop::DecomplexVerdict.lookup(v, p, "lone", 6) # the `if w`
    refute_nil arm
    refute arm[:spurious], "coarse duplication must NOT mark spurious"
    refute arm[:precise]
    assert arm[:coarse_dup], "but it IS flagged for human verification"
  end

  def test_deviance_floored_at_method_level_monotone
    # method `m` has TWO deviance detectors: `send` (False Simplicity,
    # small point-like span at line 2) and an `is_a?` guard (Decision
    # Pressure, line 3) -> method-level deviance is convergent/high.
    # An arm precisely inside ONLY the small `send` span must be
    # floored UP to the method value, not scored on the send alone --
    # otherwise precise attribution would rank it BELOW its coarse
    # peers (the inversion Fix 1 removes).
    p = write(<<~RB)
      def m(o, x)
        o.send(:to_s)
        return 1 if x.is_a?(String)
        x
      end
    RB
    v = SlopCop::DecomplexVerdict.index([p])
    method_dev = SlopCop::DecomplexVerdict.lookup(v, p, "m", 99)[:deviance]
    precise = SlopCop::DecomplexVerdict.lookup(v, p, "m", 2)
    assert precise[:precise], "line 2 is inside the send span"
    assert_operator method_dev, :>, 1, "method has >1 deviance detector"
    assert_equal method_dev, precise[:deviance],
                 "precise floored UP to the method value (Fix 1)"
  end

  def test_lookup_flags_deviance_detector_not_spurious
    # a lone `send` -> decomplex False Simplicity (a DEVIANCE detector,
    # tier 3 weight 1); single detector -> not convergent, dev = 1.
    p = write("def m(o)\n  o.send(:to_s)\nend\n")
    v = SlopCop::DecomplexVerdict.index([p])
    r = SlopCop::DecomplexVerdict.lookup(v, p, "m", 2)
    refute_nil r
    refute r[:spurious]
    assert_equal 1, r[:deviance]
    assert_equal ["False Simplicity"], r[:detectors]
    refute r[:convergent]
    assert r[:precise], "the send span contains line 2"
  end

  def test_lookup_flags_spurious_for_duplicated_decision
    # identical case/when guard tuple across 2 methods -> decomplex
    # Missing Abstractions (a SPURIOUS-class detector) on BOTH units.
    p = write(<<~RB)
      def a(n)
        case n
        when 1 then 10
        when 2 then 20
        end
      end
      def b(n)
        case n
        when 1 then 30
        when 2 then 40
        end
      end
    RB
    v = SlopCop::DecomplexVerdict.index([p])
    # line 4 is `when 2` INSIDE a's case (lines 2-5) -> span-precise.
    ra = SlopCop::DecomplexVerdict.lookup(v, p, "a", 4)
    assert ra[:spurious]
    assert ra[:precise]
    assert SlopCop::DecomplexVerdict.lookup(v, p, "b", 11)[:spurious]
  end

  def test_span_precision_excludes_unrelated_arm_in_same_method
    # `dispatch` is duplicated with `other` (Missing Abstraction on the
    # case spanning lines 2-5). The `if z` at line 7 is a DIFFERENT,
    # unflagged decision in the SAME method -> must NOT inherit the
    # spurious tag (the whole point of span-precision over method-join).
    p = write(<<~RB)
      def dispatch(n, z)
        case n
        when 1 then 10
        when 2 then 20
        end
        return 99 if z
        n
      end
      def other(n)
        case n
        when 1 then 30
        when 2 then 40
        end
      end
    RB
    v = SlopCop::DecomplexVerdict.index([p])
    inside = SlopCop::DecomplexVerdict.lookup(v, p, "dispatch", 4)
    assert inside[:spurious], "arm inside the duplicated case"
    assert inside[:precise]
    outside = SlopCop::DecomplexVerdict.lookup(v, p, "dispatch", 7)
    # line 7 is outside every flagged span -> NOT spurious by span.
    # (Method-join fallback may still see the method, but the case
    # finding is span-scoped so the `if z` arm is not its target.)
    refute(outside && outside[:precise] && outside[:spurious],
           "unrelated arm must not inherit the spurious tag span-precisely")
  end

  # ---- shared coverage harness (same pattern as rollup_test) --------

  def with_repo(src)
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/src")
      path = "#{dir}/src/m.rb"
      File.write(path, src)
      %w[init].each { system("git", "-C", dir, "init", "-q", out: File::NULL, err: File::NULL) }
      system("git", "-C", dir, "config", "user.email", "t@t")
      system("git", "-C", dir, "config", "user.name", "t")
      system("git", "-C", dir, "add", "-A", out: File::NULL, err: File::NULL)
      system("git", "-C", dir, "commit", "-qm", "x", out: File::NULL, err: File::NULL)
      Coverage.start(branches: true)
      load path
      res = Coverage.result
      rsf = "#{dir}/rs.json"
      File.write(rsf, JSON.dump(
        "T" => { "coverage" => { path => { "branches" => res.dig(path, :branches) } } }
      ))
      yield dir, rsf
    end
  end

  def test_rollup_reclassifies_duplicated_decision_as_spurious
    # a and b share the same case/when -> decomplex Missing Abstraction
    # -> the uncovered arms are NOT test targets (refactor the dup).
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
      a(1)
      b(1)
    RB
    with_repo(src) do |dir, rsf|
      out = SlopCop::Rollup.run(files: ["src/m.rb"], repo: dir, resultset: rsf)
      c = out[:per_file]["src/m.rb"][:counts]
      assert c[:spurious].to_i.positive?, "duplicated arms -> spurious"
      assert_equal 0, c[:genuine].to_i, "nothing genuine: all are the dup"
      assert_empty out[:top_gaps], "spurious arms are not test targets"
      assert_equal out[:grand], out[:totals].values.sum
    end
  end

  def test_rollup_amplifies_genuine_gap_in_deviant_method
    # `a` has a `send` (decomplex False Simplicity = deviance) + a
    # UNIQUE case (not duplicated -> not spurious). `b` has a distinct
    # unique case, no deviance. Equal churn -> `a` must outrank `b`.
    src = <<~RB
      def a(o, n)
        o.send(:to_s)
        case n
        when 1 then 10
        when 2 then 20
        else 30
        end
      end
      def b(k)
        case k
        when :x then 11
        when :y then 21
        else 31
        end
      end
      a("x", 1)
      b(:x)
    RB
    with_repo(src) do |dir, rsf|
      out = SlopCop::Rollup.run(files: ["src/m.rb"], repo: dir, resultset: rsf)
      gaps = out[:top_gaps]
      refute_empty gaps
      a_gaps = gaps.select { |g| g[:method] == "a" }
      b_gaps = gaps.select { |g| g[:method] == "b" }
      refute_empty a_gaps
      refute_empty b_gaps
      assert(a_gaps.all? { |g| g[:deviance].positive? },
             "deviant method gaps carry deviance")
      assert(a_gaps.all? { |g| g[:detectors].include?("False Simplicity") })
      assert(b_gaps.all? { |g| g[:deviance].zero? }, "non-deviant: 0")
      # every deviant `a` gap ranks above every non-deviant `b` gap.
      last_a = gaps.rindex { |g| g[:method] == "a" }
      first_b = gaps.index { |g| g[:method] == "b" }
      assert_operator last_a, :<, first_b,
                      "uncovered+deviant apexes above uncovered-only"
    end
  end

  def test_degrades_to_pure_churn_when_no_decomplex_signal
    # No decision defects anywhere -> deviance 0 for all; priority must
    # equal churn and ordering is the pre-decomplex behaviour exactly.
    src = <<~RB
      def f(n)
        if n > 0 then 1 else 2 end
      end
      f(1)
    RB
    with_repo(src) do |dir, rsf|
      out = SlopCop::Rollup.run(files: ["src/m.rb"], repo: dir, resultset: rsf)
      refute_empty out[:top_gaps]
      out[:top_gaps].each do |g|
        assert_equal 0, g[:deviance]
        assert_in_delta g[:churn], g[:priority], 1e-9,
                        "priority == churn when decomplex is silent"
      end
    end
  end

  def test_report_loudly_flags_unavailable_decomplex_not_silent
    # the worst silent failure: decomplex errors/absent and the report
    # looks identical to a healthy churn+decomplex run. Must NOT.
    r = SlopCop::Report.allocate
    assert_equal "", r.decomplex_banner(:ok)
    %i[error absent].each do |st|
      b = r.decomplex_banner(st)
      assert_includes b, "NOT applied"
      assert_includes b, "decomplex"
      assert(b.start_with?("> ⚠"), "banner is a visible callout")
    end
  end

  def test_report_renders_decomplex_column_and_spurious_row
    src = <<~RB
      def a(o, n)
        o.send(:to_s)
        case n
        when 1 then 10
        when 2 then 20
        else 30
        end
      end
      a("x", 1)
    RB
    with_repo(src) do |dir, rsf|
      md = SlopCop::Report.new(files: ["src/m.rb"], repo: dir,
                               resultset: rsf).to_markdown
      assert_includes md, "decomplex deviance"          # new column
      assert_includes md, "False Simplicity"            # the detector
      assert_includes md, "Apex = uncovered"            # thesis header
      assert_includes md, "redundant/cloned decision (decomplex)" # spurious row
    end
  end

  def test_decomplex_verdict_uses_decomplex_facts_file
    mock_data = {
      "detectors" => {
        "false_simplicity" => {
          "sites" => ["src/m.rb:foo:10"],
          "spans" => { "src/m.rb:foo:10" => [10, 0, 12, 5] }
        }
      }
    }
    Tempfile.create(["mock-decomplex", ".json"]) do |f|
      f.write(JSON.dump(mock_data))
      f.close
      begin
        ENV["DECOMPLEX_FACTS_FILE"] = f.path
        verdict = SlopCop::DecomplexVerdict.index(["src/m.rb"])
        assert_equal :ok, verdict[:status]
        res = SlopCop::DecomplexVerdict.lookup(verdict, "src/m.rb", "foo", 11)
        assert_equal ["False Simplicity"], res[:detectors]
      ensure
        ENV["DECOMPLEX_FACTS_FILE"] = nil
      end
    end
  end
end
