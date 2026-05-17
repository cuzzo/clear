# frozen_string_literal: true

require "minitest/autorun"
require "tempfile"
require_relative "../lib/decomplex"
require_relative "../lib/decomplex/report"

# Self-tested discipline (design.md principle 5): every sub-detector
# has a positive, and an explicit no-false-positive case asserting the
# exclusion column in docs/false-simplicity.md actually holds.
class FalseSimplicityTest < Minitest::Test
  def scan(ruby)
    @tmp = []
    f = Tempfile.new(["fs", ".rb"])
    f.write(ruby)
    f.close
    @tmp << f
    Decomplex::FalseSimplicity.scan([f.path])
  end

  def scan2(ruby1, ruby2)
    @tmp = []
    paths = [ruby1, ruby2].map do |src|
      f = Tempfile.new(["fs", ".rb"])
      f.write(src)
      f.close
      @tmp << f
      f.path
    end
    Decomplex::FalseSimplicity.scan(paths)
  end

  def has(r, kind, detail = nil)
    r.hits.any? { |h| h.kind == kind && (detail.nil? || h.detail == detail) }
  end

  def details(r, kind)
    r.hits.select { |h| h.kind == kind }.map(&:detail)
  end

  # ---- 1. hidden dynamic dispatch -------------------------------------

  def test_dynamic_dispatch_positive
    r = scan(<<~RB)
      def a(o); o.send(:m, 1); end
      def b(o); o.__send__(:m); end
      def c(o); o.public_send(x); end
      def d(k); Object.const_get(k); end
      def e(s); s.constantize; end
      def f(o); o.instance_variable_get(:@x); end
      def g; method(:foo).call(1); end
      def h(o); o.method(:foo).call; end
      def i(blk); blk.call(2); end
      def j(blk); blk.(3); end
      def k; yield 9; end
    RB
    %w[send __send__ public_send const_get constantize
       instance_variable_get].each do |m|
      assert has(r, :dynamic_dispatch, m), "missing dispatch #{m}"
    end
    assert has(r, :dynamic_dispatch, "method(...).call")
    assert has(r, :dynamic_dispatch, "blk.call")
    assert has(r, :dynamic_dispatch, "yield")
    # method(:foo).call AND obj.method(:foo).call both fold to one detail
    assert_operator details(r, :dynamic_dispatch).count("method(...).call"),
                     :>=, 2
  end

  def test_dynamic_dispatch_no_false_positive
    r = scan(<<~RB)
      def a(o); o.run(1); end
      def b(o); o.parse.to_s.call; end
      def c(xs); xs.map { |x| x + 1 }; end
      def d(o); o.respond_to?(:x); end
    RB
    # plain named call, fluent-chain .call (not a var/method-obj recv),
    # iteration block, and predicate are all locally reasoned.
    assert_empty r.hits
  end

  # ---- 2. hidden mutation ---------------------------------------------

  def test_hidden_mutation_positive
    r = scan(<<~RB)
      def a(s); s.gsub!(/x/, "y"); end
      def b(xs); xs.map!(&:to_s); end
      def c(rec); rec.save!; end
      def d(xs, y); xs << y; end
      def e(o, v); o.bar = v; end
      def f(h, k, v); h[k] = v; end
      def g(h, k); h[k] += 1; end
      def i(o); o.count ||= 0; end
    RB
    assert has(r, :hidden_mutation, "gsub!")
    assert has(r, :hidden_mutation, "map!")
    assert has(r, :hidden_mutation, "save!")
    assert has(r, :hidden_mutation, "<<")
    assert has(r, :hidden_mutation, "bar=")
    assert has(r, :hidden_mutation, "[]=")
    assert_equal 2, details(r, :hidden_mutation).count("op-assign") # += and ||=
  end

  def test_hidden_mutation_no_false_positive
    r = scan(<<~RB)
      def a; x = 1; x += 1; x; end
      def b; y = nil; y ||= 2; y; end
      def c; @n = 0; @n += 1; @n; end
      def d(a, b); a != b; end
      def e(f); !f; end
      def g(a, b); a == b; end
      def h(o); o.bar; end
    RB
    # local +=/||=, ivar +=, !=, unary !, ==, attr READ: none mutate
    # through a reference.
    assert_empty r.hits
  end

  # ---- 3. hidden global / context dependency --------------------------

  def test_context_dependency_positive
    r = scan(<<~RB)
      def a; $config; end
      def b; $config = 1; end
      def c; ENV["HOME"]; end
      def d; ENV.fetch("X"); end
      def e; Time.now; end
      def f; Date.today; end
      def g; Thread.current[:k]; end
      def h; Process.pid; end
      def i; rand(10); end
      def j; srand; end
      def k; Dir.pwd; end
    RB
    assert has(r, :context_dependency, "$config")
    assert has(r, :context_dependency, "ENV")
    assert has(r, :context_dependency, "Time.now")
    assert has(r, :context_dependency, "Date.today")
    assert has(r, :context_dependency, "Thread.current")
    assert has(r, :context_dependency, "Process.pid")
    assert has(r, :context_dependency, "rand")
    assert has(r, :context_dependency, "srand")
    assert has(r, :context_dependency, "Dir.pwd")
  end

  def test_context_dependency_no_false_positive
    r = scan(<<~RB)
      def a(s); Time.parse(s); end
      def b(n); Time.at(n); end
      def c; time = 1; time + 1; end
    RB
    # Time.parse/Time.at operate on a PASSED value -- not ambient.
    refute has(r, :context_dependency)
  end

  # ---- 4. hidden IO / effects -----------------------------------------

  def test_hidden_io_positive
    r = scan(<<~RB)
      def a(p); File.read(p); end
      def b(a, b); IO.write(a, b); end
      def c; Dir.glob("*.rb"); end
      def d(x); FileUtils.rm(x); end
      def e(c); Open3.capture3(c); end
      def f(u); Net::HTTP.get(u); end
      def g(u); URI.open(u); end
      def h(s); Marshal.load(s); end
      def i; `ls -l`; end
      def j; %x(whoami); end
      def k(m); puts m; end
      def l(c); system(c); end
      def m; sleep 1; end
    RB
    assert has(r, :hidden_io, "File.read")
    assert has(r, :hidden_io, "IO.write")
    assert has(r, :hidden_io, "Dir.glob")
    assert has(r, :hidden_io, "FileUtils.rm")
    assert has(r, :hidden_io, "Open3.capture3")
    assert has(r, :hidden_io, "Net::HTTP.get")
    assert has(r, :hidden_io, "URI.open")
    assert has(r, :hidden_io, "Marshal.load")
    assert_equal 2, details(r, :hidden_io).count("backtick") # `` and %x
    assert has(r, :hidden_io, "puts")
    assert has(r, :hidden_io, "system")
    assert has(r, :hidden_io, "sleep")
  end

  def test_hidden_io_no_false_positive
    r = scan(<<~RB)
      def a; Dir.pwd; end
      def b(s); s.upcase; end
      def c(u); URI.parse(u); end
      def d(arr); arr.first; end
    RB
    # Dir.pwd is CONTEXT (asserted elsewhere), not IO; the rest are pure.
    refute has(r, :hidden_io)
  end

  # ---- 5. callback / control inversion --------------------------------

  def test_callback_inversion_positive
    r = scan(<<~RB)
      def a(db); db.transaction { work }; end
      def b(m); m.synchronize { crit }; end
      def c(blk); with_lock(&blk); end
      def d; around_action { run }; end
      def e(o); o.on_event { handle }; end
      def f(o); o.before_save { stamp }; end
      def g(o); o.teardown_hook { clean }; end
      def h(l); l.lock { go }; end
    RB
    %w[transaction synchronize with_lock around_action on_event
       before_save teardown_hook lock].each do |c|
      assert has(r, :callback_inversion, c), "missing callback #{c}"
    end
  end

  def test_callback_inversion_no_false_positive
    r = scan(<<~RB)
      def a(xs); xs.each { |x| x }; end
      def b(xs); xs.map { |x| x + 1 }; end
      def c(xs); xs.select { |x| x.ok? }; end
      def d(xs); xs.reduce(0) { |a, x| a + x }; end
      def e; 3.times { work }; end
      def f; loop { spin }; end
      def g(o); o.tap { |v| v }; end
      def h; define_method(:z) { 1 }; end
    RB
    # iteration blocks do not escape local reasoning; define_method is
    # metaprogramming, NOT callback inversion.
    refute has(r, :callback_inversion)
    assert has(r, :metaprogramming, "define_method")
  end

  # ---- 6. metaprogramming / reflection --------------------------------

  def test_metaprogramming_positive
    r = scan(<<~RB)
      def a; define_method(:x) { 1 }; end
      def b; define_singleton_method(:y) { 2 }; end
      def c(k); k.class_eval { def z; end }; end
      def d(o, s); o.instance_eval(s); end
      def e(s); eval(s); end
      def f(o); o.instance_variable_set(:@a, 1); end
      def g(k); k.const_set(:C, 1); end
      def h(m); prepend(m); end
      def method_missing(n, *a); super; end
      def respond_to_missing?(n, p = false); true; end
      class << some_obj
        def patched; end
      end
    RB
    %w[define_method define_singleton_method class_eval instance_eval
       eval instance_variable_set const_set prepend].each do |m|
      assert has(r, :metaprogramming, m), "missing meta #{m}"
    end
    assert has(r, :metaprogramming, "def method_missing")
    assert has(r, :metaprogramming, "def respond_to_missing?")
    assert(r.hits.any? do |h|
      h.kind == :metaprogramming && h.detail.start_with?("class << ")
    end)
  end

  def test_metaprogramming_no_false_positive
    r = scan(<<~RB)
      class Normal
        class << self
          def factory; end
        end
        def initialize; @x = 1; end
      end
      def a(o); o.extend(M); end
      def b; include Comparable; end
    RB
    # `class << self` (the standard class-method idiom), extend, and
    # include are common/low-signal and intentionally excluded.
    refute has(r, :metaprogramming)
  end

  # ---- 7. monkeypatch / reopen ----------------------------------------

  def test_monkeypatch_core_positive
    r = scan(<<~RB)
      class String
        def shout; upcase + "!"; end
      end
      module Kernel
        def k_helper; end
      end
      class ::Array
        def second; self[1]; end
      end
    RB
    assert has(r, :monkeypatch, "String")
    assert has(r, :monkeypatch, "Kernel")
    assert has(r, :monkeypatch, "Array")
  end

  def test_monkeypatch_cross_file_project_reopen
    r = scan2(<<~RB, <<~RB2)
      class Widget
        def render; end
      end
    RB
      class Widget
        def reflow; end
      end
    RB2
    hits = r.hits.select { |h| h.kind == :monkeypatch }
    assert_equal 2, hits.size, "both reopen sites flagged"
    assert(hits.all? { |h| h.detail == "reopen Widget" })
    f = r.findings.find { |x| x[:detail] == "reopen Widget" }
    assert_equal 2, f[:scatter]
  end

  def test_monkeypatch_no_false_positive
    # (a) a single project-class definition is normal.
    r1 = scan(<<~RB)
      class MyThing
        def go; end
      end
    RB
    refute has(r1, :monkeypatch)

    # (b) reopening a core class with NO method def (constant only) is
    # not a behavioural monkeypatch.
    r2 = scan(<<~RB)
      class String
        MAX = 255
      end
    RB
    refute has(r2, :monkeypatch)

    # (c) a namespaced `App::String` is NOT core String, and a single
    # definition is not a cross-file reopen.
    r3 = scan(<<~RB)
      module App
        class String
          def n; end
        end
      end
    RB
    refute has(r3, :monkeypatch)
  end

  # ---- ranking + report integration -----------------------------------

  def test_findings_ranked_by_scatter_then_support
    r = scan(<<~RB)
      def a(o); o.send(:x); end
      def b(o); o.send(:y); end
      def c(o); o.send(:z); end
      def d(o); o.instance_variable_get(:@q); end
    RB
    top = r.findings.first
    assert_equal :dynamic_dispatch, top[:kind]
    assert_equal "send", top[:detail]
    assert_equal 3, top[:scatter] # 3 distinct methods -> blast radius
    # the scatter-1 finding ranks below the scatter-3 one
    ivg = r.findings.find { |x| x[:detail] == "send" }
    other = r.findings.find { |x| x[:kind] == :dynamic_dispatch && x[:detail] != "send" }
    assert_operator r.findings.index(ivg), :<, r.findings.index(other)
  end

  def test_report_renders_false_simplicity_section
    f = Tempfile.new(["rep", ".rb"])
    f.write("def a(o); o.send(:m); end\nclass String; def boom; end; end\n")
    f.close
    @tmp = [f]
    md = Decomplex::Report.new([f.path]).to_markdown
    assert_includes md, "## False Simplicity"
    assert_match(/\*POSSIBLE\* \[dynamic_dispatch\].*`send`/, md)
    assert_match(/\*POSSIBLE\* \[monkeypatch\].*`String`/, md)
    # appears in the prioritization, explicitly labeled tier 3 (the
    # cross-section tier ORDERING is covered by report_test.rb).
    prio = md[/## Project Prioritization.*?\n\n(.*?)\n\n/m, 1].to_s
    assert_match(/\*\*\[tier 3\]\*\* \[False Simplicity/, prio)
  end
end
