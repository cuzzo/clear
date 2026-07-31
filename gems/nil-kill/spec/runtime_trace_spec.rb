# frozen_string_literal: true

require_relative "spec_helper"

RuntimeTraceSpecDouble = Struct.new(:lines) unless defined?(RuntimeTraceSpecDouble)

RSpec.describe "nil-kill runtime trace" do
  it "keeps workspace source outside the selected targets under workspace identity" do
    require_relative "../lib/nil_kill/runtime_trace"
    source = File.join(NilKill::ROOT, "tools", "vopr_coverage.rb")
    cache = NilKillRuntimeTrace.instance_variable_get(:@runtime_package_by_path)
    cache.clear

    expect(NilKillRuntimeTrace.runtime_package(source, native: false)).to eq(
      package_manager: "workspace",
      package: File.basename(NilKill::ROOT),
      version: "workspace"
    )
    expect(NilKillRuntimeTrace.runtime_package("<internal:warning>", native: false)).to eq(
      package_manager: "ruby",
      package: "ruby",
      version: RUBY_VERSION
    )
  ensure
    cache&.clear
  end

  it "retains Ruby default gems as versioned standard-library packages" do
    require_relative "../lib/nil_kill/runtime_trace"
    Dir.mktmpdir("nil-kill-default-gem") do |directory|
      source = File.join(directory, "lib", "stringio.rb")
      FileUtils.mkdir_p(File.dirname(source))
      File.write(source, "# default gem fixture\n")
      specification = Struct.new(:name, :version, :full_gem_path)
        .new("stringio", Gem::Version.new("3.2.0"), directory)
      stub = Struct.new(:name, :full_gem_path).new("stringio", directory)
      allow(Gem).to receive(:loaded_specs).and_return("stringio" => specification)
      allow(Gem::Specification).to receive(:default_stubs).and_return([stub])

      expect(NilKillRuntimeTrace.runtime_package(source, native: false)).to eq(
        package_manager: "ruby",
        package: "stringio",
        version: "3.2.0"
      )
    ensure
      NilKillRuntimeTrace.instance_variable_get(:@runtime_package_by_path)
        .delete(File.expand_path(source))
    end
  end

  it "serializes Struct members as a runtime record shape without dispatching an override" do
    require_relative "../lib/nil_kill/runtime_trace"
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
    require_relative "../lib/nil_kill/runtime_trace"
    provider = Module.new
    stub_const("RuntimeTraceSemanticProvider", provider)

    domain = NilKillTraceNative.value_domain(provider)
    expect(domain.fetch(:types)).to eq(["Module"])
    expect(domain.fetch(:singletons)).to eq(["RuntimeTraceSemanticProvider"])
  end

  it "removes explicitly nonproduction values from runtime SCIP domains, including containers" do
    require_relative "../lib/nil_kill/runtime_trace"
    Dir.mktmpdir("nil-kill-source-role-domain") do |dir|
      roles = File.join(dir, "roles.json")
      File.write(roles, JSON.generate("nonproduction" => [File.expand_path(__FILE__)]))
      isolated_env("NIL_KILL_SOURCE_ROLES" => roles) do
        NilKillRuntimeTrace.instance_variable_set(:@runtime_nonproduction_source_paths, nil)

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
  ensure
    NilKillRuntimeTrace.instance_variable_set(:@runtime_nonproduction_source_paths, nil)
  end

  it "permits an independent branch-coverage child when collect coverage is disabled" do
    Dir.mktmpdir("nil-kill-runtime-coverage-opt-out", NilKill::ROOT) do |dir|
      source = File.join(dir, "covered.rb")
      File.write(source, "result = ENV.fetch(\"NIL_KILL_BRANCH_FIXTURE\") == \"1\" ? :yes : :no\n")
      tracer = File.join(NilKill::ROOT, "gems", "nil-kill", "lib", "nil_kill", "runtime_trace.rb")
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

  it "evicts @objects entries when a tracked collection is GC'd (no unbounded leak), keeping live collections linked" do
    require_relative "../lib/nil_kill/runtime_trace"
    rt = NilKillRuntimeTrace
    owner = lambda do |name|
      { owner_kind: "method_param", name: name,
        path: File.join(NilKill::ROOT, "x.rb"), line: 1, bucket: nil }
    end

    live = [1, 2, 3]
    rt.register_collection_owner(live, owner.call("live"))
    expect(rt.objects.key?(live.object_id)).to be(true)        # linked while alive
    rt.record_collection_mutation(live, elem: 99)              # still attributable
    expect(rt.objects.key?(live.object_id)).to be(true)

    # 20k transient collections that immediately go out of scope.
    # Before the fix @objects grew to 20_001 forever; the finalizer
    # must evict them on GC. Loose bound -> robust to finalizer
    # scheduling.
    20_000.times do |i|
      transient = [i]
      rt.register_collection_owner(transient, owner.call("t"))
      GC.start if (i % 5_000).zero?
    end
    4.times { GC.start }

    expect(rt.objects.size).to be < 1_000
    expect(rt.objects.key?(live.object_id)).to be(true)        # live survives eviction
  end

  it "does not let a stale collection finalizer evict a reused object id" do
    require_relative "../lib/nil_kill/runtime_trace"
    rt = NilKillRuntimeTrace
    tokens = rt.instance_variable_get(:@object_tokens)
    oid = -Process.pid
    owners = {}
    live_token = Object.new

    rt.objects[oid] = owners
    tokens[oid] = live_token

    rt.send(:objects_finalizer, oid, Object.new).call

    expect(rt.objects[oid]).to equal(owners)
    expect(tokens[oid]).to equal(live_token)

    rt.send(:objects_finalizer, oid, live_token).call

    expect(rt.objects).not_to have_key(oid)
    expect(tokens).not_to have_key(oid)
  ensure
    rt.objects.delete(oid) if defined?(rt) && defined?(oid)
    tokens.delete(oid) if defined?(tokens) && defined?(oid)
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
      tracer = File.join(NilKill::ROOT, "gems", "nil-kill", "lib", "nil_kill", "runtime_trace.rb")
      env = {
        "NIL_KILL_TRACE" => "1",
        "NIL_KILL_TRACE_METHODS" => "1",
        "NIL_KILL_TMP_DIR" => trace_tmp,
        "NIL_KILL_TARGETS" => dir,
        "RUBYOPT" => "-r#{tracer}",
      }

      _out, err, status = Open3.capture3(env, "bundle", "exec", "ruby", source, chdir: NilKill::ROOT)

      expect(status).to be_success, err
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
      tracer = File.join(NilKill::ROOT, "gems", "nil-kill", "lib", "nil_kill", "runtime_trace.rb")
      env = {
        "NIL_KILL_TRACE" => "1",
        "NIL_KILL_TRACE_METHODS" => "1",
        "NIL_KILL_TMP_DIR" => trace_tmp,
        "NIL_KILL_TARGETS" => dir,
        "RUBYOPT" => "-r#{tracer}",
      }

      _out, err, status = Open3.capture3(env, "bundle", "exec", "ruby", source, chdir: NilKill::ROOT)

      expect(status).to be_success, err
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
      tracer = File.join(NilKill::ROOT, "gems", "nil-kill", "lib", "nil_kill", "runtime_trace.rb")
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
