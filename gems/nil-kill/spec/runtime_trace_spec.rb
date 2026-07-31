# frozen_string_literal: true

require_relative "spec_helper"

RuntimeTraceSpecDouble = Struct.new(:lines) unless defined?(RuntimeTraceSpecDouble)

RSpec.describe "nil-kill runtime trace" do
  it "keeps workspace source outside the selected targets under workspace identity" do
    export = NilKill::Runtime::CollectorExport.new(
      { root: NilKill::ROOT, targets: [File.join(NilKill::ROOT, "src")] }, {}
    )

    expect(export.send(:package, File.join(NilKill::ROOT, "tools", "vopr_coverage.rb"), native: false)).to eq(
      package_manager: "workspace",
      package: File.basename(NilKill::ROOT),
      version: "workspace"
    )
    expect(export.send(:package, "<internal:warning>", native: false)).to eq(
      package_manager: "ruby",
      package: "ruby",
      version: RUBY_VERSION
    )
  end

  it "retains Ruby default gems as versioned standard-library packages" do
    Dir.mktmpdir("nil-kill-default-gem") do |directory|
      source = File.join(directory, "lib", "stringio.rb")
      FileUtils.mkdir_p(File.dirname(source))
      File.write(source, "# default gem fixture\n")
      export = NilKill::Runtime::CollectorExport.new({
        root: NilKill::ROOT,
        targets: [],
        gem_specs: [["stringio", "3.2.0", directory]],
        default_gem_specs: [["stringio", "3.2.0", directory]],
      }, {})

      expect(export.send(:package, source, native: false)).to eq(
        package_manager: "ruby",
        package: "stringio",
        version: "3.2.0"
      )
    end
  end

  # The traced process no longer loads, filters or reshapes the plan: it reads
  # flat records the orchestrator already decided. This is that contract.
  it "hands the collector flat plan records rather than a document to interpret" do
    Dir.mktmpdir("nil-kill-collector-plan", NilKill::ROOT) do |dir|
      File.write(File.join(dir, "lib.rb"), "class Widget\n  def call = nil\nend\n")
      isolated_env("NIL_KILL_TARGETS" => dir, "NIL_KILL_TMP_DIR" => dir) do
        NilKill::TracePlan.write(File.join(dir, "trace-plan.json"))
      end

      records = File.read(File.join(dir, NilKill::COLLECTOR_PLAN_NAME))
        .lines(chomp: true).map { |line| line.split("\x02") }
      expect(records.select { |tag, _| tag == "t" }.map(&:last)).to eq([dir])
      # Every demand is a coordinate and the one anchor it answers, so the
      # collector never has to reshape a range into keys.
      records.select { |tag, _| tag == "d" }.each do |_, key, symbol|
        expect(key.split("\x01").length).to eq(3)
        expect(symbol).not_to be_empty
      end
    end
  end

  it "serializes Struct members as a runtime record shape without dispatching an override" do
    record_class = Struct.new(:kind, :payload)
    record_class.class_eval do
      def members
        raise "NilKill must use Struct's native member reader"
      end
    end

    domain = NilKillTraceNative.value_domain(record_class.new(:ok, 1))
    record = domain.fetch(:shapes).find { |shape| shape.fetch(:kind) == "record" }

    expect(record.fetch(:members)).to include(
      "kind" => { "kind" => "class", "name" => "Symbol" },
      "payload" => { "kind" => "class", "name" => "Integer" }
    )
  end

  it "preserves an exact module identity separately from its nominal Module type" do
    provider = Module.new
    stub_const("RuntimeTraceSemanticProvider", provider)

    domain = NilKillTraceNative.value_domain(provider)
    expect(domain.fetch(:types)).to eq(["Module"])
    expect(domain.fetch(:singletons)).to eq(["RuntimeTraceSemanticProvider"])
  end

  it "removes explicitly nonproduction values from runtime SCIP domains, including containers" do
    Dir.mktmpdir("nil-kill-source-role-domain") do |dir|
      roles = File.join(dir, "roles.json")
      File.write(roles, JSON.generate("nonproduction" => [File.expand_path(__FILE__)]))
      isolated_env("NIL_KILL_SOURCE_ROLES" => roles) do
        NilKillTraceNative.reset_value_domain

        # The observation is kept whatever declared it, with the verdict beside
        # it: the shape a function was handed is real evidence, and it is the
        # exporter that must not present a test double as a call target.
        expect(NilKillTraceNative.value_domain(RuntimeTraceSpecDouble.new([]))
          .fetch(:nonproduction)).to be(true)

        domain = NilKillTraceNative.value_domain(
          [RuntimeTraceSpecDouble.new([]), "production"]
        )
        expect(domain.fetch(:types)).to eq(["Array"])
        expect(domain.fetch(:elements)).to eq(["String"])
        array_shape = domain.fetch(:shapes).find { |shape| shape.fetch("kind") == "array" }
        expect(array_shape.fetch("elements")).to eq(
          [{ "kind" => "class", "name" => "String" }]
        )
      end
    end
  end

  it "permits an independent branch-coverage child when collect coverage is disabled" do
    Dir.mktmpdir("nil-kill-runtime-coverage-opt-out", NilKill::ROOT) do |dir|
      source = File.join(dir, "covered.rb")
      File.write(source, "result = ENV.fetch(\"NIL_KILL_BRANCH_FIXTURE\") == \"1\" ? :yes : :no\n")
      tracer = NilKill::COLLECTOR_EXTENSION
      trace_tmp = File.join(dir, "trace-tmp")
      env = {
        "NIL_KILL_TRACE" => "1",
        "NIL_KILL_TRACE_METHODS" => "0",
        "NIL_KILL_COLLECT_COVERAGE" => "0",
        "NIL_KILL_BRANCH_FIXTURE" => "1",
        "NIL_KILL_TMP_DIR" => trace_tmp,
        "NIL_KILL_TARGETS" => dir,
        "RUBYOPT" => "-r#{tracer}",
      }
      script = <<~RUBY
        require "coverage"
        Coverage.start(branches: true)
        load ARGV.fetch(0)
        branches = Coverage.result.fetch(File.expand_path(ARGV.fetch(0))).fetch(:branches)
        abort "missing branch coverage" if branches.empty?
      RUBY

      _out, err, status = Open3.capture3(env, "bundle", "exec", "ruby", "-e", script, source, chdir: NilKill::ROOT)

      expect(status).to be_success, err
    end
  end

  it "forgets a tracked collection once it is collected, and keeps live ones linked" do
    owner = lambda do |name|
      { owner_kind: "method_param", name: name,
        path: File.join(NilKill::ROOT, "x.rb"), line: 1 }
    end

    live = [1, 2, 3]
    NilKillTraceNative.register_collection_owner(live, owner.call("live"))
    expect(NilKillTraceNative.tracks_collection?(live)).to be(true)
    before = NilKillTraceNative.tracked_collections

    # Transient collections that immediately go out of scope. Keyed by object
    # id and never evicted, these grew the graph forever and GC then marked a
    # monotonically growing live set every cycle.
    20_000.times do |i|
      NilKillTraceNative.register_collection_owner([i], owner.call("t"))
      GC.start if (i % 5_000).zero?
    end
    4.times { GC.start }

    # A loose bound: finalizer scheduling is not something to assert on.
    expect(NilKillTraceNative.tracked_collections).to be < before + 1_000
    expect(NilKillTraceNative.tracks_collection?(live)).to be(true)
  end

  it "observes T::Struct construction without blocking Sorbet's generated initializer" do
    Dir.mktmpdir("nil-kill-runtime-tstruct", NilKill::ROOT) do |dir|
      source = File.join(dir, "sample.rb")
      File.write(source, <<~RUBY)
        require "sorbet-runtime"

        class RuntimeRecord < T::Struct
          const :name, String
          const :payload, T.untyped
        end

        record = RuntimeRecord.new(name: "typed", payload: 42)
        abort "bad construction" unless record.name == "typed"
      RUBY

      trace_tmp = File.join(dir, "trace-tmp")
      trace_dir = File.join(trace_tmp, "runtime")
      tracer = NilKill::COLLECTOR_EXTENSION
      env = {
        "NIL_KILL_TRACE" => "1",
        "NIL_KILL_TRACE_METHODS" => "1",
        "NIL_KILL_TMP_DIR" => trace_tmp,
        "NIL_KILL_TARGETS" => dir,
        "RUBYOPT" => "-r#{tracer}",
      }

      _out, err, status = Open3.capture3(env, "bundle", "exec", "ruby", source, chdir: NilKill::ROOT)

      expect(status).to be_success, err
      # The traced program writes what the collector saw; the rows are shaped
      # afterwards, which is what a real collect does between the two.
      NilKill::Runtime::CollectorExport.write(runtime_dir: trace_dir, plan: nil, root: NilKill::ROOT)
      struct_events = Dir.glob(File.join(trace_dir, "structs-*.jsonl")).flat_map do |path|
        File.readlines(path, chomp: true).map { |line| JSON.parse(line) }
      end
      expect(struct_events).to include(
        a_hash_including("class" => "RuntimeRecord", "field" => "name", "classes" => include("String")),
        a_hash_including("class" => "RuntimeRecord", "field" => "payload", "classes" => include("Integer"))
      )
    end
  end

  it "observes a Struct that is reopened with a Sorbet-signed initializer" do
    Dir.mktmpdir("nil-kill-runtime-reopened-struct", NilKill::ROOT) do |dir|
      source = File.join(dir, "sample.rb")
      File.write(source, <<~RUBY)
        require "sorbet-runtime"

        RuntimePlainRecord = Struct.new(:name, keyword_init: true)
        class RuntimePlainRecord
          extend T::Sig

          sig { params(name: String).void }
          def initialize(name:)
            super
          end
        end

        record = RuntimePlainRecord.new(name: "typed")
        record.name = "updated"
        abort "bad construction" unless record.name == "updated"
      RUBY

      trace_tmp = File.join(dir, "trace-tmp")
      trace_dir = File.join(trace_tmp, "runtime")
      tracer = NilKill::COLLECTOR_EXTENSION
      env = {
        "NIL_KILL_TRACE" => "1",
        "NIL_KILL_TRACE_METHODS" => "1",
        "NIL_KILL_TMP_DIR" => trace_tmp,
        "NIL_KILL_TARGETS" => dir,
        "RUBYOPT" => "-r#{tracer}",
      }

      _out, err, status = Open3.capture3(env, "bundle", "exec", "ruby", source, chdir: NilKill::ROOT)

      expect(status).to be_success, err
      # The traced program writes what the collector saw; the rows are shaped
      # afterwards, which is what a real collect does between the two.
      NilKill::Runtime::CollectorExport.write(runtime_dir: trace_dir, plan: nil, root: NilKill::ROOT)
      struct_events = Dir.glob(File.join(trace_dir, "structs-*.jsonl")).flat_map do |path|
        File.readlines(path, chomp: true).map { |line| JSON.parse(line) }
      end
      name_events = struct_events.select { |event| event["class"] == "RuntimePlainRecord" && event["field"] == "name" }
      expect(name_events).not_to be_empty
      expect(name_events.flat_map { |event| event.fetch("classes") }).to include("String")
    end
  end

  it "does not force autoloaded constants from the Struct/Data const hook" do
    Dir.mktmpdir("nil-kill-runtime-autoload", NilKill::ROOT) do |dir|
      source = File.join(dir, "sample.rb")
      lazy = File.join(dir, "lazy_struct.rb")
      File.write(lazy, "raise 'autoload should not be forced by const_added'\n")
      File.write(source, <<~RUBY)
        module LazyHost
          autoload :LazyStruct, #{lazy.inspect}
        end

        puts "ok"
      RUBY

      trace_tmp = File.join(dir, "trace-tmp")
      tracer = NilKill::COLLECTOR_EXTENSION
      env = {
        "NIL_KILL_TRACE" => "1",
        "NIL_KILL_TRACE_METHODS" => "1",
        "NIL_KILL_TMP_DIR" => trace_tmp,
        "NIL_KILL_TARGETS" => dir,
        "RUBYOPT" => "-r#{tracer}",
      }

      out, err, status = Open3.capture3(env, "bundle", "exec", "ruby", source, chdir: NilKill::ROOT)

      expect(status).to be_success, err
      expect(out).to include("ok")
    end
  end


end
