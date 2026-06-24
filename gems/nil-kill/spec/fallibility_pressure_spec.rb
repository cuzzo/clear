# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe NilKill::FallibilityPressure do
  it "attributes rescue handlers to every reachable fallibility root and preserves sharedness" do
    Dir.mktmpdir("nil-kill-fallibility", NilKill::ROOT) do |dir|
      path = File.join(dir, "service.rb")
      File.write(path, <<~RUBY)
        class Service
          def root
            raise "boom"
          end

          def other
            fail "bad"
          end

          def wrapper
            root
          end

          def caller
            wrapper
          end

          def handled
            begin
              wrapper
            rescue RuntimeError
              nil
            end
          end

          def shared
            begin
              wrapper
              other
            rescue RuntimeError
              nil
            end
          end
        end
      RUBY

      rows = described_class.scan([path])
      root = rows.find { |row| row["label"] == "Service#root" }
      other = rows.find { |row| row["label"] == "Service#other" }

      expect(root).to include(
        "handler_pressure" => 2,
        "exclusive_handlers" => 1,
        "shared_handlers" => 1
      )
      expect(root.fetch("fallible_callers")).to contain_exactly("Service#caller", "Service#wrapper")
      expect(root.fetch("handlers")).to include(
        a_hash_including("method" => "Service#handled", "roots" => ["Service#root"]),
        a_hash_including("method" => "Service#shared", "roots" => contain_exactly("Service#other", "Service#root"))
      )

      expect(other).to include(
        "handler_pressure" => 1,
        "exclusive_handlers" => 0,
        "shared_handlers" => 1
      )
    end
  end

  it "treats error! and fixable!(level: :error) as direct failure sources" do
    Dir.mktmpdir("nil-kill-fallibility-source", NilKill::ROOT) do |dir|
      path = File.join(dir, "source.rb")
      File.write(path, <<~RUBY)
        class Source
          def explicit(node)
            error!(node, :bad)
          end

          def fixable(node)
            fixable!(node, message: "bad", category: :typing, fixes: [], level: :error)
          end
        end
      RUBY

      rows = described_class.scan([path])
      expect(rows).to include(
        a_hash_including("label" => "Source#explicit", "direct_sources" => [a_hash_including("kind" => "error!")]),
        a_hash_including("label" => "Source#fixable", "direct_sources" => [a_hash_including("kind" => "fixable_error")])
      )
    end
  end

  it "uses runtime raised-call evidence as a fallibility root" do
    Dir.mktmpdir("nil-kill-fallibility-runtime", NilKill::ROOT) do |dir|
      path = File.join(dir, "runtime.rb")
      File.write(path, <<~RUBY)
        class RuntimeSource
          def flaky(value)
            value
          end

          def caller(value)
            flaky(value)
          end
        end
      RUBY

      runtime = [{
        "class" => "RuntimeSource",
        "method" => "flaky",
        "kind" => "instance",
        "path" => path,
        "line" => 2,
        "calls" => 10,
        "ok_calls" => 7,
        "raised_calls" => 3,
        "raised" => ["ArgumentError"]
      }]

      rows = described_class.scan([path], runtime_methods: runtime)
      flaky = rows.find { |row| row["label"] == "RuntimeSource#flaky" }

      expect(flaky.fetch("direct_sources")).to be_empty
      expect(flaky.fetch("runtime")).to include(
        "calls" => 10,
        "raised_calls" => 3,
        "raised_rate" => 30.0,
        "raised_classes" => ["ArgumentError"]
      )
      expect(flaky.fetch("fallible_callers")).to contain_exactly("RuntimeSource#caller")
    end
  end

  it "uses runtime method edges to propagate through dynamic receivers that static resolution cannot disambiguate" do
    Dir.mktmpdir("nil-kill-fallibility-runtime-edge", NilKill::ROOT) do |dir|
      path = File.join(dir, "runtime_edge.rb")
      File.write(path, <<~RUBY)
        class RuntimeEdgePrimary
          def root
            raise "primary"
          end
        end

        class RuntimeEdgeOther
          def root
            raise "other"
          end
        end

        class RuntimeEdgeCaller
          def entry(target)
            target.root
          end
        end
      RUBY

      runtime = [{
        "class" => "RuntimeEdgePrimary",
        "method" => "root",
        "kind" => "instance",
        "path" => path,
        "line" => 2,
        "calls" => 1,
        "ok_calls" => 0,
        "raised_calls" => 1,
        "raised" => ["RuntimeError"]
      }, {
        "class" => "RuntimeEdgeCaller",
        "method" => "entry",
        "kind" => "instance",
        "path" => path,
        "line" => 12,
        "calls" => 1,
        "ok_calls" => 0,
        "raised_calls" => 1,
        "raised" => ["RuntimeError"]
      }]
      runtime_edges = [{
        "caller" => {"class" => "RuntimeEdgeCaller", "method" => "entry", "kind" => "instance", "path" => path, "line" => 12},
        "callee" => {"class" => "RuntimeEdgePrimary", "method" => "root", "kind" => "instance", "path" => path, "line" => 2},
        "calls" => 1,
        "ok_calls" => 0,
        "raised_calls" => 1
      }]

      rows = described_class.scan([path], runtime_methods: runtime, runtime_edges: runtime_edges)
      primary = rows.find { |row| row["label"] == "RuntimeEdgePrimary#root" }
      other = rows.find { |row| row["label"] == "RuntimeEdgeOther#root" }

      expect(primary.fetch("fallible_callers")).to contain_exactly("RuntimeEdgeCaller#entry")
      expect(other.fetch("fallible_callers")).to be_empty
    end
  end

  it "does not treat an observed rescued dynamic edge as unhandled propagation" do
    Dir.mktmpdir("nil-kill-fallibility-runtime-handled-edge", NilKill::ROOT) do |dir|
      path = File.join(dir, "runtime_handled_edge.rb")
      File.write(path, <<~RUBY)
        class RuntimeHandledPrimary
          def root
            raise "primary"
          end
        end

        class RuntimeHandledOther
          def root
            raise "other"
          end
        end

        class RuntimeHandledCaller
          def entry(target)
            target.root
          rescue RuntimeError
            nil
          end
        end
      RUBY

      runtime = [{
        "class" => "RuntimeHandledPrimary",
        "method" => "root",
        "kind" => "instance",
        "path" => path,
        "line" => 2,
        "calls" => 1,
        "ok_calls" => 0,
        "raised_calls" => 1,
        "raised" => ["RuntimeError"]
      }, {
        "class" => "RuntimeHandledCaller",
        "method" => "entry",
        "kind" => "instance",
        "path" => path,
        "line" => 12,
        "calls" => 1,
        "ok_calls" => 1,
        "raised_calls" => 0,
        "raised" => []
      }]
      runtime_edges = [{
        "caller" => {"class" => "RuntimeHandledCaller", "method" => "entry", "kind" => "instance", "path" => path, "line" => 12},
        "callee" => {"class" => "RuntimeHandledPrimary", "method" => "root", "kind" => "instance", "path" => path, "line" => 2},
        "calls" => 1,
        "ok_calls" => 0,
        "raised_calls" => 1
      }]

      rows = described_class.scan([path], runtime_methods: runtime, runtime_edges: runtime_edges)
      primary = rows.find { |row| row["label"] == "RuntimeHandledPrimary#root" }

      expect(primary.fetch("fallible_callers")).to be_empty
    end
  end

  it "attributes rescue modifiers around constant receiver class calls" do
    Dir.mktmpdir("nil-kill-fallibility-modifier", NilKill::ROOT) do |dir|
      path = File.join(dir, "modifier.rb")
      File.write(path, <<~RUBY)
        class Utility
          def self.root
            raise "boom"
          end
        end

        class Runner
          def self.call
            Utility.root rescue nil
          end
        end
      RUBY

      rows = described_class.scan([path])
      root = rows.find { |row| row["label"] == "Utility.root" }

      expect(root).to include(
        "handler_pressure" => 1,
        "exclusive_handlers" => 1,
        "shared_handlers" => 0
      )
      expect(root.fetch("handlers")).to include(
        a_hash_including(
          "method" => "Runner.call",
          "kind" => "rescue_modifier",
          "protected_calls" => ["Utility.root"],
          "roots" => ["Utility.root"]
        )
      )
    end
  end

  it "attributes handlers around direct failure sources in the same method" do
    Dir.mktmpdir("nil-kill-fallibility-direct-handler", NilKill::ROOT) do |dir|
      path = File.join(dir, "direct_handler.rb")
      File.write(path, <<~RUBY)
        class DirectHandler
          def handled
            begin
              raise "boom"
            rescue RuntimeError
              nil
            end
          end
        end
      RUBY

      rows = described_class.scan([path])
      handled = rows.find { |row| row["label"] == "DirectHandler#handled" }

      expect(handled).to include(
        "handler_pressure" => 1,
        "exclusive_handlers" => 1,
        "shared_handlers" => 0
      )
      expect(handled.fetch("fallible_callers")).to be_empty
      expect(handled.fetch("handlers")).to include(
        a_hash_including(
          "method" => "DirectHandler#handled",
          "protected_calls" => ["DirectHandler#handled"],
          "roots" => ["DirectHandler#handled"]
        )
      )
    end
  end

  it "resolves explicit singleton definitions and class-open singleton definitions" do
    Dir.mktmpdir("nil-kill-fallibility-singleton", NilKill::ROOT) do |dir|
      path = File.join(dir, "singleton.rb")
      File.write(path, <<~RUBY)
        class ExplicitSingleton
          def self.entry
            ExplicitSingleton.root
          end
        end

        def ExplicitSingleton.root
          raise "boom"
        end

        module OuterSingleton
          class Service
            class << self
              def entry
                root
              end

              def root
                fail "boom"
              end
            end
          end
        end
      RUBY

      rows = described_class.scan([path])
      explicit = rows.find { |row| row["label"] == "ExplicitSingleton.root" }
      opened = rows.find { |row| row["label"] == "OuterSingleton::Service.root" }

      expect(explicit.fetch("fallible_callers")).to contain_exactly("ExplicitSingleton.entry")
      expect(opened.fetch("fallible_callers")).to contain_exactly("OuterSingleton::Service.entry")
    end
  end

  it "resolves relative constant receivers through lexical owners" do
    Dir.mktmpdir("nil-kill-fallibility-relative-constant", NilKill::ROOT) do |dir|
      path = File.join(dir, "relative_constant.rb")
      File.write(path, <<~RUBY)
        class Target
          def self.root
            raise "top level"
          end
        end

        module RelativeOwner
          class Target
            def self.root
              raise "nested"
            end
          end

          class Caller
            def self.entry
              Target.root
            end
          end
        end
      RUBY

      rows = described_class.scan([path])
      nested = rows.find { |row| row["label"] == "RelativeOwner::Target.root" }
      top = rows.find { |row| row["label"] == "Target.root" }

      expect(nested.fetch("fallible_callers")).to contain_exactly("RelativeOwner::Caller.entry")
      expect(top.fetch("fallible_callers")).to be_empty
    end
  end

  it "resolves included module methods without relying on globally unique method names" do
    Dir.mktmpdir("nil-kill-fallibility-mixin", NilKill::ROOT) do |dir|
      path = File.join(dir, "mixin.rb")
      File.write(path, <<~RUBY)
        module PrimaryMixin
          def root
            raise "primary"
          end
        end

        module OtherMixin
          def root
            raise "other"
          end
        end

        class MixinCaller
          include PrimaryMixin

          def entry
            root
          end
        end
      RUBY

      rows = described_class.scan([path])
      primary = rows.find { |row| row["label"] == "PrimaryMixin#root" }
      other = rows.find { |row| row["label"] == "OtherMixin#root" }

      expect(primary.fetch("fallible_callers")).to contain_exactly("MixinCaller#entry")
      expect(other.fetch("fallible_callers")).to be_empty
    end
  end

  it "resolves methods through nested included modules" do
    Dir.mktmpdir("nil-kill-fallibility-nested-mixin", NilKill::ROOT) do |dir|
      path = File.join(dir, "nested_mixin.rb")
      File.write(path, <<~RUBY)
        module InnerMixin
          def root
            raise "nested"
          end
        end

        module OuterMixin
          include InnerMixin
        end

        class NestedMixinCaller
          include OuterMixin

          def entry
            root
          end
        end
      RUBY

      rows = described_class.scan([path])
      root = rows.find { |row| row["label"] == "InnerMixin#root" }

      expect(root.fetch("fallible_callers")).to contain_exactly("NestedMixinCaller#entry")
    end
  end

  it "indexes methods inside constant-assigned class factory blocks under the assigned constant" do
    Dir.mktmpdir("nil-kill-fallibility-struct-block", NilKill::ROOT) do |dir|
      path = File.join(dir, "struct_block.rb")
      File.write(path, <<~RUBY)
        module StructNamespace
          Record = Struct.new(:value) do
            def root
              raise "record"
            end

            def entry
              root
            end
          end
        end
      RUBY

      rows = described_class.scan([path])
      root = rows.find { |row| row["label"] == "StructNamespace::Record#root" }

      expect(root.fetch("fallible_callers")).to contain_exactly("StructNamespace::Record#entry")
    end
  end

  it "does not treat arbitrary constant-assigned call blocks as class factories" do
    Dir.mktmpdir("nil-kill-fallibility-non-factory-block", NilKill::ROOT) do |dir|
      path = File.join(dir, "non_factory_block.rb")
      File.write(path, <<~RUBY)
        module DslNamespace
          Config = build_config do
            def root
              raise "dsl"
            end

            def entry
              root
            end
          end
        end
      RUBY

      rows = described_class.scan([path])
      root = rows.find { |row| row["label"] == "DslNamespace#root" }

      expect(rows.map { |row| row["label"] }).not_to include("DslNamespace::Config#root")
      expect(root.fetch("fallible_callers")).to contain_exactly("DslNamespace#entry")
    end
  end

  it "renders fallibility pressure in the nil-kill report" do
    evidence = {
      "target_dirs" => ["src"],
      "target_exclude_dirs" => [],
      "methods" => [],
      "facts" => {
        "unsigned_methods" => [],
        "existing_sigs" => [],
        "tlet_sites" => [],
        "type_normalizers" => [],
        "fallibility_pressure" => [{
          "label" => "Parser#parse",
          "path" => "src/parser.rb",
          "line" => 12,
          "score" => 9,
          "direct_sources" => [{"path" => "src/parser.rb", "line" => 15, "kind" => "raise", "code" => "raise ParserError"}],
          "runtime" => {"calls" => 20, "ok_calls" => 18, "raised_calls" => 2, "raised_rate" => 10.0, "raised_classes" => ["ParserError"]},
          "fallible_callers" => ["Compiler#run"],
          "handler_pressure" => 1,
          "exclusive_handlers" => 1,
          "shared_handlers" => 0,
          "handlers" => [{
            "path" => "src/compiler.rb",
            "line" => 40,
            "method" => "Compiler#run",
            "kind" => "rescue",
            "roots" => ["Parser#parse"],
            "protected_calls" => ["Parser#parse"],
            "unknown_calls" => 0
          }]
        }, {
          "label" => "Tiny#helper",
          "path" => "src/tiny.rb",
          "line" => 3,
          "score" => 1,
          "direct_sources" => [{"path" => "src/tiny.rb", "line" => 4, "kind" => "raise", "code" => "raise Nope"}],
          "runtime" => {"calls" => 0, "ok_calls" => 0, "raised_calls" => 0, "raised_rate" => 0.0, "raised_classes" => []},
          "fallible_callers" => [],
          "handler_pressure" => 0,
          "exclusive_handlers" => 0,
          "shared_handlers" => 0,
          "handlers" => []
        }]
      },
      "diagnostics" => {"sorbet_errors" => [], "nil_origins" => [], "sorbet_feedback" => []},
      "actions" => []
    }

    expect { NilKill::Report.new(["--output-path", NilKill::REPORT_PATH], evidence: evidence).run }
      .to output(/Fallibility Pressure \(1\).*hidden low-tail roots: 1.*Parser#parse/m).to_stdout
    expect(File.read(NilKill::REPORT_PATH)).not_to include("Tiny#helper")
  end

  it "writes fallibility pressure facts during infer" do
    # skip "fallibility pressure pending in Rust FactMine (Phase 3)"
    Dir.mktmpdir("nil-kill-fallibility-infer", NilKill::ROOT) do |dir|
      path = File.join(dir, "pipeline.rb")
      File.write(path, <<~RUBY)
        class PipelineFallibility
          def root
            raise "boom"
          end

          def handled
            begin
              root
            rescue RuntimeError
              nil
            end
          end
        end
      RUBY

      isolated_env("NIL_KILL_TARGETS" => dir) do
        expect { NilKill::Infer.new(["--no-sorbet"]).run }
          .to output(/Fallibility Pressure \(0\).*1 low-tail hidden/m).to_stdout
      end

      evidence = JSON.parse(File.read(NilKill::EVIDENCE_PATH))
      rows = evidence.dig("facts", "fallibility_pressure")
      expect(rows).to include(
        a_hash_including(
          "label" => "PipelineFallibility#root",
          "fallible_callers" => ["PipelineFallibility#handled"],
          "handler_pressure" => 0
        )
      )
    end
  end
end
