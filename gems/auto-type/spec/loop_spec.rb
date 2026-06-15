# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe AutoType::Loop do
  def loop_instance
    described_class.allocate.tap do |loop|
      loop.instance_variable_set(:@skipped, Set.new)
      loop.instance_variable_set(:@permanent_skip, [])
      loop.instance_variable_set(:@z3_solver, nil)
      loop.instance_variable_set(:@hash_record_limit, 1)
      loop.instance_variable_set(:@signature_backflow_limit, 5)
      loop.instance_variable_set(:@return_backflow_limit, 5)
      loop.instance_variable_set(:@narrow_generic_limit, 0)
      loop.instance_variable_set(:@narrow_tlet_limit, 0)
    end
  end

  it "selects review actions only when the corresponding verified loop owns them" do
    loop = loop_instance
    evidence = {
      "actions" => [
        { "kind" => "promote_hash_record_cluster_to_struct", "confidence" => "review",
          "path" => "src/low.rb", "line" => 1, "data" => { "pressure" => { "total" => 1 }, "blockers" => [] } },
        { "kind" => "promote_hash_record_cluster_to_struct", "confidence" => "review",
          "path" => "src/high.rb", "line" => 2, "data" => { "pressure" => { "total" => 9 }, "blockers" => [] } },
        { "kind" => "promote_hash_record_cluster_to_struct", "confidence" => "review",
          "path" => "src/blocked.rb", "line" => 3, "data" => { "pressure" => { "total" => 99 }, "blockers" => ["dynamic key"] } },
        { "kind" => "fix_sig_param", "confidence" => "review",
          "path" => "src/param.rb", "line" => 4, "data" => { "source" => "static_param_backflow", "callsite_count" => 3 } },
        { "kind" => "fix_sig_return", "confidence" => "review",
          "path" => "src/return.rb", "line" => 5, "data" => { "source" => "forwarded_return_chain", "chain" => ["a", "b"] } },
        { "kind" => "narrow_generic_param", "confidence" => "review",
          "path" => "src/generic.rb", "line" => 6, "data" => { "source" => "collection_runtime" } },
        { "kind" => "narrow_tlet", "confidence" => "review",
          "path" => "src/tlet.rb", "line" => 7, "data" => { "type" => "String" } },
        { "kind" => "add_struct_field_sig", "confidence" => "review",
          "path" => "sorbet/rbi/fields.rbi", "line" => 8, "data" => { "class" => "X", "field" => "f", "type" => "String" } },
      ],
    }

    expect(loop.send(:hash_record_review_actions, evidence).map { |action| action["path"] }).to eq(["src/high.rb"])
    expect(loop.send(:signature_backflow_review_actions, evidence).map { |action| action["path"] }).to eq(["src/param.rb"])
    expect(loop.send(:return_backflow_review_actions, evidence).map { |action| action["path"] }).to eq(["src/return.rb"])
    expect(loop.send(:narrow_generic_review_actions, evidence).map { |action| action["path"] }).to eq(["src/generic.rb"])
    expect(loop.send(:narrow_tlet_review_actions, evidence).map { |action| action["path"] }).to eq(["src/tlet.rb"])
    expect(loop.send(:struct_rbi_review_actions, evidence).map { |action| action["path"] }).to eq(["sorbet/rbi/fields.rbi"])
  end

  it "recognizes RSpec load-failure output as verifier failure material" do
    patterns = described_class::RSPEC_LOAD_FAILURE_PATTERNS

    expect(patterns.any? { |pattern| pattern.match?("0 examples, 0 failures, 5 errors occurred outside of examples") }).to be(true)
    expect(patterns.any? { |pattern| pattern.match?("An error occurred while loading ./spec/foo_spec.rb.") }).to be(true)
    expect(patterns.any? { |pattern| pattern.match?("42 examples, 0 failures") }).to be(false)
  end

  it "skips review actions already selected, manually skipped, permanently skipped, or rejected by Z3" do
    loop = loop_instance
    action = { "kind" => "fix_sig_return", "confidence" => "review",
      "path" => "src/return.rb", "line" => 5,
      "data" => { "source" => "forwarded_return_chain", "chain" => ["a"] } }

    expect(loop.send(:return_backflow_review_actions, { "actions" => [action] }, [action])).to be_empty

    loop.instance_variable_set(:@skipped, Set.new([loop.send(:fingerprint, action)]))
    expect(loop.send(:return_backflow_review_actions, { "actions" => [action] })).to be_empty

    loop.instance_variable_set(:@skipped, Set.new)
    loop.instance_variable_set(:@permanent_skip, [{ "kind" => "fix_sig_return", "path" => "src/return.rb" }])
    expect(loop.send(:return_backflow_review_actions, { "actions" => [action] })).to be_empty

    loop.instance_variable_set(:@permanent_skip, [])
    stub_solver = Object.new
    def stub_solver.preflight_rejection(_action) = "candidate union exceeds cutoff"
    loop.instance_variable_set(:@z3_solver, stub_solver)
    expect(loop.send(:return_backflow_review_actions, { "actions" => [action] })).to be_empty
  end

  it "restores snapshots when a retry verifier raises" do
    Dir.mktmpdir("auto-type-loop-restore") do |dir|
      path = File.join(dir, "sample.rb")
      File.write(path, "ORIGINAL\n")
      loop = loop_instance
      loop.define_singleton_method(:verify) { |**| raise ArgumentError, "bad verifier" }
      loop.define_singleton_method(:apply_useless_tcast_feedback) { |_, _| 0 }

      apply_calls = 0
      stub_const("AutoType::Apply", Class.new do
        define_method(:initialize) { |_| }
        define_method(:apply_actions) do |_actions|
          apply_calls += 1
          File.write(path, "MODIFIED\n")
          1
        end
      end)

      result = loop.send(:retry_with_useless_tcast_cleanup,
        { "kind" => "fix_sig_return", "path" => path },
        { path => "ORIGINAL\n" },
        "")

      expect(result).to eq(0)
      expect(apply_calls).to eq(1)
      expect(File.read(path)).to eq("ORIGINAL\n")
    end
  end

  it "builds nilable fallback actions from Sorbet result-type feedback" do
    loop = loop_instance
    output = <<~TEXT
      lib/example.rb:12: Expected `String` but found `T.nilable(String)` for method result type https://srb.help/7005
          12 |  end
                ^^^
        Expected `String` for result type of method `name`:
          lib/example.rb:8:
           8 | sig { returns(String) }
    TEXT
    action = {
      "kind" => "fix_sig_return",
      "confidence" => "high",
      "path" => "lib/example.rb",
      "line" => 8,
      "message" => "existing sig return is T.untyped; observed String",
      "data" => { "type" => "String" },
    }

    fallback = loop.send(:nilable_widening_fallback, action, output)

    expect(fallback).to include(
      "kind" => "fix_sig_return",
      "path" => "lib/example.rb",
      "line" => 8,
      "data" => a_hash_including("type" => "T.nilable(String)")
    )
  end
end
