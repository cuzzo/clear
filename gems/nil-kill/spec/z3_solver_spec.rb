# frozen_string_literal: true

require_relative "spec_helper"
require_relative "../lib/nil_kill/z3_solver"

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
end
