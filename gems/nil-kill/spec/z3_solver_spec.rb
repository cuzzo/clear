# frozen_string_literal: true

require_relative "spec_helper"
require_relative "../lib/nil_kill/inference/z3_solver"

RSpec.describe NilKill::Z3Solver do
  def solver_for(source)
    dir = Dir.mktmpdir("nil-kill-z3", File.join(NilKill::ROOT, "tmp"))
    path = File.join(dir, "sample.rb")
    File.write(path, source)
    rel = Pathname.new(path).relative_path_from(Pathname.new(NilKill::ROOT)).to_s
    evidence = { "facts" => { "existing_sigs" => [] }, "methods" => [] }
    [described_class.new(evidence, [path]), rel]
  end

  it "rejects candidates with bare generic collection constants" do
    solver, rel = solver_for(<<~RUBY)
      class Example
        sig { returns(T::Hash[T.untyped, T.untyped]) }
        def table
          {}
        end
      end
    RUBY

    action = {
      "kind" => "narrow_generic_return",
      "path" => rel,
      "line" => 3,
      "data" => { "type" => "T::Hash[String, Array]" },
    }

    expect(solver.preflight_rejection(action)).to eq("candidate uses bare generic collection type")
  end

  it "rejects candidates with broad unions before verification" do
    solver, rel = solver_for(<<~RUBY)
      class Example
        sig { returns(T.untyped) }
        def value
          something
        end
      end
    RUBY

    action = {
      "kind" => "fix_sig_return",
      "path" => rel,
      "line" => 3,
      "data" => { "type" => "T.any(Float, Hash, Integer, String)" },
    }

    expect(solver.preflight_rejection(action)).to eq("candidate union exceeds cutoff")
  end

  it "rejects candidates with broad nested unions before verification" do
    solver, rel = solver_for(<<~RUBY)
      class Example
        sig { returns(T::Hash[T.untyped, T.untyped]) }
        def value
          {}
        end
      end
    RUBY

    action = {
      "kind" => "narrow_generic_return",
      "path" => rel,
      "line" => 3,
      "data" => { "type" => "T::Hash[Symbol, T.any(Float, Hash, Integer, String)]" },
    }

    expect(solver.preflight_rejection(action)).to eq("candidate union exceeds cutoff")
  end

  it "rejects array returns inferred from tuple-like array literals" do
    solver, rel = solver_for(<<~RUBY)
      class Example
        sig { returns(T.untyped) }
        def tuple
          return [base, ownership, sync]
        end
      end
    RUBY

    action = {
      "kind" => "fix_sig_return",
      "path" => rel,
      "line" => 3,
      "data" => { "type" => "T::Array[T.nilable(String)]" },
    }

    expect(solver.preflight_rejection(action)).to eq("array candidate conflicts with tuple-like return shape")
  end

  it "rejects symbol-key hash candidates when the method reads distinct fixed keys" do
    solver, rel = solver_for(<<~RUBY)
      class Example
        sig { params(snapshot: T::Hash[Symbol, T.untyped]).void }
        def restore(snapshot)
          snapshot[:node_states].each {}
          target_count = snapshot[:edge_count]
        end
      end
    RUBY

    action = {
      "kind" => "narrow_generic_param",
      "path" => rel,
      "line" => 3,
      "data" => {
        "name" => "snapshot",
        "type" => "T::Hash[Symbol, T.any(Integer, T::Hash[String, String])]",
      },
    }

    expect(solver.preflight_rejection(action)).to eq("hash candidate collapses per-key symbol shape")
  end

  it "rejects container candidates that conflict with protocol calls on the receiver" do
    solver, rel = solver_for(<<~RUBY)
      class Example
        sig { params(node: T.untyped).void }
        def walk(node)
          node.class.members.each {}
        end
      end
    RUBY

    action = {
      "kind" => "fix_sig_param",
      "path" => rel,
      "line" => 3,
      "data" => {
        "name" => "node",
        "type" => "T::Hash[Symbol, String]",
      },
    }

    expect(solver.preflight_rejection(action)).to eq("container candidate conflicts with receiver protocol use")
  end

  describe "#consistent?" do
    it "returns true if the proposed return type matches the param type constraint, and false otherwise" do
      Dir.mktmpdir("nil-kill-z3", File.join(NilKill::ROOT, "tmp")) do |dir|
        path = File.join(dir, "sample.rb")
        File.write(path, <<~RUBY)
          class Example
            def run_caller
              callee(inferred_method)
            end
          end
        RUBY
        rel = Pathname.new(path).relative_path_from(Pathname.new(NilKill::ROOT)).to_s

        evidence = {
          "facts" => {
            "existing_sigs" => [
              {
                "path" => rel,
                "line" => 10,
                "method" => "callee",
                "sig" => "sig { params(x: Numeric).void }"
              },
              {
                "path" => rel,
                "line" => 2,
                "method" => "inferred_method",
                "sig" => "sig { returns(T.untyped) }"
              }
            ]
          }
        }

        solver = described_class.new(evidence, [path])

        action_consistent = {
          "kind" => "fix_sig_return",
          "path" => rel,
          "line" => 2,
          "data" => { "type" => "Float" }
        }
        expect(solver.consistent?([action_consistent])).to eq(true)

        action_inconsistent = {
          "kind" => "fix_sig_return",
          "path" => rel,
          "line" => 2,
          "data" => { "type" => "String" }
        }
        expect(solver.consistent?([action_inconsistent])).to eq(false)
      end
    end

    it "resolves transitive subclass subtyping and nilability bounds correctly" do
      Dir.mktmpdir("nil-kill-z3", File.join(NilKill::ROOT, "tmp")) do |dir|
        path = File.join(dir, "hierarchy.rb")
        File.write(path, <<~RUBY)
          class Grandparent; end
          class Parent < Grandparent; end
          class Child < Parent; end
          class Unrelated; end
        RUBY
        rel = Pathname.new(path).relative_path_from(Pathname.new(NilKill::ROOT)).to_s

        evidence = {
          "facts" => {
            "existing_sigs" => [
              {
                "path" => rel,
                "line" => 10,
                "method" => "callee",
                "sig" => "sig { params(x: Grandparent).void }"
              },
              {
                "path" => rel,
                "line" => 20,
                "method" => "nilable_callee",
                "sig" => "sig { params(x: T.nilable(Grandparent)).void }"
              },
              {
                "path" => rel,
                "line" => 2,
                "method" => "inferred_method",
                "sig" => "sig { returns(T.untyped) }"
              }
            ]
          }
        }

        solver = described_class.new(evidence, [path])
        solver.instance_eval do
          @type_ids = {
            "Child" => 10,
            "Parent" => 11,
            "Grandparent" => 12,
            "Unrelated" => 13,
            "NilClass" => 14,
            "T.nilable(Grandparent)" => 15,
            "T.nilable(Child)" => 16,
            "String" => 17
          }
        end

        # Child is a subtype of Grandparent -> true
        expect(solver.send(:sat?, [[10, 12]])).to eq(true)

        # Child is a subtype of T.nilable(Grandparent) -> true
        expect(solver.send(:sat?, [[10, 15]])).to eq(true)

        # T.nilable(Child) is a subtype of T.nilable(Grandparent) -> true
        expect(solver.send(:sat?, [[16, 15]])).to eq(true)

        # NilClass is a subtype of T.nilable(Grandparent) -> true
        expect(solver.send(:sat?, [[14, 15]])).to eq(true)

        # Unrelated is NOT a subtype of Grandparent -> false
        expect(solver.send(:sat?, [[13, 12]])).to eq(false)

        # String is NOT a subtype of T.nilable(Grandparent) -> false
        expect(solver.send(:sat?, [[17, 15]])).to eq(false)
      end
    end
  end

  describe "#infer_unobserved_params" do
    it "infers param types for unobserved methods from static call sites" do
      Dir.mktmpdir("nil-kill-z3", File.join(NilKill::ROOT, "tmp")) do |dir|
        path = File.join(dir, "sample.rb")
        File.write(path, <<~RUBY)
          class Example
            def run_caller
              unobserved_method("hello", 42)
            end
          end
        RUBY
        rel = Pathname.new(path).relative_path_from(Pathname.new(NilKill::ROOT)).to_s

        evidence = {
          "facts" => {
            "existing_sigs" => []
          },
          "methods" => [
            {
              "calls" => 0,
              "has_sig" => false,
              "source" => {
                "path" => rel,
                "line" => 10,
                "method" => "unobserved_method",
                "scope" => ["Example"],
                "params" => [
                  { "name" => "a" },
                  { "name" => "b" }
                ]
              }
            }
          ]
        }

        solver = described_class.new(evidence, [path])
        actions = solver.infer_unobserved_params(evidence)

        expect(actions).to include(a_hash_including(
          "kind" => "add_sig",
          "path" => rel,
          "line" => 10,
          "data" => a_hash_including(
            "sig" => "sig { params(a: String, b: Integer).returns(T.untyped) }"
          )
        ))
      end
    end
  end

  describe "#provably_dead_safe_nav?" do
    it "returns true if receiver is provably dead/non-nil, and false if receiver is assigned nil" do
      Dir.mktmpdir("nil-kill-z3", File.join(NilKill::ROOT, "tmp")) do |dir|
        path = File.join(dir, "sample.rb")
        File.write(path, <<~RUBY)
          def my_method(x)
            val = nil
            val.nil?
          end
        RUBY
        rel = Pathname.new(path).relative_path_from(Pathname.new(NilKill::ROOT)).to_s

        evidence = { "facts" => { "existing_sigs" => [] } }
        solver = described_class.new(evidence, [path])

        action_nil = {
          "kind" => "replace_dead_nil_check",
          "path" => rel,
          "line" => 3,
          "data" => { "code" => "val.nil?" }
        }
        expect(solver.provably_dead_safe_nav?(action_nil)).to eq(false)
      end
    end
  end
end
