# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe NilKill::SourceIndex do
  it "indexes methods, sigs, dead nil checks, structs, tuples, hashes, and normalizers" do
    Dir.mktmpdir("nil-kill-source-index") do |dir|
      path = File.join(dir, "sample.rb")
      File.write(path, <<~RUBY)
        class Example
          extend T::Sig

          Node = Struct.new(:token, :items)

          sig { params(reason: String).returns(String) }
          def run(reason)
            tuple = [:name, 1]
            shape = {name: "x", value: 1}
            node = Node.new("tok", [])
            t = reason.is_a?(Type) ? reason : Type.new(reason)
            reason&.upcase
            reason.nil?
            t.to_s
          end
        end
      RUBY

      idx = described_class.new(path)

      expect(idx.methods).to include(a_hash_including(
        "class" => "Example",
        "method" => "run",
        "has_sig" => true,
        "non_nil_params" => include("reason")
      ))
      expect(idx.dead_nil_checks).to include(a_hash_including("kind" => "safe_nav", "code" => "reason&.upcase"))
      expect(idx.dead_nil_checks).to include(a_hash_including("kind" => "nil_check", "code" => "reason.nil?"))
      expect(idx.struct_declarations).to include(a_hash_including("class" => "Example::Node", "fields" => %w[token items]))
      expect(idx.struct_field_static).to include(a_hash_including("class" => "Example::Node", "field" => "token", "type" => "String"))
      expect(idx.tuple_arrays).to include(a_hash_including("types" => %w[Symbol Integer]))
      expect(idx.hash_shapes).to include(a_hash_including("keys" => %w[name value]))
      expect(idx.type_normalizers).to include(a_hash_including("method" => "run", "code" => include("is_a?(Type)")))
    end
  end

  it "identifies T.must around a total call without flagging a nilable call" do
    Dir.mktmpdir("nil-kill-source-index-t-must") do |dir|
      path = File.join(dir, "sample.rb")
      File.write(path, <<~RUBY)
        class Example
          extend T::Sig

          sig { returns(String) }
          def total
            "value"
          end

          sig { returns(T.nilable(String)) }
          def optional
            nil
          end

          sig { returns(String) }
          def run
            T.must(total)
            T.must(optional)
          end
        end
      RUBY

      checks = described_class.new(path).dead_nil_checks

      expect(checks).to include(a_hash_including(
        "kind" => "non_nil_assertion",
        "code" => "T.must(total)",
        "subject" => "total"
      ))
      expect(checks).not_to include(a_hash_including("code" => "T.must(optional)"))

      actions = NilKill::Analyzers::RuntimeEvidenceAnalyzer.new(
        "languages" => ["ruby"],
        "static" => { "facts" => { "dead_nil_checks" => checks } }
      ).analyze
      expect(actions).to include(a_hash_including(
        "kind" => "replace_deterministic_guard",
        "data" => a_hash_including("operation" => "remove_non_nil_assertion")
      ))
    end
  end

  it "indexes Ruby struct block owners and Sorbet struct fields" do
    Dir.mktmpdir("nil-kill-source-index-struct-owners") do |dir|
      path = File.join(dir, "sample.rb")
      File.write(path, <<~RUBY)
        module Sample
          module DropField
            extend T::Sig

            sig { returns(String) }
            def token
              "fallback"
            end
          end

          Item = Struct.new(:token) do
            include DropField

            sig { returns(String) }
            def token
              self[:token].to_s
            end
          end

          class Record < T::Struct
            const :value, String

            def helper
              const :not_a_field, String
            end

            prop :after_method, Integer
          end
        end
      RUBY

      idx = described_class.new(path)

      expect(idx.methods).to include(a_hash_including("class" => "Sample::Item", "method" => "token", "has_sig" => true))
      expect(idx.struct_declarations).to include(a_hash_including("class" => "Sample::Item", "fields" => %w[token]))
      expect(idx.included_modules).to include(a_hash_including("class" => "Sample::Item", "module" => "Sample::DropField"))
      expect(idx.sorbet_state_fields).to include(a_hash_including("class" => "Sample::Record", "field" => "value", "type" => "String"))
      expect(idx.sorbet_state_fields).to include(a_hash_including("class" => "Sample::Record", "field" => "after_method", "type" => "Integer"))
      expect(idx.sorbet_state_fields).not_to include(a_hash_including("field" => "not_a_field"))
    end
  end

  it "indexes reusable return-usage and hash-record escape facts" do
    Dir.mktmpdir("nil-kill-source-index-facts") do |dir|
      path = File.join(dir, "sample.rb")
      File.write(path, <<~RUBY)
        class Example
          def produce
            items << {name: name, id: id}
            fallback
          end

          def consume
            produce
          end

          def route(mode)
            mode == :fast || mode == :safe
          end
        end
      RUBY

      idx = described_class.new(path)

      expect(idx.return_usage_sites).to include(a_hash_including(
        "name" => "produce",
        "context" => "return",
        "current_method" => "consume"
      ))
      expect(idx.return_direct_usage_sites).to include(a_hash_including(
        "name" => "produce",
        "context" => "return",
        "current_method" => "consume"
      ))
      expect(idx.hash_record_escape_sites).to include(a_hash_including(
        "line" => 3,
        "code" => "{name: name, id: id}",
        "escapes_collection" => true
      ))
      expect(idx.hidden_enum_observations).to include(a_hash_including(
        "kind" => "param",
        "slot" => "mode",
        "values" => include(a_hash_including("value" => ":fast"))
      ))

      usage_only = described_class.new(path, usage_only: true)
      expect(usage_only.methods).to be_empty
      expect(usage_only.hash_record_escape_sites).to be_empty
      expect(usage_only.return_usage_sites).not_to be_empty
    end
  end

  it "records splat / double-splat / block params as untraceable (def-side, not sig-side)" do
    Dir.mktmpdir("nil-kill-untraceable") do |dir|
      path = File.join(dir, "sample.rb")
      File.write(path, <<~RUBY)
        class Example
          extend T::Sig

          sig { params(node: Integer, type_kwargs: T.untyped).returns(T.nilable(Integer)) }
          def lift(node, **type_kwargs)
            node
          end

          sig { params(items: T.untyped, blk: T.untyped).returns(T.untyped) }
          def each_item(*items, &blk)
            items
          end
        end
      RUBY

      idx = described_class.new(path)

      expect(idx.methods).to include(a_hash_including(
        "method" => "lift",
        "untraceable_params" => ["type_kwargs"]
      ))
      expect(idx.methods).to include(a_hash_including(
        "method" => "each_item",
        "untraceable_params" => contain_exactly("items", "blk")
      ))
    end
  end

  it "recognizes multiline sig blocks above class methods" do
    Dir.mktmpdir("nil-kill-multiline-sig") do |dir|
      path = File.join(dir, "sample.rb")
      File.write(path, <<~RUBY)
        class Example
          extend T::Sig

          sig do
            params(
              value: String,
              count: Integer
            ).returns(T::Hash[String, Integer])
          end
          def self.build(value:, count:)
            {value => count}
          end

          def self.unsigned(value)
            value
          end
        end
      RUBY

      idx = described_class.new(path)
      method = idx.methods.find { |entry| entry["method"] == "build" }
      unsigned = idx.methods.find { |entry| entry["method"] == "unsigned" }

      expect(method).to include(
        "kind" => "class",
        "has_sig" => true,
        "sig" => include("returns(T::Hash[String, Integer])")
      )
      expect(method.fetch("params")).to include(
        a_hash_including("name" => "value", "type" => "String"),
        a_hash_including("name" => "count", "type" => "Integer")
      )
      expect(unsigned).to include("kind" => "class", "has_sig" => false)
      expect(idx.summary.fetch("unsigned_methods")).to eq(1)
    end
  end

  it "attributes a type-normalizer to its method even after a nested block" do
    Dir.mktmpdir("nil-kill-normalizer-method") do |dir|
      path = File.join(dir, "sample.rb")
      File.write(path, <<~RUBY)
        class Coercer
          def normalize(input)
            if input.respond_to?(:each)
              input.each { |x| x }
            end
            t = input.is_a?(Type) ? input : Type.new(input)
            t
          end

          def from_call(node)
            ti = annotate(node)
            ti.is_a?(Type) ? ti : Type.new(ti)
          end

          def from_ivar
            @cached.is_a?(Type) ? @cached : Type.new(@cached)
          end

          private_class_method def self.prefixed(arg)
            t = arg
            t.is_a?(Type) ? t : Type.new(t)
          end
        end
      RUBY

      idx = described_class.new(path)

      # The normalizer sits AFTER a nested if/end; the old bare-`end`
      # reset mis-attributed it to method=nil. It must bind to #normalize,
      # and `input` resolves to a param origin (no in-method assignment).
      expect(idx.type_normalizers).to include(
        a_hash_including("class" => "Coercer", "method" => "normalize",
          "code" => include("input.is_a?(Type)"), "origin_kind" => "param", "origin_name" => "input")
      )
      # ti = annotate(node) -> one-hop call origin (join target = annotate's returns).
      expect(idx.type_normalizers).to include(
        a_hash_including("method" => "from_call", "origin_kind" => "call", "origin_name" => "annotate")
      )
      # @cached.is_a?(Type) -> ivar origin.
      expect(idx.type_normalizers).to include(
        a_hash_including("method" => "from_ivar", "origin_kind" => "ivar", "origin_name" => "@cached")
      )
      # `private_class_method def self.prefixed` -- the modifier prefix
      # used to leave method blank for the whole def.
      expect(idx.type_normalizers).to include(
        a_hash_including("method" => "prefixed", "code" => include("t.is_a?(Type)"))
      )
      expect(idx.type_normalizers.map { |n| n["method"] }).not_to include(nil)
    end
  end

  it "records dispatcher unions when multiple case arms share a helper" do
    Dir.mktmpdir("nil-kill-dispatcher-union") do |dir|
      path = File.join(dir, "visitor.rb")
      File.write(path, <<~RUBY)
        class Visitor
          def visit(node)
            case node
            when AST::Name, AST::Call
              visit_expr(node)
            end
          end

          def visit_expr(node)
            node
          end
        end
      RUBY

      idx = described_class.new(path)

      expect(idx.dispatcher_inferences).to include(a_hash_including(
        "helper" => "visit_expr",
        "type" => "T.any(AST::Call, AST::Name)",
        "classes" => %w[AST::Call AST::Name]
      ))
    end
  end

  it "propagates array hash element shapes through map results and keyword constructor fields" do
    described_class.reset_global_shape_indexes

    Dir.mktmpdir("nil-kill-constructor-field-shapes") do |dir|
      path = File.join(dir, "constructor_field_shapes.rb")
      File.write(path, <<~RUBY)
        class SignatureBox
          extend T::Sig

          attr_reader :params

          sig { params(params: T::Array[T::Hash[Symbol, T.untyped]]).void }
          def initialize(params:)
            @params = params
            params.each { |param| param[:name] }
          end
        end

        class Consumer
          extend T::Sig

          sig { params(raw: T::Array[T::Hash[Symbol, T.untyped]]).void }
          def run(raw)
            normalized = raw.map do |param|
              {name: "arg", type: :Any}
            end
            signature = SignatureBox.new(params: normalized)
            signature.params.each do |param|
              param[:type]
            end
          end
        end
      RUBY

      idx = described_class.new(path)
      lookup = idx.collection_index_lookups.find { |entry| entry["code"] == "param[:type]" && entry["line"] > 20 }

      expect(lookup).to include("origin" => a_hash_including("kind" => "local hash shape"))
      expect(lookup.dig("origin", "shape", "keys").keys).to include("name", "type")
    end
  ensure
    described_class.reset_global_shape_indexes
  end

  it "attributes chained first/last array element hash reads to the element shape" do
    described_class.reset_global_shape_indexes

    Dir.mktmpdir("nil-kill-chained-array-element-shapes") do |dir|
      path = File.join(dir, "chained_array_element_shapes.rb")
      File.write(path, <<~RUBY)
        class ChainedArrayElementShapes
          def run
            steps = [{expr: "x", binding: nil}]
            [steps.first[:expr], steps.last[:binding]]
          end
        end
      RUBY

      idx = described_class.new(path)
      first_lookup = idx.collection_index_lookups.find { |entry| entry["code"] == "steps.first[:expr]" }
      last_lookup = idx.collection_index_lookups.find { |entry| entry["code"] == "steps.last[:binding]" }

      expect(first_lookup).to include("origin" => a_hash_including("kind" => "local hash shape"))
      expect(first_lookup.dig("origin", "shape", "keys").keys).to include("expr", "binding")
      expect(last_lookup).to include("origin" => a_hash_including("kind" => "local hash shape"))
    end
  ensure
    described_class.reset_global_shape_indexes
  end

  it "uses a unique field array element shape when the receiver type is unknown" do
    described_class.reset_global_shape_indexes

    Dir.mktmpdir("nil-kill-unique-field-array-shape") do |dir|
      path = File.join(dir, "unique_field_array_shape.rb")
      File.write(path, <<~RUBY)
        class StepBox
          attr_reader :steps

          def initialize(steps:)
            @steps = steps
          end
        end

        class UniqueFieldArrayShape
          def build
            StepBox.new(steps: [{expr: "x", binding: nil}])
          end

          def run(box)
            out = []
            box.steps.each do |step|
              out << step
            end
            out.each do |step|
              step[:expr]
            end
          end
        end
      RUBY

      idx = described_class.new(path)
      lookup = idx.collection_index_lookups.find { |entry| entry["code"] == "step[:expr]" }

      expect(lookup).to include("origin" => a_hash_including("kind" => "local hash shape"))
      expect(lookup.dig("origin", "shape", "keys").keys).to include("expr", "binding")
    end
  ensure
    described_class.reset_global_shape_indexes
  end

        it "classifies static return origins and records return-to-param flows" do
    Dir.mktmpdir("nil-kill-return-origins") do |dir|
      path = File.join(dir, "returns.rb")
      File.write(path, <<~RUBY)
        class ReturnOrigins
          extend T::Sig

          sig { returns(String) }
          def typed_name
            "name"
          end

          sig { returns(T.untyped) }
          def strong_literal
            "literal"
          end

          sig { returns(T.untyped) }
          def from_typed_callee
            typed_name
          end

          sig { returns(T.untyped) }
          def blocked_nil(flag)
            return nil if flag
            unknown_value
          end

          def sink(value)
            value
          end

          def caller
            sink(from_typed_callee)
          end
        end
      RUBY

      idx = described_class.new(path)
      origins = idx.return_origins.each_with_object({}) { |origin, h| h[origin["method"]] = origin }

      expect(origins["strong_literal"]).to include(
        "confidence" => "strong",
        "candidate_type" => "String"
      )
      expect(origins["from_typed_callee"]).to include(
        "confidence" => "strong",
        "candidate_type" => "String"
      )
      expect(origins["blocked_nil"]).to include(
        "confidence" => "blocked",
        "candidate_type" => "T.untyped"
      )
      expect(origins["blocked_nil"]["sources"]).to include(a_hash_including("kind" => "nil"))

      expect(idx.param_origins).to include(a_hash_including(
        "callee" => "sink",
        "slot" => "0",
        "origin_kind" => "typed_return",
        "source_method" => "from_typed_callee"
      ))
    end
  end

  it "infers static return origins through parser control-flow and local expression nodes" do
    Dir.mktmpdir("nil-kill-parser-return-gaps") do |dir|
      path = File.join(dir, "parser_return_gaps.rb")
      File.write(path, <<~RUBY)
        class ParserReturnGaps
          extend T::Sig

          sig { params(flag: T::Boolean).returns(T.untyped) }
          def branch_string(flag)
            if flag
              "yes"
            else
              "no"
            end
          end

          sig { params(flag: T::Boolean).returns(T.untyped) }
          def branch_nilable(flag)
            if flag
              "yes"
            else
              nil
            end
          end

          sig { params(flag: T::Boolean).returns(T.untyped) }
          def branch_without_else(flag)
            if flag
              "yes"
            end
          end

          sig { params(flag: T::Boolean).returns(T.untyped) }
          def unless_without_else(flag)
            unless flag
              "yes"
            end
          end

          sig { returns(T.untyped) }
          def explicit_false
            return false
          end

          sig { returns(T.untyped) }
          def returned_local
            name = "Ada"
            name
          end

          sig { params(flag: T::Boolean).returns(T.untyped) }
          def branch_local(flag)
            if flag
              name = "Ada"
            else
              name = "Grace"
            end
            name
          end

          sig { params(flag: T::Boolean).returns(T.untyped) }
          def conflicting_local(flag)
            if flag
              value = "Ada"
            else
              value = 1
            end
            value
          end

          sig { returns(T.untyped) }
          def range_literal
            1..3
          end

          sig { returns(T.untyped) }
          def interpolated
            name = "Ada"
            "hello \#{name}"
          end

          sig { returns(T.untyped) }
          def parenthesized
            ("Ada")
          end

          sig { params(name: T.nilable(String)).returns(T.untyped) }
          def fallback(name)
            name || "Ada"
          end

          sig { params(items: T::Array[String]).returns(T.untyped) }
          def loop_fallthrough(items)
            while items.any?
              items.pop
            end
          end
        end
      RUBY

      idx = described_class.new(path)
      origins = idx.return_origins.each_with_object({}) { |entry, h| h[entry["method"]] = entry }

      expect(origins["branch_string"]).to include("confidence" => "strong", "candidate_type" => "String")
      expect(origins["branch_nilable"]).to include("confidence" => "strong", "candidate_type" => "T.nilable(String)")
      expect(origins["branch_without_else"]).to include("confidence" => "strong", "candidate_type" => "T.nilable(String)")
      expect(origins["unless_without_else"]).to include("confidence" => "strong", "candidate_type" => "T.nilable(String)")
      expect(origins["explicit_false"]).to include("confidence" => "strong", "candidate_type" => "T::Boolean")
      expect(origins["returned_local"]).to include("confidence" => "strong", "candidate_type" => "String")
      expect(origins["branch_local"]).to include("confidence" => "strong", "candidate_type" => "String")
      expect(origins["conflicting_local"]).to include("confidence" => "blocked", "candidate_type" => "T.untyped")
      expect(origins["conflicting_local"]["blockers"].join("\n")).to include("LocalVariableReadNode")
      expect(origins["range_literal"]).to include("confidence" => "strong", "candidate_type" => "Range")
      expect(origins["interpolated"]).to include("confidence" => "strong", "candidate_type" => "String")
      expect(origins["parenthesized"]).to include("confidence" => "strong", "candidate_type" => "String")
      expect(origins["fallback"]).to include("confidence" => "strong", "candidate_type" => "String")
      expect(origins["loop_fallthrough"]).to include("confidence" => "strong", "candidate_type" => "NilClass")
    end
  end

  it "uses RBI return types for receiver calls when source sigs are absent" do
    previous = NilKill.instance_variable_get(:@rbi_return_index)
    fake_index = Object.new
    def fake_index.return_type(name, _receiver_type = nil)
      name == "include?" ? "T::Boolean" : nil
    end
    NilKill.instance_variable_set(:@rbi_return_index, fake_index)

    Dir.mktmpdir("nil-kill-rbi-return") do |dir|
      path = File.join(dir, "rbi_return.rb")
      File.write(path, <<~RUBY)
        class RbiReturn
          extend T::Sig

          sig { params(items: T::Array[String]).returns(T.untyped) }
          def has_name(items)
            items.include?("name")
          end
        end
      RUBY

      idx = described_class.new(path)
      origin = idx.return_origins.find { |entry| entry["method"] == "has_name" }

      expect(origin).to include(
        "confidence" => "strong",
        "candidate_type" => "T::Boolean"
      )
    end
  ensure
    NilKill.instance_variable_set(:@rbi_return_index, previous)
  end

  it "parses multiline RBI return signatures" do
    Dir.mktmpdir("nil-kill-rbi-index") do |dir|
      path = File.join(dir, "core.rbi")
      File.write(path, <<~RBI)
        class Array
          sig { returns(::T.untyped) }
          def include?; end

          sig do
            params(
              arg0: T.untyped,
              blk: T.proc.params(arg0: T.untyped).returns(BasicObject),
            )
            .returns(T::Boolean)
          end
          def include?(arg0); end
        end
      RBI

      idx = NilKill::RbiReturnIndex.new
      idx.load_path(path)

      expect(idx.return_type("include?")).to eq("T::Boolean")
    end
  end

  it "filters out ambiguous stdlib RBI owners (Resolv, URI, Net) from bare-receiver fallback" do
    Dir.mktmpdir("nil-kill-rbi-resolv") do |dir|
      path = File.join(dir, "resolv_stub.rbi")
      File.write(path, <<~RBI)
        class Resolv::DNS::Name
          sig { returns(Resolv::DNS::Name) }
          def name; end
        end

        class MyProject::Node
          sig { returns(String) }
          def label; end
        end
      RBI

      idx = NilKill::RbiReturnIndex.new
      idx.load_path(path)

      # Bare-receiver fallback for `name` would previously pull
      # `Resolv::DNS::Name` -> wrong narrowing for project fields. Now it
      # filters that owner out, so the result is nil (no useful candidate).
      expect(idx.return_type("name")).to be_nil
      # Non-stdlib classes still resolve normally.
      expect(idx.return_type("label", "MyProject::Node")).to eq("String")
    end
  end

  it "normalizes Sorbet RBI boolean overload return variants" do
    Dir.mktmpdir("nil-kill-rbi-boolean-index") do |dir|
      path = File.join(dir, "boolean_core.rbi")
      File.write(path, <<~RBI)
        class BasicObject
          sig { returns(T::Boolean) }
          def !; end
        end

        class FalseClass
          sig { returns(TrueClass) }
          def !; end
        end

        class TrueClass
          sig { returns(FalseClass) }
          def !; end
        end
      RBI

      idx = NilKill::RbiReturnIndex.new
      idx.load_path(path)

      expect(idx.return_type("!")).to eq("T::Boolean")
    end
  end

  it "keeps generic collection shape from Sorbet RBI returns" do
    Dir.mktmpdir("nil-kill-rbi-generic-collections") do |dir|
      path = File.join(dir, "enumerable_core.rbi")
      File.write(path, <<~RBI)
        module Enumerable
          sig do
            type_parameters(:U)
              .params(blk: T.proc.params(arg0: Elem).returns(T.type_parameter(:U)))
              .returns(T::Array[T.type_parameter(:U)])
          end
          sig { returns(T::Enumerator[Elem]) }
          def map(&blk); end
        end
      RBI

      idx = NilKill::RbiReturnIndex.new
      idx.load_path(path)

      expect(idx.return_type("map", "T::Array[String]")).to eq("T::Array[T.untyped]")
    end
  end

  it "uses receiver types to disambiguate RBI return signatures" do
    previous = NilKill.instance_variable_get(:@rbi_return_index)
    fake_index = Object.new
    def fake_index.return_type(name, receiver_type = nil)
      return "String" if name == "join" && receiver_type == "T::Array[String]"
      nil
    end
    NilKill.instance_variable_set(:@rbi_return_index, fake_index)

    Dir.mktmpdir("nil-kill-rbi-receiver") do |dir|
      path = File.join(dir, "rbi_receiver.rb")
      File.write(path, <<~RUBY)
        class RbiReceiver
          extend T::Sig

          sig { params(items: T::Array[String]).returns(T.untyped) }
          def csv(items)
            items.join(",")
          end
        end
      RUBY

      idx = described_class.new(path)
      origin = idx.return_origins.find { |entry| entry["method"] == "csv" }

      expect(origin).to include(
        "confidence" => "strong",
        "candidate_type" => "String"
      )
    end
  ensure
    NilKill.instance_variable_set(:@rbi_return_index, previous)
  end

  it "uses Sorbet RBI return types for obvious core methods" do
    Dir.mktmpdir("nil-kill-core-returns") do |dir|
      path = File.join(dir, "core_returns.rb")
      File.write(path, <<~RUBY)
        class CoreReturns
          extend T::Sig

          sig { params(items: T::Array[String], value: String).returns(T.untyped) }
          def has_any(items, value)
            items.any? { |item| item == value }
          end

          sig { params(items: T::Array[String]).returns(T.untyped) }
          def csv(items)
            items.join(",")
          end

          sig { params(value: T.untyped).returns(T.untyped) }
          def negated(value)
            !value
          end

          sig { params(value: T.untyped).returns(T.untyped) }
          def stringified(value)
            value.to_s
          end

          sig { params(value: String).returns(T.untyped) }
          def len(value)
            value.length
          end
        end
      RUBY

      idx = described_class.new(path)
      origins = idx.return_origins.each_with_object({}) { |entry, h| h[entry["method"]] = entry }

      expect(origins["has_any"]).to include("confidence" => "strong", "candidate_type" => "T::Boolean")
      expect(origins["csv"]).to include("confidence" => "strong", "candidate_type" => "String")
      expect(origins["negated"]).to include("confidence" => "strong", "candidate_type" => "T::Boolean")
      expect(origins["stringified"]).to include("confidence" => "strong", "candidate_type" => "String")
      expect(origins["len"]).to include("confidence" => "strong", "candidate_type" => "Integer")
    end
  end

  it "propagates typed collection index lookups into return origins" do
    Dir.mktmpdir("nil-kill-collection-index-return") do |dir|
      path = File.join(dir, "collection_index_return.rb")
      File.write(path, <<~RUBY)
        class CollectionIndexReturn
          extend T::Sig

          sig { params(items: T::Array[String]).returns(T.untyped) }
          def first_item(items)
            items[0]
          end

          sig { params(items: T::Array[String]).returns(T.untyped) }
          def first_two(items)
            items[0..1]
          end

          sig { params(map: T::Hash[Symbol, Integer]).returns(T.untyped) }
          def count_for(map)
            map[:count]
          end

          sig { params(items: T::Array[T.untyped], map: T::Hash[Symbol, T.untyped]).returns(T.untyped) }
          def weak_lookup(items, map)
            [items[0], map[:count]]
          end
        end
      RUBY

      idx = described_class.new(path)
      origins = idx.return_origins.each_with_object({}) { |entry, h| h[entry["method"]] = entry }

      expect(origins["first_item"]).to include("confidence" => "strong", "candidate_type" => "T.nilable(String)")
      expect(origins["first_two"]).to include("confidence" => "strong", "candidate_type" => "T::Array[String]")
      expect(origins["count_for"]).to include("confidence" => "strong", "candidate_type" => "T.nilable(Integer)")
      expect(origins["weak_lookup"]).to include("confidence" => "weak", "candidate_type" => "T::Array[T.untyped]")
    end
  end

  it "propagates typed collection and core call results into param origins" do
    Dir.mktmpdir("nil-kill-collection-param-origin") do |dir|
      path = File.join(dir, "collection_param_origin.rb")
      File.write(path, <<~RUBY)
        class CollectionParamOrigin
          extend T::Sig

          sig { params(value: T.untyped).void }
          def sink(value); end

          sig { params(items: T::Array[String], map: T::Hash[Symbol, Integer], names: T::Set[String]).void }
          def call(items, map, names)
            sink(items[0])
            sink(map[:count])
            sink(items.length)
            sink(items.include?("x"))
            sink(names.include?("x"))
          end
        end
      RUBY

      idx = described_class.new(path)
      origins = idx.param_origins.select { |entry| entry["callee"] == "sink" }.each_with_object({}) do |entry, h|
        h[entry["code"]] = entry
      end

      expect(origins.fetch("items[0]")).to include("origin_kind" => "typed_return", "type" => "T.nilable(String)")
      expect(origins.fetch("map[:count]")).to include("origin_kind" => "typed_return", "type" => "T.nilable(Integer)")
      expect(origins.fetch("items.length")).to include("origin_kind" => "typed_return", "type" => "Integer")
      expect(origins.fetch("items.include?(\"x\")")).to include("origin_kind" => "typed_return", "type" => "T::Boolean")
      expect(origins.fetch("names.include?(\"x\")")).to include("origin_kind" => "typed_return", "type" => "T::Boolean")
    end
  end

  it "records shorthand keyword arguments as local param origins" do
    Dir.mktmpdir("nil-kill-shorthand-keyword-param-origin") do |dir|
      path = File.join(dir, "shorthand_keyword_param_origin.rb")
      File.write(path, <<~RUBY)
        class ShorthandKeywordParamOrigin
          extend T::Sig

          sig { params(value: T.untyped).void }
          def sink(value:); end

          sig { params(value: String).void }
          def call(value)
            sink(value:)
          end
        end
      RUBY

      idx = described_class.new(path)
      origin = idx.param_origins.find { |entry| entry["callee"] == "sink" && entry["slot"] == "value" }

      expect(origin).to include(
        "origin_kind" => "local",
        "code" => "value"
      )
    end
  end

  it "infers static return origins for Ruby iterator and collection mutation calls" do
    Dir.mktmpdir("nil-kill-iterator-return-origin") do |dir|
      path = File.join(dir, "iterator_return_origin.rb")
      File.write(path, <<~RUBY)
        class IteratorReturnOrigin
          extend T::Sig

          sig { params(items: T::Array[String]).returns(T.untyped) }
          def each_items(items)
            items.each { |item| item.to_s }
          end

          sig { params(map: T::Hash[Symbol, Integer]).returns(T.untyped) }
          def each_pair_map(map)
            map.each_pair { |key, value| [key, value] }
          end

          sig { params(items: T::Array[Integer]).returns(T.untyped) }
          def mapped(items)
            items.map { |item| item.to_s }
          end

          sig { params(items: T::Array[T.nilable(String)]).returns(T.untyped) }
          def filtered(items)
            items.filter_map { |item| item }
          end

          sig { params(items: T::Array[T.nilable(String)]).returns(T.untyped) }
          def compacted(items)
            items.compact
          end

          sig { params(items: T::Array[String]).returns(T.untyped) }
          def selected(items)
            items.select { |item| item.length > 1 }
          end

          sig { params(items: T::Array[String]).returns(T.untyped) }
          def appended(items)
            items << "Ada"
          end

          sig { params(items: T::Array[String], more: T::Array[String]).returns(T.untyped) }
          def concatenated(items, more)
            items.concat(more)
          end

          sig { params(items: T.untyped).returns(T.untyped) }
          def unknown_each(items)
            items.each { |item| item }
          end
        end
      RUBY

      idx = described_class.new(path)
      origins = idx.return_origins.each_with_object({}) { |entry, h| h[entry["method"]] = entry }

      expect(origins["each_items"]).to include("confidence" => "strong", "candidate_type" => "T::Array[String]")
      expect(origins["each_pair_map"]).to include("confidence" => "strong", "candidate_type" => "T::Hash[Symbol, Integer]")
      expect(origins["mapped"]).to include("confidence" => "strong", "candidate_type" => "T::Array[String]")
      expect(origins["filtered"]).to include("confidence" => "strong", "candidate_type" => "T::Array[String]")
      expect(origins["compacted"]).to include("confidence" => "strong", "candidate_type" => "T::Array[String]")
      expect(origins["selected"]).to include("confidence" => "strong", "candidate_type" => "T::Array[String]")
      expect(origins["appended"]).to include("confidence" => "strong", "candidate_type" => "T::Array[String]")
      expect(origins["concatenated"]).to include("confidence" => "strong", "candidate_type" => "T::Array[String]")
      expect(origins["unknown_each"]).to include("confidence" => "blocked", "candidate_type" => "T.untyped")
    end
  end

  it "infers local accumulator collection types from static mutations" do
    Dir.mktmpdir("nil-kill-accumulator-return-origin") do |dir|
      path = File.join(dir, "accumulator_return_origin.rb")
      File.write(path, <<~RUBY)
        class AccumulatorReturnOrigin
          extend T::Sig

          sig { returns(T.untyped) }
          def array_append
            out = []
            out << "Ada"
            out
          end

          sig { returns(T.untyped) }
          def array_push
            out = []
            out.push(1)
            out
          end

          sig { returns(T.untyped) }
          def array_concat
            out = []
            out.concat(["Ada"])
            out
          end

          sig { returns(T.untyped) }
          def array_nilable
            out = []
            out << "Ada"
            out << nil
            out
          end

          sig { returns(T.untyped) }
          def array_conflict
            out = []
            out << "Ada"
            out << 1
            out
          end

          sig { returns(T.untyped) }
          def hash_assign
            out = {}
            out[:name] = "Ada"
            out
          end

          sig { returns(T.untyped) }
          def hash_non_mutating_merge
            out = {}
            out.merge(name: "Ada")
            out
          end

          sig { returns(T.untyped) }
          def hash_mutating_merge
            out = {}
            out.merge!(name: "Ada")
            out
          end

          sig { returns(T.untyped) }
          def set_add
            out = Set.new
            out.add(:name)
            out
          end

          sig { params(node: String, out: T::Array[T.untyped]).returns(T.untyped) }
          def default_accumulator(node, out = [])
            out << node
            out
          end

          sig { params(node: String, children: T::Array[String], out: T::Array[T.untyped]).returns(T.untyped) }
          def recursive_accumulator(node, children, out = [])
            out << node
            children.each { |child| recursive_accumulator(child, [], out) }
            out
          end

          sig { returns(T.untyped) }
          def poisoned_accumulator
            out = []
            out << "Ada"
            mutate(out)
            out
          end
        end
      RUBY

      idx = described_class.new(path)
      origins = idx.return_origins.each_with_object({}) { |entry, h| h[entry["method"]] = entry }

      expect(origins["array_append"]).to include("confidence" => "strong", "candidate_type" => "T::Array[String]")
      expect(origins["array_push"]).to include("confidence" => "strong", "candidate_type" => "T::Array[Integer]")
      expect(origins["array_concat"]).to include("confidence" => "strong", "candidate_type" => "T::Array[String]")
      expect(origins["array_nilable"]).to include("confidence" => "strong", "candidate_type" => "T::Array[T.nilable(String)]")
      expect(origins["array_conflict"]).to include("confidence" => "weak", "candidate_type" => "T::Array[T.untyped]")
      expect(origins["hash_assign"]).to include("confidence" => "strong", "candidate_type" => "T::Hash[Symbol, String]")
      expect(origins["hash_non_mutating_merge"]).to include("confidence" => "weak", "candidate_type" => "T::Hash[T.untyped, T.untyped]")
      expect(origins["hash_mutating_merge"]).to include("confidence" => "strong", "candidate_type" => "T::Hash[Symbol, String]")
      expect(origins["set_add"]).to include("confidence" => "strong", "candidate_type" => "T::Set[Symbol]")
      expect(origins["default_accumulator"]).to include("confidence" => "strong", "candidate_type" => "T::Array[String]")
      expect(origins["recursive_accumulator"]).to include("confidence" => "strong", "candidate_type" => "T::Array[String]")
      expect(origins["poisoned_accumulator"]).to include("confidence" => "blocked", "candidate_type" => "T.untyped")
    end
  end

  it "propagates static hash record shapes into index lookups" do
    Dir.mktmpdir("nil-kill-hash-shape-return-origin") do |dir|
      path = File.join(dir, "hash_shape_return_origin.rb")
      File.write(path, <<~RUBY)
        class HashShapeReturnOrigin
          extend T::Sig

          sig { returns(T.untyped) }
          def local_hash_lookup
            entry = {expr: "Ada", count: 1}
            entry[:expr]
          end

          sig { returns(T.untyped) }
          def aliased_hash_lookup
            entry = {expr: "Ada"}
            alias_entry = entry
            alias_entry[:expr]
          end

          sig { params(flag: T::Boolean).returns(T.untyped) }
          def branch_hash_lookup(flag)
            if flag
              entry = {expr: "Ada"}
            else
              entry = {expr: "Grace"}
            end
            entry[:expr]
          end

          sig { params(flag: T::Boolean).returns(T.untyped) }
          def branch_hash_conflict(flag)
            if flag
              entry = {expr: "Ada"}
            else
              entry = {expr: 1}
            end
            entry[:expr]
          end

          sig { returns(T.untyped) }
          def array_of_records
            records = [{expr: "Ada"}, {expr: "Grace"}]
            records.map { |entry| entry[:expr] }
          end

          sig { returns(T.untyped) }
          def make_entry
            {expr: "Ada", token: :name}
          end

          sig { params(target: T.untyped, flag: T::Boolean).returns(T.untyped) }
          def assign_entry(target, flag)
            return unless flag
            target.entry = {expr: "Ada", token: :name}
          end

          sig { returns(T.untyped) }
          def forwarded_hash_lookup
            entry = make_entry
            entry[:token]
          end

          sig { returns(T.untyped) }
          def caller_before_callee
            helper_defined_later({expr: "Ada"})
          end

          sig { params(entry: T.untyped).returns(T.untyped) }
          def helper_defined_later(entry)
            entry[:expr]
          end

          sig { returns(T.untyped) }
          def escaped_hash_lookup
            entry = {expr: "Ada"}
            mutate(entry)
            entry[:expr]
          end
        end
      RUBY

      idx = described_class.new(path)
      origins = idx.return_origins.each_with_object({}) { |entry, h| h[entry["method"]] = entry }

      expect(origins["local_hash_lookup"]).to include("confidence" => "strong", "candidate_type" => "T.nilable(String)")
      expect(origins["aliased_hash_lookup"]).to include("confidence" => "strong", "candidate_type" => "T.nilable(String)")
      expect(origins["branch_hash_lookup"]).to include("confidence" => "strong", "candidate_type" => "T.nilable(String)")
      expect(origins["branch_hash_conflict"]).to include("confidence" => "blocked", "candidate_type" => "T.untyped")
      expect(origins["array_of_records"]).to include("confidence" => "strong", "candidate_type" => "T::Array[T.nilable(String)]")
      expect(origins["make_entry"]).to include("confidence" => "weak", "candidate_type" => "T::Hash[Symbol, T.untyped]")
      expect(origins["make_entry"]["hash_shape"]).to include("keys" => include("expr" => ["String"], "token" => ["Symbol"]))
      expect(origins["assign_entry"]["hash_shape"]).to include("keys" => include("expr" => ["String"], "token" => ["Symbol"]))
      expect(origins["forwarded_hash_lookup"]).to include("confidence" => "strong", "candidate_type" => "T.nilable(Symbol)")
      expect(origins["caller_before_callee"]).to include("confidence" => "strong", "candidate_type" => "T.nilable(String)")
      expect(origins["helper_defined_later"]).to include("confidence" => "strong", "candidate_type" => "T.nilable(String)")
      expect(origins["escaped_hash_lookup"]).to include("confidence" => "blocked", "candidate_type" => "T.untyped")
    end
  end

                      it "records explicit hash-record blockers for dynamic keys and mutations" do
    Dir.mktmpdir("nil-kill-hash-record-blockers") do |dir|
      path = File.join(dir, "hash_record_blockers.rb")
      File.write(path, <<~RUBY)
        class HashRecordBlockers
          def label(key)
            entry = {name: "Ada", id: 1}
            entry[key]
            entry[:id] = 2
            entry.merge!(name: "Grace")
          end
        end
      RUBY

      idx = described_class.new(path)

      expect(idx.hash_record_blockers).to include(
        a_hash_including("kind" => "dynamic_key", "code" => "entry[key]", "receiver" => "entry"),
        a_hash_including("kind" => "mutation", "code" => "entry[:id] = 2", "receiver" => "entry"),
        a_hash_including("kind" => "mutation", "code" => "entry.merge!(name: \"Grace\")", "receiver" => "entry")
      )
    end
  end

  it "propagates hash record shapes through cross-file attribute writers" do
    Dir.mktmpdir("nil-kill-attribute-shape-origin") do |dir|
      described_class.reset_global_shape_indexes
      producer = File.join(dir, "producer.rb")
      consumer = File.join(dir, "consumer.rb")
      File.write(producer, <<~RUBY)
        class Producer
          def attach(node)
            clauses = []
            clauses << {expr: "Ada", source: :pre}
            node.pre_clauses = clauses
          end
        end
      RUBY
      File.write(consumer, <<~RUBY)
        class Consumer
          extend T::Sig

          sig { params(value: T.untyped).void }
          def sink(value); end

          sig { params(fn_node: T.untyped).void }
          def consume(fn_node)
            fn_node.pre_clauses.each do |entry|
              sink(entry[:expr])
            end
          end
        end
      RUBY

      described_class.new(producer)
      idx = described_class.new(consumer)
      origin = idx.param_origins.find { |entry| entry["callee"] == "sink" && entry["code"] == "entry[:expr]" }

      expect(origin).to include("origin_kind" => "typed_return", "type" => "T.nilable(String)")
      expect(idx.collection_index_lookups).to include(a_hash_including(
        "code" => "entry[:expr]",
        "receiver_type" => "T::Hash[T.untyped, T.untyped]",
        "lookup_type" => "T.nilable(String)",
        "status" => "typed lookup"
      ))
    ensure
      described_class.reset_global_shape_indexes
    end
  end

  it "learns hash-record array element schemas from callsites for param and return inference" do
    Dir.mktmpdir("nil-kill-hash-record-array-param-shape") do |dir|
      path = File.join(dir, "hash_record_array_param_shape.rb")
      File.write(path, <<~RUBY)
        class HashRecordArrayParamShape
          extend T::Sig

          sig { params(value: T.untyped).void }
          def sink(value); end

          sig { void }
          def caller
            consume_caps([{capability: :VIEW, var_node: "source"}])
            cap_names([{capability: :SNAPSHOT, var_node: "cache"}])
          end

          sig { params(caps: T::Array[T.untyped]).void }
          def consume_caps(caps)
            caps.each do |c|
              sink(c[:capability])
              sink(c[:var_node])
            end
          end

          sig { params(caps: T::Array[T.untyped]).returns(T.untyped) }
          def cap_names(caps)
            caps.map { |cap| cap[:capability] }
          end
        end
      RUBY

      idx = described_class.new(path)
      origins = idx.param_origins.select { |entry| entry["callee"] == "sink" }.each_with_object({}) do |entry, h|
        h[entry["code"]] = entry
      end
      returns = idx.return_origins.each_with_object({}) { |entry, h| h[entry["method"]] = entry }

      expect(origins.fetch("c[:capability]")).to include("origin_kind" => "typed_return", "type" => "T.nilable(Symbol)")
      expect(origins.fetch("c[:var_node]")).to include("origin_kind" => "typed_return", "type" => "T.nilable(String)")
      expect(returns.fetch("cap_names")).to include("confidence" => "strong", "candidate_type" => "T::Array[T.nilable(Symbol)]")
    end
  end

  it "propagates hash-record array element schemas through forwarded method returns" do
    Dir.mktmpdir("nil-kill-forwarded-hash-record-array-shape") do |dir|
      path = File.join(dir, "forwarded_hash_record_array_shape.rb")
      File.write(path, <<~RUBY)
        class ForwardedHashRecordArrayShape
          extend T::Sig

          sig { params(value: T.untyped).void }
          def sink(value); end

          sig { returns(T.untyped) }
          def build_caps
            [{capability: :VIEW, var_node: "source"}]
          end

          sig { void }
          def caller
            consume_caps(build_caps)
          end

          sig { params(caps: T::Array[T.untyped]).void }
          def consume_caps(caps)
            caps.each do |c|
              sink(c[:capability])
              sink(c[:var_node])
            end
          end
        end
      RUBY

      idx = described_class.new(path)
      origins = idx.param_origins.select { |entry| entry["callee"] == "sink" }.each_with_object({}) do |entry, h|
        h[entry["code"]] = entry
      end
      returns = idx.return_origins.each_with_object({}) { |entry, h| h[entry["method"]] = entry }

      expect(returns.fetch("build_caps")).to include("confidence" => "weak", "candidate_type" => "T::Array[T::Hash[Symbol, T.untyped]]")
      expect(origins.fetch("c[:capability]")).to include("origin_kind" => "typed_return", "type" => "T.nilable(Symbol)")
      expect(origins.fetch("c[:var_node]")).to include("origin_kind" => "typed_return", "type" => "T.nilable(String)")
    end
  end

  it "flows hash-record arrays through struct constructor fields and accessors" do
    Dir.mktmpdir("nil-kill-struct-field-record-flow") do |dir|
      described_class.reset_global_shape_indexes
      path = File.join(dir, "struct_field_record_flow.rb")
      File.write(path, <<~RUBY)
        module AST
          WithBlock = Struct.new(:token, :capabilities, :body)
        end

        class StructFieldRecordFlow
          extend T::Sig

          sig { returns(AST::WithBlock) }
          def build_node
            caps = [{capability: :VIEW, var_node: "source"}]
            AST::WithBlock.new(nil, caps, [])
          end

          sig { params(value: T.untyped).void }
          def sink(value); end

          sig { void }
          def consume
            node = build_node
            node.capabilities.each do |c|
              sink(c[:capability])
              sink(c[:var_node])
            end
          end
        end
      RUBY

      idx = described_class.new(path)
      origins = idx.param_origins.select { |entry| entry["callee"] == "sink" }.each_with_object({}) do |entry, h|
        h[entry["code"]] = entry
      end

      expect(origins.fetch("c[:capability]")).to include("origin_kind" => "typed_return", "type" => "T.nilable(Symbol)")
      expect(origins.fetch("c[:var_node]")).to include("origin_kind" => "typed_return", "type" => "T.nilable(String)")
    ensure
      described_class.reset_global_shape_indexes
    end
  end

  it "flows scalar struct constructor field evidence into accessor calls" do
    Dir.mktmpdir("nil-kill-struct-field-scalar-flow") do |dir|
      described_class.reset_global_shape_indexes
      path = File.join(dir, "struct_field_scalar_flow.rb")
      File.write(path, <<~RUBY)
        module Lexer
          Token = Struct.new(:type, :value)
        end

        class StructFieldScalarFlow
          extend T::Sig

          sig { returns(Lexer::Token) }
          def token
            Lexer::Token.new(:VAR_ID, "name")
          end

          sig { returns(T.untyped) }
          def token_value
            token.value
          end
        end
      RUBY

      idx = described_class.new(path)
      origins = idx.return_origins.each_with_object({}) { |entry, h| h[entry["method"]] = entry }

      expect(origins.fetch("token_value")).to include("confidence" => "strong", "candidate_type" => "String")
    ensure
      described_class.reset_global_shape_indexes
    end
  end

  it "preserves record array evidence through fallback expressions" do
    Dir.mktmpdir("nil-kill-record-fallback-flow") do |dir|
      described_class.reset_global_shape_indexes
      path = File.join(dir, "record_fallback_flow.rb")
      File.write(path, <<~RUBY)
        module AST
          WithBlock = Struct.new(:capabilities)
        end

        class RecordFallbackFlow
          extend T::Sig

          sig { returns(AST::WithBlock) }
          def build_node
            AST::WithBlock.new([{capability: :VIEW, alias_mutable: true}])
          end

          sig { params(value: T.untyped).void }
          def sink(value); end

          sig { void }
          def consume
            node = build_node
            caps = node.capabilities || []
            caps.select { |cap| cap[:alias_mutable] }.each do |cap|
              sink(cap[:capability])
            end
          end
        end
      RUBY

      idx = described_class.new(path)
      origin = idx.param_origins.find { |entry| entry["callee"] == "sink" && entry["code"] == "cap[:capability]" }
      lookup = idx.collection_index_lookups.find { |entry| entry["code"] == "cap[:capability]" }

      expect(origin).to include("origin_kind" => "typed_return", "type" => "T.nilable(Symbol)")
      expect(lookup).to include("lookup_type" => "T.nilable(Symbol)", "status" => "typed lookup")
    ensure
      described_class.reset_global_shape_indexes
    end
  end

  it "types assignment expressions from the assigned RHS" do
    Dir.mktmpdir("nil-kill-assignment-return") do |dir|
      path = File.join(dir, "assignment_return.rb")
      File.write(path, <<~RUBY)
        class AssignmentReturn
          extend T::Sig

          sig { returns(T.untyped) }
          def attr_set
            self.name = "Ada"
          end

          sig { params(items: T::Array[T.untyped]).returns(T.untyped) }
          def index_set(items)
            items[0] = 1
          end

          def name=(value)
          end
        end
      RUBY

      idx = described_class.new(path)
      origins = idx.return_origins.each_with_object({}) { |entry, h| h[entry["method"]] = entry }

      expect(origins["attr_set"]).to include("confidence" => "strong", "candidate_type" => "String")
      expect(origins["index_set"]).to include("confidence" => "strong", "candidate_type" => "Integer")
    end
  end

  it "propagates local receiver types into RBI return lookup" do
    previous = NilKill.instance_variable_get(:@rbi_return_index)
    fake_index = Object.new
    def fake_index.return_type(name, receiver_type = nil)
      return "String" if name == "join" && receiver_type&.start_with?("T::Array[")
      return "T::Array[T.untyped]" if name == "map" && receiver_type&.start_with?("T::Array[")
      nil
    end
    NilKill.instance_variable_set(:@rbi_return_index, fake_index)

    Dir.mktmpdir("nil-kill-local-receiver") do |dir|
      path = File.join(dir, "local_receiver.rb")
      File.write(path, <<~RUBY)
        class LocalReceiver
          extend T::Sig

          sig { returns(T.untyped) }
          def joined
            parts = []
            parts.join("")
          end

          sig { params(args: T::Array[T.untyped]).returns(T.untyped) }
          def fallback_join(args)
            (args || []).map { |arg| arg }.join(", ")
          end

          sig { params(items: T::Array[String]).returns(T.untyped) }
          def slice_join(items)
            slice = items[0..1]
            slice.join
          end
        end
      RUBY

      idx = described_class.new(path)
      origins = idx.return_origins.each_with_object({}) { |entry, h| h[entry["method"]] = entry }

      expect(origins["joined"]).to include("confidence" => "strong", "candidate_type" => "String")
      expect(origins["fallback_join"]).to include("confidence" => "strong", "candidate_type" => "String")
      expect(origins["slice_join"]).to include("confidence" => "strong", "candidate_type" => "String")
    end
  ensure
    NilKill.instance_variable_set(:@rbi_return_index, previous)
  end

  it "uses RBI NilClass returns for bare Kernel-style calls" do
    previous = NilKill.instance_variable_get(:@rbi_return_index)
    fake_index = Object.new
    def fake_index.return_type(name, _receiver_type = nil)
      name == "puts" ? "NilClass" : nil
    end
    NilKill.instance_variable_set(:@rbi_return_index, fake_index)

    Dir.mktmpdir("nil-kill-rbi-kernel") do |dir|
      path = File.join(dir, "rbi_kernel.rb")
      File.write(path, <<~RUBY)
        class RbiKernel
          extend T::Sig

          sig { returns(T.untyped) }
          def log
            puts("ok")
          end
        end
      RUBY

      idx = described_class.new(path)
      origin = idx.return_origins.find { |entry| entry["method"] == "log" }

      expect(origin).to include(
        "confidence" => "strong",
        "candidate_type" => "NilClass"
      )
    end
  ensure
    NilKill.instance_variable_set(:@rbi_return_index, previous)
  end

  it "types class constants used as argument values" do
    Dir.mktmpdir("nil-kill-class-constant-arg") do |dir|
      path = File.join(dir, "class_constant_arg.rb")
      File.write(path, <<~RUBY)
        class ClassConstantArg
          extend T::Sig

          sig { params(value: T.untyped).void }
          def takes(value); end

          sig { void }
          def call
            takes(String)
          end
        end
      RUBY

      idx = described_class.new(path)
      origin = idx.param_origins.find { |entry| entry["callee"] == "takes" && entry["code"] == "String" }
      expect(origin).to include(
        "origin_kind" => "static",
        "type" => "T.class_of(String)"
      )
    end
  end

  it "attributes collection index lookups to visible local and ivar origins" do
    Dir.mktmpdir("nil-kill-index-origin") do |dir|
      path = File.join(dir, "index_origin.rb")
      File.write(path, <<~RUBY)
        class IndexOrigin
          extend T::Sig

          sig { params(items: T::Array[T.untyped]).returns(T.untyped) }
          def initialize(items)
            @items = items
          end

          sig { params(values: T::Hash[String, T.untyped]).returns(T.untyped) }
          def fetch(values)
            local = { "name" => 1 }
            [values["name"], local["name"], @items[0]]
          end
        end
      RUBY

      idx = described_class.new(path)
      by_receiver = idx.collection_index_lookups.each_with_object({}) { |lookup, h| h[lookup["receiver"]] = lookup }

      expect(by_receiver.fetch("values")).to include(
        "status" => "weak collection receiver",
        "receiver_type" => "T::Hash[String, T.untyped]"
      )
      expect(by_receiver.fetch("values").fetch("origin")).to include(
        "kind" => "method parameter",
        "name" => "values"
      )

      expect(by_receiver.fetch("local").fetch("origin")).to include(
        "kind" => "hash literal",
        "hash_key_types" => ["String"],
        "hash_value_types" => ["Integer"]
      )

      expect(by_receiver.fetch("@items").fetch("origin")).to include(
        "kind" => "method parameter",
        "name" => "@items",
        "alias_of" => "items"
      )
    end
  end

  it "does not treat Sorbet generic type syntax as collection index lookup" do
    Dir.mktmpdir("nil-kill-type-index") do |dir|
      path = File.join(dir, "type_index.rb")
      File.write(path, <<~RUBY)
        class TypeIndex
          extend T::Sig

          sig { params(items: T::Array[String]).returns(T::Hash[String, Integer]) }
          def call(items)
            {"first" => items[0]}
          end
        end
      RUBY

      idx = described_class.new(path)

      expect(idx.collection_index_lookups.map { |lookup| lookup["code"] }).to eq(["items[0]"])
    end
  end

  it "does not classify typed array indexing or mutation as hash-record blockers" do
    Dir.mktmpdir("nil-kill-array-hash-record-blockers") do |dir|
      path = File.join(dir, "typed_arrays.rb")
      File.write(path, <<~RUBY)
        class TypedArrays
          extend T::Sig

          sig do
            params(
              tokens: T::Array[String],
              closings: T::Array[T.nilable(Integer)],
              position: Integer
            ).returns(T.nilable(String))
          end
          def lookup(tokens, closings, position)
            closings[position] = position
            tokens[position]
          end
        end
      RUBY

      idx = described_class.new(path)

      expect(idx.collection_index_lookups.map { |lookup| lookup["code"] }).to include("tokens[position]")
      expect(idx.hash_record_blockers).to be_empty
    end
  end

  it "does not propose NilClass T.let sites for nil ivar placeholders" do
    Dir.mktmpdir("nil-kill-nil-ivar") do |dir|
      path = File.join(dir, "nil_ivar.rb")
      File.write(path, <<~RUBY)
        class NilIvar
          def initialize
            @cached = nil
          end
        end
      RUBY

      idx = described_class.new(path)

      expect(idx.tlet_sites).not_to include(a_hash_including("name" => "@cached", "candidate_type" => "NilClass"))
    end
  end

  it "does not treat nil assignments as non-nil safe-navigation proof" do
    Dir.mktmpdir("nil-kill-nil-local") do |dir|
      path = File.join(dir, "nil_local.rb")
      File.write(path, <<~RUBY)
        class NilLocal
          extend T::Sig

          sig { params(value: T.untyped).returns(T.untyped) }
          def maybe(value)
            value = nil unless value.is_a?(String)
            value&.upcase
          end
        end
      RUBY

      idx = described_class.new(path)

      expect(idx.dead_nil_checks).not_to include(a_hash_including("kind" => "safe_nav", "code" => "value&.upcase"))
    end
  end

  it "does not treat branch-dependent locals as dead nil checks" do
    Dir.mktmpdir("nil-kill-branch-local") do |dir|
      path = File.join(dir, "branch_local.rb")
      File.write(path, <<~RUBY)
        class BranchLocal
          extend T::Sig

          sig { params(flag: T::Boolean).returns(T::Boolean) }
          def maybe(flag)
            reason = nil
            reason = :present if flag
            reason.nil?
          end
        end
      RUBY

      idx = described_class.new(path)

      expect(idx.dead_nil_checks).not_to include(a_hash_including("kind" => "nil_check", "code" => "reason.nil?"))
    end
  end

  describe "operator handlers in propagated_core_return_type" do
    def expression_returns(code)
      Dir.mktmpdir("nil-kill-op-handlers") do |dir|
        path = File.join(dir, "sample.rb")
        File.write(path, "class Sample\n  def m\n    #{code}\n  end\nend\n")
        idx = described_class.new(path)
        origins = idx.return_origins.each_with_object({}) { |o, h| h[o["method"]] = o }
        origins["m"]&.fetch("candidate_type", nil)
      end
    end

    it "returns T::Boolean for comparison operators" do
      expect(expression_returns("1 == 2")).to eq("T::Boolean")
      expect(expression_returns("1 != 2")).to eq("T::Boolean")
      expect(expression_returns("1 < 2")).to eq("T::Boolean")
      expect(expression_returns("1 >= 2")).to eq("T::Boolean")
    end

    it "returns T.nilable(Integer) for <=>" do
      expect(expression_returns("1 <=> 2")).to eq("T.nilable(Integer)")
    end

    it "returns Integer for hash" do
      expect(expression_returns('"x".hash')).to eq("Integer")
    end

    it "returns String for inspect" do
      expect(expression_returns("1.inspect")).to eq("String")
    end

    it "preserves String receiver type for +" do
      expect(expression_returns('"a" + "b"')).to eq("String")
    end

    it "preserves Integer receiver type for +" do
      expect(expression_returns("1 + 2")).to eq("Integer")
    end

    it "preserves receiver type through freeze and dup" do
      expect(expression_returns('"x".freeze')).to eq("String")
      expect(expression_returns("1.dup")).to eq("Integer")
    end
  end

  describe "cross-file noreturn propagation" do
    it "registers methods detected as noreturn for use by callers in other files" do
      described_class.reset_global_shape_indexes
      Dir.mktmpdir("nil-kill-noreturn-prop") do |dir|
        path = File.join(dir, "raise_helper.rb")
        File.write(path, <<~RUBY)
          class RaiseHelper
            def bang!
              raise "boom"
            end
          end
        RUBY
        described_class.new(path)
      end
      expect(described_class.noreturn_methods).to include("bang!")
    end

    it "treats T.absurd as a noreturn call" do
      described_class.reset_global_shape_indexes
      Dir.mktmpdir("nil-kill-tabsurd") do |dir|
        path = File.join(dir, "exhaustive.rb")
        File.write(path, <<~RUBY)
          class Exhaustive
            def visit
              T.absurd(:never)
            end
          end
        RUBY
        described_class.new(path)
      end
      expect(described_class.noreturn_methods).to include("visit")
    end

    it "propagates noreturn through registered callee names" do
      described_class.reset_global_shape_indexes
      # Simulate the cross-file world: register a helper, then verify a
      # caller whose only path ends in that helper is noreturn.
      described_class.register_noreturn_method("bang!")
      Dir.mktmpdir("nil-kill-prop-caller") do |dir|
        path = File.join(dir, "caller.rb")
        File.write(path, <<~RUBY)
          class Caller
            def doit
              bang!
            end
          end
        RUBY
        idx = described_class.new(path)
        rec = idx.methods.find { |m| m["method"] == "doit" }
        expect(rec["noreturn_candidate"]).to be(true)
      end
    end
  end

  describe "instance variable typing in expression_type" do
    it "uses T.let-declared ivar types when reading the ivar" do
      Dir.mktmpdir("nil-kill-ivar-tlet-read") do |dir|
        path = File.join(dir, "ivar_tlet.rb")
        File.write(path, <<~RUBY)
          class IvarTlet
            extend T::Sig

            def initialize(name)
              @name = T.let(name, String)
            end

            def get_name
              @name
            end
          end
        RUBY

        idx = described_class.new(path)
        origins = idx.return_origins.each_with_object({}) { |origin, h| h[origin["method"]] = origin }

        expect(origins["get_name"]).to include(
          "confidence" => "strong",
          "candidate_type" => "String"
        )
      end
    end

    it "scopes ivar T.let types per-class so unrelated classes do not bleed" do
      Dir.mktmpdir("nil-kill-ivar-tlet-scope") do |dir|
        path = File.join(dir, "ivar_tlet_scope.rb")
        File.write(path, <<~RUBY)
          class A
            def initialize(n)
              @x = T.let(n, String)
            end

            def read_x
              @x
            end
          end

          class B
            def read_x
              @x
            end
          end
        RUBY

        idx = described_class.new(path)
        origins = idx.return_origins.each_with_object({}) { |origin, h| h[[origin["class"], origin["method"]]] = origin }

        expect(origins[["A", "read_x"]]).to include("candidate_type" => "String")
        expect(origins[["B", "read_x"]]["candidate_type"]).to eq("T.untyped").or eq(nil)
      end
    end

    it "returns no useful type for unrecorded or T.untyped-typed ivars" do
      Dir.mktmpdir("nil-kill-ivar-untyped") do |dir|
        path = File.join(dir, "ivar_untyped.rb")
        File.write(path, <<~RUBY)
          class IvarUntyped
            def initialize(n)
              @y = T.let(n, T.untyped)
            end

            def read_y
              @y
            end

            def read_unset
              @never_set
            end
          end
        RUBY

        idx = described_class.new(path)
        origins = idx.return_origins.each_with_object({}) { |origin, h| h[origin["method"]] = origin }

        expect(origins["read_y"]["candidate_type"]).to eq("T.untyped")
        expect(origins["read_unset"]["candidate_type"]).to eq("T.untyped")
      end
    end
  end
end
