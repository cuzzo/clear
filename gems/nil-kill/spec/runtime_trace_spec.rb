# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe "nil-kill runtime trace" do
  it "does not re-enter source return or raise recording while collection hooks are disabled" do
    require_relative "../lib/nil_kill/runtime_trace"
    rt = NilKillRuntimeTrace
    path = File.join(NilKill::ROOT, "src", "nil_kill_runtime_trace_guard_spec.rb")

    rt.with_collection_hooks_disabled do
      rt.lock.synchronize do
        expect(rt.record_source_method_return("GuardOwner", "call", "instance", path, 1, :ok)).to eq(:ok)
        expect do
          rt.record_source_method_raise("GuardOwner", "call", "instance", path, 1, RuntimeError.new("boom"))
        end.not_to raise_error
      end
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

  it "captures method returns, T.let values, and struct fields in a subprocess" do
    Dir.mktmpdir("nil-kill-runtime", NilKill::ROOT) do |dir|
      source = File.join(dir, "sample.rb")
      File.write(source, <<~RUBY)
        require "ostruct"
        require "sorbet-runtime"

        Pair = Struct.new(:name, :items)

        class Worker
          extend T::Sig

          sig { params(values: T::Array[T.untyped]).returns(String) }
          def call(values)
            label = T.let("ok", T.untyped)
            Pair.new(label, values)
            OpenStruct.new(count: values.length)
            label
          end
        end

        Worker.new.call(["a", "b"])
      RUBY

      trace_tmp = File.join(dir, "trace-tmp")
      trace_dir = File.join(trace_tmp, "runtime")
      FileUtils.rm_rf(trace_dir)
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
      method_events = Dir.glob(File.join(trace_dir, "methods-*.jsonl")).flat_map { |path| File.readlines(path, chomp: true).map { |line| JSON.parse(line) } }
      tlet_events = Dir.glob(File.join(trace_dir, "tlets-*.jsonl")).flat_map { |path| File.readlines(path, chomp: true).map { |line| JSON.parse(line) } }
      struct_events = Dir.glob(File.join(trace_dir, "structs-*.jsonl")).flat_map { |path| File.readlines(path, chomp: true).map { |line| JSON.parse(line) } }

      expect(method_events).to include(a_hash_including("class" => "Worker", "method" => "call", "returns" => include("String")))
      expect(method_events).to include(a_hash_including("class" => "Worker", "method" => "call", "param_elem" => a_hash_including("values" => include("String"))))
      expect(tlet_events).to include(a_hash_including("classes" => include("String")))
      expect(struct_events).to include(a_hash_including("class" => "Pair", "field" => "name", "classes" => include("String")))
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

  it "captures collection mutations and source-instrumented ivar assignments in a subprocess" do
    Dir.mktmpdir("nil-kill-runtime-ivar", NilKill::ROOT) do |dir|
      source = File.join(dir, "sample.rb")
      File.write(source, <<~RUBY)
        require "sorbet-runtime"
        require "set"

        class Worker
          extend T::Sig

          sig { params(items: T::Array[T.untyped], map: T::Hash[T.untyped, T.untyped]).returns(T::Hash[T.untyped, T.untyped]) }
          def call(items, map)
            @items = []
            @seen = Set.new
            items << "runtime"
            items << {name: ["nested"]}
            map[:name] = 1
            map[:nested] = {ok: ["yes"]}
            @items << :ivar_item
            @seen.add(:seen)
            map
          end
        end

        Worker.new.call([], {})
      RUBY

      instrumented = File.join(dir, "sample.instrumented.rb")
      FileUtils.mkdir_p(File.dirname(instrumented))
      File.write(instrumented, NilKill::SourceInstrumenter.new.instrument_file(source))

      trace_tmp = File.join(dir, "trace-tmp")
      trace_dir = File.join(trace_tmp, "runtime")
      FileUtils.rm_rf(trace_dir)
      tracer = File.join(NilKill::ROOT, "gems", "nil-kill", "lib", "nil_kill", "runtime_trace.rb")
      env = {
        "NIL_KILL_TRACE" => "1",
        "NIL_KILL_TRACE_METHODS" => "1",
        "NIL_KILL_TMP_DIR" => trace_tmp,
        "NIL_KILL_TARGETS" => dir,
        "RUBYOPT" => "-r#{tracer}",
      }

      _out, err, status = Open3.capture3(env, "bundle", "exec", "ruby", instrumented, chdir: NilKill::ROOT)

      expect(status).to be_success, err
      method_events = Dir.glob(File.join(trace_dir, "methods-*.jsonl")).flat_map { |path| File.readlines(path, chomp: true).map { |line| JSON.parse(line) } }
      collection_events = Dir.glob(File.join(trace_dir, "collections-*.jsonl")).flat_map { |path| File.readlines(path, chomp: true).map { |line| JSON.parse(line) } }

      expect(method_events).to include(a_hash_including(
        "class" => "Worker",
        "method" => "call",
        "param_elem" => a_hash_including("items" => include("String", "Hash")),
        "param_kv" => a_hash_including("map" => [include("Symbol"), include("Integer", "Hash")]),
        "param_elem_shapes" => a_hash_including("items" => include(
          a_hash_including(
            "kind" => "hash",
            "keys" => include(a_hash_including("kind" => "class", "name" => "Symbol")),
            "values" => include(a_hash_including(
              "kind" => "array",
              "elements" => include(a_hash_including("kind" => "class", "name" => "String"))
            ))
          )
        )),
        "param_kv_shapes" => a_hash_including("map" => [
          [],
          include(a_hash_including(
            "kind" => "hash",
            "keys" => include(a_hash_including("kind" => "class", "name" => "Symbol")),
            "values" => include(a_hash_including(
              "kind" => "array",
              "elements" => include(a_hash_including("kind" => "class", "name" => "String"))
            ))
          ))
        ])
      ))
      expect(collection_events).to include(a_hash_including(
        "owner_kind" => "method_param",
        "name" => "items",
        "kind" => "array",
        "elem_shapes" => include(a_hash_including(
          "kind" => "hash",
          "keys" => include(a_hash_including("kind" => "class", "name" => "Symbol")),
          "values" => include(a_hash_including(
            "kind" => "array",
            "elements" => include(a_hash_including("kind" => "class", "name" => "String"))
          ))
        ))
      ))
      expect(collection_events).to include(a_hash_including("owner_kind" => "ivar", "name" => "@items", "kind" => "array", "elem_classes" => include("Symbol")))
      expect(collection_events).to include(a_hash_including("owner_kind" => "ivar", "name" => "@seen", "kind" => "set", "elem_classes" => include("Symbol")))
      items_owner = collection_events.find { |event| event["owner_kind"] == "method_param" && event["name"] == "items" }
      expect(items_owner.fetch("mutation_sites").keys).to include(a_string_matching(/sample\.instrumented\.rb:\d+\z/))
    end
  end

  it "source-instruments sampled and frame-only trace-plan methods when method TracePoint collection is disabled" do
    Dir.mktmpdir("nil-kill-runtime-source-plan", NilKill::ROOT) do |dir|
      source = File.join(dir, "sample.rb")
      File.write(source, <<~RUBY)
        require "sorbet-runtime"

        class Worker
          extend T::Sig

          sig { params(value: String).returns(String) }
          def typed(value)
            value
          end

          sig { params(value: T.untyped).returns(T.untyped) }
          def untyped(value)
            value
          end
        end

        worker = Worker.new
        worker.typed("typed")
        worker.untyped("untyped")
      RUBY

      methods = NilKill::SourceIndex.new(source).methods.each_with_object({}) { |method, lookup| lookup[method["method"]] = method }
      plan = {
        "methods" => {
          ["Worker", "typed", "instance", File.expand_path(source), methods.fetch("typed")["line"]].join("\0") => {
            "sample" => false,
            "params" => { "value" => false },
            "return" => false,
          },
          ["Worker", "untyped", "instance", File.expand_path(source), methods.fetch("untyped")["line"]].join("\0") => {
            "sample" => true,
            "params" => { "value" => true },
            "return" => true,
          },
        },
      }
      FileUtils.mkdir_p(NilKill::TMP_DIR)
      File.write(NilKill::TRACE_PLAN_PATH, JSON.pretty_generate(plan))

      instrumented = File.join(dir, "sample.instrumented.rb")
      FileUtils.mkdir_p(File.dirname(instrumented))
      instrumented_source = NilKill::SourceInstrumenter.new.instrument_file(source)
      File.write(instrumented, instrumented_source)

      expect(instrumented_source).to include('record_source_method_call("Worker", "untyped"')
      expect(instrumented_source).to include('record_source_method_call("Worker", "typed"')

      trace_tmp = File.join(dir, "trace-tmp")
      trace_dir = File.join(trace_tmp, "runtime")
      FileUtils.rm_rf(trace_dir)
      tracer = File.join(NilKill::ROOT, "gems", "nil-kill", "lib", "nil_kill", "runtime_trace.rb")
      env = {
        "NIL_KILL_TRACE" => "1",
        "NIL_KILL_TRACE_METHODS" => "0",
        "NIL_KILL_TMP_DIR" => trace_tmp,
        "NIL_KILL_TARGETS" => dir,
        "RUBYOPT" => "-r#{tracer}",
      }

      _out, err, status = Open3.capture3(env, "bundle", "exec", "ruby", instrumented, chdir: NilKill::ROOT)

      expect(status).to be_success, err
      method_events = Dir.glob(File.join(trace_dir, "methods-*.jsonl")).flat_map { |path| File.readlines(path, chomp: true).map { |line| JSON.parse(line) } }
      expect(method_events).to include(a_hash_including("class" => "Worker", "method" => "untyped", "returns" => include("String")))
      expect(method_events).to include(a_hash_including("class" => "Worker", "method" => "typed"))
    end
  end

  it "instruments a one-line def (def f; ...; end), anchoring the suffix on the end keyword" do
    Dir.mktmpdir("nil-kill-oneline", NilKill::ROOT) do |dir|
      source = File.join(dir, "sample.rb")
      File.write(source, <<~RUBY)
        require "sorbet-runtime"

        class Worker
          extend T::Sig

          sig { returns(T.untyped) }
          def oneline; @v = T.let(@v, T.untyped); end
        end

        Worker.new.oneline
      RUBY

      methods = NilKill::SourceIndex.new(source).methods.each_with_object({}) { |m, h| h[m["method"]] = m }
      plan = {
        "methods" => {
          ["Worker", "oneline", "instance", File.expand_path(source), methods.fetch("oneline")["line"]].join("\0") => {
            "sample" => true, "params" => {}, "return" => true
          },
        },
      }
      FileUtils.mkdir_p(NilKill::TMP_DIR)
      File.write(NilKill::TRACE_PLAN_PATH, JSON.pretty_generate(plan))

      instrumented_source = NilKill::SourceInstrumenter.new.instrument_file(source)
      expect(instrumented_source).to include('record_source_method_call("Worker", "oneline"')

      instrumented = File.join(dir, "sample.instrumented.rb")
      File.write(instrumented, instrumented_source)
      trace_tmp = File.join(dir, "trace-tmp")
      trace_dir = File.join(trace_tmp, "runtime")
      FileUtils.rm_rf(trace_dir)
      tracer = File.join(NilKill::ROOT, "gems", "nil-kill", "lib", "nil_kill", "runtime_trace.rb")
      env = {
        "NIL_KILL_TRACE" => "1", "NIL_KILL_TRACE_METHODS" => "0",
        "NIL_KILL_TMP_DIR" => trace_tmp, "NIL_KILL_TARGETS" => dir,
        "RUBYOPT" => "-r#{tracer}",
      }
      _out, err, status = Open3.capture3(env, "bundle", "exec", "ruby", instrumented, chdir: NilKill::ROOT)
      expect(status).to be_success, err
      method_events = Dir.glob(File.join(trace_dir, "methods-*.jsonl")).flat_map { |p| File.readlines(p, chomp: true).map { |l| JSON.parse(l) } }
      expect(method_events).to include(a_hash_including("class" => "Worker", "method" => "oneline"))
    end
  end

  it "source-wraps methods with ensure in the body" do
    Dir.mktmpdir("nil-kill-tp-fallback", NilKill::ROOT) do |dir|
      source = File.join(dir, "sample.rb")
      File.write(source, <<~RUBY)
        require "sorbet-runtime"

        class Worker
          extend T::Sig

          sig { params(value: T.untyped).returns(T.untyped) }
          def guarded(value)
            value.to_s
          ensure
            nil
          end
        end

        Worker.new.guarded(42)
      RUBY

      methods = NilKill::SourceIndex.new(source).methods.each_with_object({}) { |m, h| h[m["method"]] = m }
      # target_dirs MUST be present and match NIL_KILL_TARGETS or the
      # runtime discards the whole plan (trace_plan target-guard) ->
      # the TracePoint fallback never installs. This is exactly the
      # faithful shape TracePlan.write produces in a real collect.
      plan = {
        "target_dirs" => [dir],
        "methods" => {
          ["Worker", "guarded", "instance", File.expand_path(source), methods.fetch("guarded")["line"]].join("\0") => {
            "sample" => true, "params" => { "value" => true }, "return" => true
          },
        },
      }
      FileUtils.mkdir_p(NilKill::TMP_DIR)
      File.write(NilKill::TRACE_PLAN_PATH, JSON.pretty_generate(plan))

      instrumented_source = NilKill::SourceInstrumenter.new.instrument_file(source)
      expect(instrumented_source).to include('record_source_method_call("Worker", "guarded"')
      reloaded = JSON.parse(File.read(NilKill::TRACE_PLAN_PATH))
      expect(reloaded.fetch("tracepoint_methods", {}).keys.any? { |k| k.split("\0")[1] == "guarded" }).to be(false)

      instrumented = File.join(dir, "sample.instrumented.rb")
      File.write(instrumented, instrumented_source)
      trace_tmp = File.join(dir, "trace-tmp")
      trace_dir = File.join(trace_tmp, "runtime")
      FileUtils.rm_rf(trace_tmp)
      FileUtils.mkdir_p(trace_tmp)
      # Faithful to real collect: the trace plan and runtime dumps share one TMP_DIR.
      FileUtils.cp(NilKill::TRACE_PLAN_PATH, File.join(trace_tmp, "trace-plan.json"))
      tracer = File.join(NilKill::ROOT, "gems", "nil-kill", "lib", "nil_kill", "runtime_trace.rb")
      env = {
        "NIL_KILL_TRACE" => "1", "NIL_KILL_TRACE_METHODS" => "0",
        "NIL_KILL_TMP_DIR" => trace_tmp, "NIL_KILL_TARGETS" => dir,
        "RUBYOPT" => "-r#{tracer}",
      }
      _out, err, status = Open3.capture3(env, "bundle", "exec", "ruby", instrumented, chdir: NilKill::ROOT)
      expect(status).to be_success, err
      method_events = Dir.glob(File.join(trace_dir, "methods-*.jsonl")).flat_map { |p| File.readlines(p, chomp: true).map { |l| JSON.parse(l) } }
      expect(method_events).to include(a_hash_including(
        "class" => "Worker", "method" => "guarded",
        "params_by_name" => a_hash_including("value" => include("Integer"))
      ))
    end
  end

  it "does not crash when a loaded module overrides the singleton .name" do
    Dir.mktmpdir("nil-kill-runtime-evil-name", NilKill::ROOT) do |dir|
      source = File.join(dir, "sample.rb")
      File.write(source, <<~RUBY)
        require "sorbet-runtime"

        # Mirrors REXML::Functions, which defines `.name` as an XPath DSL
        # method. The targeted-definition TracePoint(:end) fires for this
        # module's `end` and must NOT invoke this override.
        module Hostile
          def self.name(*)
            raise "singleton .name must never be called by the tracer"
          end
        end

        class Worker
          extend T::Sig

          sig { params(value: T.untyped).returns(T.untyped) }
          def untyped(value)
            value
          end
        end

        Worker.new.untyped("ok")
      RUBY

      methods = NilKill::SourceIndex.new(source).methods.each_with_object({}) { |method, lookup| lookup[method["method"]] = method }
      plan = {
        "methods" => {
          ["Worker", "untyped", "instance", File.expand_path(source), methods.fetch("untyped")["line"]].join("\0") => {
            "sample" => true,
            "params" => { "value" => true },
            "return" => true,
          },
        },
      }
      FileUtils.mkdir_p(NilKill::TMP_DIR)
      File.write(NilKill::TRACE_PLAN_PATH, JSON.pretty_generate(plan))

      instrumented = File.join(dir, "sample.instrumented.rb")
      FileUtils.mkdir_p(File.dirname(instrumented))
      File.write(instrumented, NilKill::SourceInstrumenter.new.instrument_file(source))

      trace_tmp = File.join(dir, "trace-tmp")
      trace_dir = File.join(trace_tmp, "runtime")
      FileUtils.rm_rf(trace_dir)
      tracer = File.join(NilKill::ROOT, "gems", "nil-kill", "lib", "nil_kill", "runtime_trace.rb")
      env = {
        "NIL_KILL_TRACE" => "1",
        "NIL_KILL_TRACE_METHODS" => "0",
        "NIL_KILL_TMP_DIR" => trace_tmp,
        "NIL_KILL_TARGETS" => dir,
        "RUBYOPT" => "-r#{tracer}",
      }

      _out, err, status = Open3.capture3(env, "bundle", "exec", "ruby", instrumented, chdir: NilKill::ROOT)

      expect(status).to be_success, err
      method_events = Dir.glob(File.join(trace_dir, "methods-*.jsonl")).flat_map { |path| File.readlines(path, chomp: true).map { |line| JSON.parse(line) } }
      expect(method_events).to include(a_hash_including("class" => "Worker", "method" => "untyped", "returns" => include("String")))
    end
  end

  it "source-instrumented methods record both explicit and implicit return paths" do
    Dir.mktmpdir("nil-kill-runtime-source-returns", NilKill::ROOT) do |dir|
      source = File.join(dir, "sample.rb")
      File.write(source, <<~RUBY)
        require "sorbet-runtime"

        class Worker
          extend T::Sig

          sig { params(flag: T::Boolean).returns(T.untyped) }
          def mixed(flag)
            return "explicit" if flag
            :implicit
          end
        end

        worker = Worker.new
        worker.mixed(true)
        worker.mixed(false)
      RUBY

      method = NilKill::SourceIndex.new(source).methods.fetch(0)
      plan = {
        "methods" => {
          ["Worker", "mixed", "instance", File.expand_path(source), method["line"]].join("\0") => {
            "sample" => true,
            "params" => { "flag" => false },
            "return" => true,
          },
        },
      }
      FileUtils.mkdir_p(NilKill::TMP_DIR)
      File.write(NilKill::TRACE_PLAN_PATH, JSON.pretty_generate(plan))

      instrumented = File.join(dir, "sample.instrumented.rb")
      FileUtils.mkdir_p(File.dirname(instrumented))
      File.write(instrumented, NilKill::SourceInstrumenter.new.instrument_file(source))

      trace_tmp = File.join(dir, "trace-tmp")
      trace_dir = File.join(trace_tmp, "runtime")
      FileUtils.rm_rf(trace_dir)
      tracer = File.join(NilKill::ROOT, "gems", "nil-kill", "lib", "nil_kill", "runtime_trace.rb")
      env = {
        "NIL_KILL_TRACE" => "1",
        "NIL_KILL_TRACE_METHODS" => "0",
        "NIL_KILL_TMP_DIR" => trace_tmp,
        "NIL_KILL_TARGETS" => dir,
        "RUBYOPT" => "-r#{tracer}",
      }

      _out, err, status = Open3.capture3(env, "bundle", "exec", "ruby", instrumented, chdir: NilKill::ROOT)

      expect(status).to be_success, err
      method_events = Dir.glob(File.join(trace_dir, "methods-*.jsonl")).flat_map { |path| File.readlines(path, chomp: true).map { |line| JSON.parse(line) } }
      expect(method_events).to include(a_hash_including(
        "class" => "Worker",
        "method" => "mixed",
        "returns" => include("String", "Symbol"),
        "ok_calls" => 2
      ))
    end
  end

  it "uses source wrappers for source-instrumented methods with ensure" do
    Dir.mktmpdir("nil-kill-runtime-source-ensure", NilKill::ROOT) do |dir|
      source = File.join(dir, "sample.rb")
      File.write(source, <<~RUBY)
        require "sorbet-runtime"

        class Worker
          extend T::Sig

          sig { params(value: T.untyped).returns(T.untyped) }
          def guarded(value)
            value
          ensure
            @done = true
          end
        end

        Worker.new.guarded("ensured")
      RUBY

      method = NilKill::SourceIndex.new(source).methods.fetch(0)
      plan = {
        "version" => 1,
        "target_dirs" => [File.expand_path(dir)],
        "methods" => {
          ["Worker", "guarded", "instance", File.expand_path(source), method["line"]].join("\0") => {
            "sample" => true,
            "params" => { "value" => true },
            "return" => true,
          },
        },
      }
      FileUtils.mkdir_p(NilKill::TMP_DIR)
      File.write(NilKill::TRACE_PLAN_PATH, JSON.pretty_generate(plan))

      instrumented_root = File.join(dir, "instrumented")
      instrumented = File.join(instrumented_root, Pathname.new(source).relative_path_from(Pathname.new(NilKill::ROOT)).to_s)
      FileUtils.mkdir_p(File.dirname(instrumented))
      instrumented_source = NilKill::SourceInstrumenter.new.instrument_file(source)
      File.write(instrumented, instrumented_source)

      trace_plan = JSON.parse(File.read(NilKill::TRACE_PLAN_PATH))
      expect(instrumented_source).to include('record_source_method_call("Worker", "guarded"')
      expect(trace_plan.fetch("tracepoint_methods", {})).to be_empty

      trace_tmp = File.join(dir, "trace-tmp")
      FileUtils.mkdir_p(trace_tmp)
      File.write(File.join(trace_tmp, "trace-plan.json"), JSON.pretty_generate(trace_plan))
      trace_dir = File.join(trace_tmp, "runtime")
      FileUtils.rm_rf(trace_dir)
      tracer = File.join(NilKill::ROOT, "gems", "nil-kill", "lib", "nil_kill", "runtime_trace.rb")
      env = {
        "NIL_KILL_TRACE" => "1",
        "NIL_KILL_TRACE_METHODS" => "0",
        "NIL_KILL_TMP_DIR" => trace_tmp,
        "NIL_KILL_TARGETS" => dir,
        "NIL_KILL_INSTRUMENTED_ROOT" => instrumented_root,
        "RUBYOPT" => "-rbundler/setup -r#{tracer}",
      }

      _out, err, status = Open3.capture3(env, "ruby", instrumented, chdir: NilKill::ROOT)

      expect(status).to be_success, err
      method_events = Dir.glob(File.join(trace_dir, "methods-*.jsonl")).flat_map { |path| File.readlines(path, chomp: true).map { |line| JSON.parse(line) } }
      expect(method_events).to include(a_hash_including(
        "class" => "Worker",
        "method" => "guarded",
        "params_by_name" => a_hash_including("value" => include("String")),
        "returns" => include("String"),
        "ok_calls" => 1
      ))
    end
  end

  it "source-wraps (does NOT punt) methods with lambda-local returns" do
    Dir.mktmpdir("nil-kill-runtime-source-lambda-return", NilKill::ROOT) do |dir|
      source = File.join(dir, "sample.rb")
      File.write(source, <<~RUBY)
        require "sorbet-runtime"

        class Worker
          extend T::Sig

          sig { params(value: T.untyped).returns(T.untyped) }
          def lambda_return(value)
            fn = lambda do |item|
              return nil if item.nil?
              item
            end
            fn.call(value)
          end
        end

        Worker.new.lambda_return("lambda")
      RUBY

      method = NilKill::SourceIndex.new(source).methods.fetch(0)
      plan = {
        "version" => 1,
        "target_dirs" => [File.expand_path(dir)],
        "methods" => {
          ["Worker", "lambda_return", "instance", File.expand_path(source), method["line"]].join("\0") => {
            "sample" => true,
            "params" => { "value" => true },
            "return" => true,
          },
        },
      }
      FileUtils.mkdir_p(NilKill::TMP_DIR)
      File.write(NilKill::TRACE_PLAN_PATH, JSON.pretty_generate(plan))

      instrumented_root = File.join(dir, "instrumented")
      instrumented = File.join(instrumented_root, Pathname.new(source).relative_path_from(Pathname.new(NilKill::ROOT)).to_s)
      FileUtils.mkdir_p(File.dirname(instrumented))
      instrumented_source = NilKill::SourceInstrumenter.new.instrument_file(source)
      File.write(instrumented, instrumented_source)

      trace_plan = JSON.parse(File.read(NilKill::TRACE_PLAN_PATH))
      # A lambda-local `return` returns from the lambda, not the method
      # -- it never reaches the wrapper's catch, so the method is safely
      # SOURCE-WRAPPED (deterministic inline record), NOT punted to the
      # unreliable multi-process TracePoint fallback.
      expect(instrumented_source).to include('record_source_method_call("Worker", "lambda_return"')
      expect(trace_plan.fetch("tracepoint_methods", {})).to be_empty

      trace_tmp = File.join(dir, "trace-tmp")
      FileUtils.mkdir_p(trace_tmp)
      File.write(File.join(trace_tmp, "trace-plan.json"), JSON.pretty_generate(trace_plan))
      trace_dir = File.join(trace_tmp, "runtime")
      FileUtils.rm_rf(trace_dir)
      tracer = File.join(NilKill::ROOT, "gems", "nil-kill", "lib", "nil_kill", "runtime_trace.rb")
      env = {
        "NIL_KILL_TRACE" => "1",
        "NIL_KILL_TRACE_METHODS" => "0",
        "NIL_KILL_TMP_DIR" => trace_tmp,
        "NIL_KILL_TARGETS" => dir,
        "NIL_KILL_INSTRUMENTED_ROOT" => instrumented_root,
        "RUBYOPT" => "-rbundler/setup -r#{tracer}",
      }

      _out, err, status = Open3.capture3(env, "ruby", instrumented, chdir: NilKill::ROOT)

      expect(status).to be_success, err
      method_events = Dir.glob(File.join(trace_dir, "methods-*.jsonl")).flat_map { |path| File.readlines(path, chomp: true).map { |line| JSON.parse(line) } }
      expect(method_events).to include(a_hash_including(
        "class" => "Worker",
        "method" => "lambda_return",
        "params_by_name" => a_hash_including("value" => include("String")),
        "returns" => include("String"),
        "ok_calls" => 1
      ))
    end
  end

  it "maps instrumented line numbers back to src line numbers across a modified ivar-write line" do
    Dir.mktmpdir("nil-kill-linemap", NilKill::ROOT) do |dir|
      src = File.join(dir, "sample.rb")
      # @x = ... is a MODIFIED (rewritten) line; a naive line-equality
      # map drifts permanently after it. The method below it must still
      # map instrumented lines back into its real src def-range.
      File.write(src, <<~RUBY)
        class Foo
          def initialize
            @x = compute_value
          end

          def target(value)
            result = value.to_s
            result.upcase
          end

          def compute_value
            42
          end
        end
      RUBY

      old = ENV["NIL_KILL_TARGETS"]
      ENV["NIL_KILL_TARGETS"] = dir
      begin
        instrumented, map = NilKill::SourceInstrumenter.new.instrument_file_with_map(src)
      ensure
        ENV["NIL_KILL_TARGETS"] = old
      end

      src_lines = File.read(src).lines.map(&:chomp)
      def_idx = src_lines.index { |l| l.include?("def target(value)") }
      target_def_src = def_idx + 1
      target_end_src = src_lines[def_idx..].index { |l| l.strip == "end" } + def_idx + 1

      target_instr_lines = instrumented.lines.each_index.select do |i|
        instrumented.lines[i].include?("result.upcase") || instrumented.lines[i].include?("def target(value)")
      end.map { |i| i + 1 }

      expect(target_instr_lines).not_to be_empty
      target_instr_lines.each do |il|
        expect(map[il]).to be_between(target_def_src, target_end_src),
          "instrumented line #{il} mapped to src #{map[il]}, outside target's src range #{target_def_src}..#{target_end_src}"
      end
    end
  end
end
