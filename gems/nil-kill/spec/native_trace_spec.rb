# frozen_string_literal: true

require "spec_helper"

# The native collector is loaded directly from ext/ so this spec runs against the
# built object without a gemspec/extension install step.
NATIVE_EXT = File.expand_path("../ext/nil_kill_trace", __dir__)
NATIVE_AVAILABLE = File.exist?(File.join(NATIVE_EXT, "nil_kill_trace.so"))

if NATIVE_AVAILABLE
  $LOAD_PATH.unshift(NATIVE_EXT) unless $LOAD_PATH.include?(NATIVE_EXT)
  require "nil_kill_trace"
end

RSpec.describe "NilKillTraceNative", if: NATIVE_AVAILABLE do
  # Fixture lives in a real file so the collector sees genuine iseq paths; a
  # heredoc eval would carry an "(eval)" path and exercise nothing.
  FIXTURE_ROOT = File.expand_path("fixtures/native_trace", __dir__)
  FIXTURE = File.join(FIXTURE_ROOT, "subject.rb")

  before(:all) do
    FileUtils.mkdir_p(FIXTURE_ROOT)
    File.write(FIXTURE, <<~RUBY)
      module NativeTraceSubject
        def self.scalar(value)
          value.positive?
        end

        def self.container(rows)
          rows.length
        end

        def self.two_selectors(text)
          text.upcase
          text.strip
        end

        def self.untracked(value)
          value.to_s
        end
      end
    RUBY
    load FIXTURE
  end

  after(:all) { FileUtils.rm_rf(FIXTURE_ROOT) }

  # Anchor keys are "<path>\1<line>\1<selector>" -- the collector only records a
  # callsite the plan named, so each example declares exactly what it demands.
  def anchor_key(line, selector)
    "#{FIXTURE}#{line}#{selector}"
  end

  def line_of(pattern)
    File.readlines(FIXTURE).index { |line| line.include?(pattern) } + 1
  end

  # Stands in for the one delegation left: the record-wrapper registry, which
  # answers a callee's owner, kind, nativeness and declaration site. The value
  # domain is the collector's own.
  before do
    NilKillTraceNative.value_domain_owner = Object.new.tap do |owner|
      owner.define_singleton_method(:native_callee_identity) do |defined_class, method_id, native|
        name = defined_class.respond_to?(:name) ? defined_class.name : nil
        [name, "instance", nil, nil, nil]
      end
    end
  end

  def trace(anchors, state_anchors = {})
    NilKillTraceNative.reset
    NilKillTraceNative.configure([FIXTURE_ROOT], anchors, state_anchors)
    NilKillTraceNative.start
    yield
  ensure
    NilKillTraceNative.stop
  end

  def rows_for(selector)
    NilKillTraceNative.records.select { |row| row.dig(:callee, :name) == selector }
  end

  it "records a demanded native call with its caller, callsite and receiver type" do
    line = line_of("value.positive?")
    trace(anchor_key(line, "positive?") => "anchor-scalar") do
      NativeTraceSubject.scalar(7)
    end

    row = rows_for("positive?").fetch(0)
    expect(row.dig(:caller, :class)).to eq("NativeTraceSubject")
    expect(row.dig(:caller, :method)).to eq("scalar")
    expect(row.dig(:caller, :kind)).to eq("class")
    expect(row.dig(:callsite, :path)).to eq(FIXTURE)
    expect(row.dig(:callsite, :line)).to eq(line)
    expect(row.dig(:callsite, :selector)).to eq("positive?")
    expect(row.dig(:callee, :owner)).to eq("Numeric")
    expect(row.dig(:callee, :native)).to be(true)
    expect(row.dig(:callee, :receiver_type)).to eq("Integer")
    expect(row.fetch(:receiver_types)).to eq(["Integer"])
    expect(row.fetch(:count)).to eq(1)
  end

  it "ignores a callsite the plan did not demand" do
    trace(anchor_key(line_of("value.positive?"), "positive?") => "anchor-scalar") do
      NativeTraceSubject.scalar(1)
      NativeTraceSubject.untracked(1)
    end

    expect(rows_for("to_s")).to be_empty
    expect(rows_for("positive?").length).to eq(1)
  end

  it "counts repeated executions once per callsite" do
    trace(anchor_key(line_of("value.positive?"), "positive?") => "anchor-scalar") do
      NativeTraceSubject.scalar(1)
      NativeTraceSubject.scalar(2)
    end

    rows = rows_for("positive?")
    expect(rows.length).to eq(1)
    expect(rows.fetch(0).fetch(:count)).to eq(2)
    expect(rows.fetch(0).fetch(:receiver_types)).to eq(["Integer"])
  end

  # Integer#positive? dispatches to Numeric (a C method) while Float#positive? is
  # a Ruby method on Float. One callsite therefore has two correlated
  # receiver->target alternatives, and the protocol forbids flattening them into
  # one bucket. This also pins that a Ruby-implemented dependency callee is
  # observed at all, which only :call reports.
  it "keeps distinct receiver-target alternatives for one callsite separate" do
    trace(anchor_key(line_of("value.positive?"), "positive?") => "anchor-scalar") do
      NativeTraceSubject.scalar(1)
      NativeTraceSubject.scalar(3.5)
    end

    rows = rows_for("positive?")
    expect(rows.length).to eq(2)
    integer = rows.find { |row| row.fetch(:receiver_types) == ["Integer"] }
    float = rows.find { |row| row.fetch(:receiver_types) == ["Float"] }
    expect(integer.dig(:callee, :owner)).to eq("Numeric")
    expect(integer.dig(:callee, :native)).to be(true)
    expect(float.dig(:callee, :owner)).to eq("Float")
    expect(float.dig(:callee, :native)).to be(false)
    expect(rows.map { |row| row.dig(:callsite, :line) }.uniq.length).to eq(1)
  end

  it "separates two demanded selectors on distinct lines of one method" do
    upcase_line = line_of("text.upcase")
    strip_line = line_of("text.strip")
    trace(
      anchor_key(upcase_line, "upcase") => "anchor-upcase",
      anchor_key(strip_line, "strip") => "anchor-strip"
    ) { NativeTraceSubject.two_selectors(" hi ") }

    expect(rows_for("upcase").fetch(0).dig(:callsite, :line)).to eq(upcase_line)
    expect(rows_for("strip").fetch(0).dig(:callsite, :line)).to eq(strip_line)
  end

  it "records both observed boolean results for one predicate callsite" do
    trace(anchor_key(line_of("value.positive?"), "positive?") => "anchor-scalar") do
      NativeTraceSubject.scalar(1)
      NativeTraceSubject.scalar(-1)
    end

    expect(rows_for("positive?").fetch(0).fetch(:result_truths)).to contain_exactly(true, false)
  end

  it "delegates a container receiver to the Ruby value-domain implementation" do
    trace(anchor_key(line_of("rows.length"), "length") => "anchor-container") do
      NativeTraceSubject.container([1, 2, 3])
    end

    row = rows_for("length").fetch(0)
    expect(row.fetch(:receiver_types)).to eq(["Array"])
    indices = row.fetch(:receiver_domain_indices)
    expect(indices.length).to eq(1)
    domain = NilKillTraceNative.domains.fetch(indices.fetch(0))
    expect(domain.fetch(:types)).to eq(["Array"])
    expect(domain.fetch(:elements)).not_to be_empty
  end

  it "observes nothing while stopped" do
    NilKillTraceNative.reset
    NilKillTraceNative.configure(
      [FIXTURE_ROOT], { anchor_key(line_of("value.positive?"), "positive?") => "a" }, {}
    )
    NativeTraceSubject.scalar(1)
    expect(NilKillTraceNative.records).to be_empty
  end

  it "leaves the traced program's own behaviour unchanged" do
    result = nil
    trace(anchor_key(line_of("value.positive?"), "positive?") => "anchor-scalar") do
      result = NativeTraceSubject.scalar(5)
    end
    expect(result).to be(true)
  end

  it "survives a raise inside a traced frame without leaking stack depth" do
    line = line_of("value.positive?")
    trace(anchor_key(line, "positive?") => "anchor-scalar") do
      10.times do
        begin
          NativeTraceSubject.scalar(nil)
        rescue NoMethodError
          nil
        end
      end
      NativeTraceSubject.scalar(1)
    end

    expect(rows_for("positive?").fetch(0).fetch(:count)).to eq(1)
  end

  it "records calls made from other threads" do
    trace(anchor_key(line_of("value.positive?"), "positive?") => "anchor-scalar") do
      [1, 2].map { |v| Thread.new { NativeTraceSubject.scalar(v) } }.each(&:join)
    end

    expect(rows_for("positive?").fetch(0).fetch(:count)).to eq(2)
  end

  it "reports event counts and clears them on reset" do
    trace(anchor_key(line_of("value.positive?"), "positive?") => "anchor-scalar") do
      NativeTraceSubject.scalar(1)
    end
    expect(NilKillTraceNative.stats.fetch(:c_call)).to be > 0

    NilKillTraceNative.reset
    expect(NilKillTraceNative.stats.fetch(:c_call)).to eq(0)
    expect(NilKillTraceNative.stats.fetch(:records)).to eq(0)
  end
  it "tallies executed callsites by path, line and selector" do
    line = line_of("value.positive?")
    trace(anchor_key(line, "positive?") => "anchor-scalar") do
      NativeTraceSubject.scalar(1)
      NativeTraceSubject.scalar(2)
    end

    expect(NilKillTraceNative.executed_callsites)
      .to include([FIXTURE, line, "positive?", 2])
  end

  it "tallies function entries for analyzed methods that ran" do
    trace(anchor_key(line_of("value.positive?"), "positive?") => "anchor-scalar") do
      NativeTraceSubject.scalar(1)
      NativeTraceSubject.scalar(2)
      NativeTraceSubject.container([1])
    end

    entries = NilKillTraceNative.function_entries
    scalar = entries.find { |row| row[2] == "scalar" }
    container = entries.find { |row| row[2] == "container" }
    expect(scalar).to eq([FIXTURE, "NativeTraceSubject", "scalar", line_of("def self.scalar"), 2])
    expect(container.fetch(4)).to eq(1)
  end

  it "clears the tallies on reset" do
    trace(anchor_key(line_of("value.positive?"), "positive?") => "anchor-scalar") do
      NativeTraceSubject.scalar(1)
    end
    NilKillTraceNative.reset
    expect(NilKillTraceNative.executed_callsites).to be_empty
    expect(NilKillTraceNative.function_entries).to be_empty
  end

  it "records the analyzed function's own return under selector return" do
    # A FUNCTION_RETURN anchor spans the whole method, as the plan emits it, so
    # whichever line the :return event reports is inside the demand.
    span = (line_of("def self.scalar")..line_of("value.positive?") + 1)
    demand = span.to_h { |line| [anchor_key(line, "return"), "anchor-return"] }
    trace(demand) { NativeTraceSubject.scalar(1) }

    row = NilKillTraceNative.records.find { |r| r.dig(:callsite, :selector) == "return" }
    expect(row).not_to be_nil
    expect(span).to cover(row.dig(:callsite, :line))
    expect(row.fetch(:result_truths)).to eq([true])
  end

  it "records the result type domain of a demanded call" do
    trace(anchor_key(line_of("rows.length"), "length") => "anchor-container") do
      NativeTraceSubject.container([1, 2])
    end

    row = rows_for("length").fetch(0)
    expect(row.fetch(:result_types)).to eq(["Integer"])
  end

  it "observes a call whose callee is also analyzed source" do
    File.write(File.join(FIXTURE_ROOT, "inner.rb"), <<~RUBY)
      module NativeTraceInner
        def self.outer(value)
          inner(value)
        end

        def self.inner(value)
          value
        end
      end
    RUBY
    load File.join(FIXTURE_ROOT, "inner.rb")
    inner_path = File.join(FIXTURE_ROOT, "inner.rb")
    key = "#{inner_path}\u00013\u0001inner"

    NilKillTraceNative.reset
    NilKillTraceNative.configure([FIXTURE_ROOT], { key => "anchor-internal" }, {})
    NilKillTraceNative.start
    NativeTraceInner.outer(5)
    NilKillTraceNative.stop

    row = NilKillTraceNative.records.find { |r| r.dig(:callee, :name) == "inner" }
    expect(row).not_to be_nil
    expect(row.dig(:callsite, :selector)).to eq("inner")
    expect(row.dig(:caller, :method)).to eq("outer")
    expect(row.dig(:callee, :native)).to be(false)
    expect(row.fetch(:result_types)).to eq(["Integer"])
  end

  # `Kernel#tap` is a Ruby method defined in <internal:kernel>, so it pushes a
  # frame of its own between the analyzed method and the block it yields to.
  # Without the enclosing method's identity the whole block's evidence is
  # unattributable and FactMine drops it.
  it "attributes a call inside a yielded block to the enclosing analyzed method" do
    path = File.join(FIXTURE_ROOT, "blocks.rb")
    File.write(path, <<~RUBY)
      module NativeTraceBlocks
        def self.wrapping(value)
          value.tap do |held|
            held.length
          end
        end
      end
    RUBY
    load path

    NilKillTraceNative.reset
    NilKillTraceNative.configure([FIXTURE_ROOT], { "#{path}4length" => "anchor-block" }, {})
    NilKillTraceNative.start
    NativeTraceBlocks.wrapping("abc")
    NilKillTraceNative.stop

    row = NilKillTraceNative.records.find { |r| r.dig(:callee, :name) == "length" }
    expect(row).not_to be_nil
    expect(row.dig(:callsite, :line)).to eq(4)
    expect(row.dig(:caller, :method)).to eq("wrapping")
    expect(row.dig(:caller, :line)).to eq(2)
  end

  # A :call reports the callee's definition line, and no :line event fires for
  # the continuation lines of a multi-line expression, so the frame's last known
  # line points at the start of the expression rather than the callsite.
  it "binds a call on a continuation line to the line it was written on" do
    path = File.join(FIXTURE_ROOT, "multiline.rb")
    File.write(path, <<~RUBY)
      module NativeTraceMultiline
        def self.build(value)
          {
            "first" => value,
            "second" => widen(value)
          }
        end

        def self.widen(value)
          value
        end
      end
    RUBY
    load path

    NilKillTraceNative.reset
    # `widen` is demanded on every line of the method, exactly as a parameter
    # name would be, so only the true callsite line distinguishes the anchors.
    anchors = (3..6).to_h { |line| ["#{path}#{line}widen", "anchor-#{line}"] }
    NilKillTraceNative.configure([FIXTURE_ROOT], anchors, {})
    NilKillTraceNative.start
    NativeTraceMultiline.build("x")
    NilKillTraceNative.stop

    row = NilKillTraceNative.records.find { |r| r.dig(:callee, :name) == "widen" }
    expect(row).not_to be_nil
    expect(row.dig(:callsite, :line)).to eq(5)
  end

  # A generated accessor is C-backed, so the VM offers no definition site for it.
  # Its owning class still has one, and without it the accessor is exported as
  # opaque CRuby rather than the project declaration FactMine can price.
  it "reports the declaration site the identity delegation supplies for a native callee" do
    path = File.join(FIXTURE_ROOT, "declared.rb")
    File.write(path, <<~RUBY)
      module NativeTraceDeclared
        def self.read(record)
          record.length
        end
      end
    RUBY
    load path

    NilKillTraceNative.value_domain_owner = Object.new.tap do |owner|
      owner.define_singleton_method(:native_callee_identity) do |_defined_class, _method_id, native|
        native ? ["Record", "instance", true, "/declared/record.rb", 12] : [nil, nil, nil, nil, nil]
      end
    end

    NilKillTraceNative.reset
    NilKillTraceNative.configure([FIXTURE_ROOT], { "#{path}3length" => "anchor-declared" }, {})
    NilKillTraceNative.start
    NativeTraceDeclared.read("abc")
    NilKillTraceNative.stop

    row = NilKillTraceNative.records.find { |r| r.dig(:callee, :name) == "length" }
    expect(row).not_to be_nil
    expect(row.dig(:callee, :owner)).to eq("Record")
    expect(row.dig(:callee, :path)).to eq("/declared/record.rb")
    expect(row.dig(:callee, :line)).to eq(12)
  end

  # Ruby raises no event when an ivar is assigned, so a demanded state write is
  # read back off the object once the line performing it has run. Source
  # rewriting is the only other way to see this, and rewriting shifts every line
  # the rest of the collector depends on.
  it "reads a demanded state write back after its line has run" do
    path = File.join(FIXTURE_ROOT, "state.rb")
    File.write(path, <<~RUBY)
      class NativeTraceState
        def initialize(value)
          @label = value.to_s
          @count = value
        end
      end
    RUBY
    load path

    NilKillTraceNative.reset
    NilKillTraceNative.configure(
      [FIXTURE_ROOT], {},
      "#{path}\u00013\u0001label" => "@label",
      "#{path}\u00014\u0001count" => "@count"
    )
    NilKillTraceNative.start
    NativeTraceState.new(7)
    NilKillTraceNative.stop

    rows = NilKillTraceNative.state_values.to_h do |file, line, owner, name, types, calls|
      [name, [file, line, owner, types, calls]]
    end
    expect(rows.fetch("label")).to eq([path, 3, "NativeTraceState", ["String"], 1])
    # The write on the method's last line has no following :line event; the
    # frame's own :return is what flushes it.
    expect(rows.fetch("count")).to eq([path, 4, "NativeTraceState", ["Integer"], 1])
  end

  it "records nothing for a state write the plan did not demand" do
    path = File.join(FIXTURE_ROOT, "state_undemanded.rb")
    File.write(path, <<~RUBY)
      class NativeTraceUndemanded
        def initialize
          @hidden = 1
        end
      end
    RUBY
    load path

    NilKillTraceNative.reset
    NilKillTraceNative.configure([FIXTURE_ROOT], {}, {})
    NilKillTraceNative.start
    NativeTraceUndemanded.new
    NilKillTraceNative.stop

    expect(NilKillTraceNative.state_values).to be_empty
  end
end
