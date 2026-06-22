# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe "deterministic guard collapse" do
  def write_guard_sample(dir)
    path = File.join(dir, "guard_sample.rb")
    File.write(path, <<~RUBY)
      class GuardSample
        extend T::Sig

        sig { params(name: String, count: Integer).void }
        def check(name, count)
          if name.is_a?(String)
            name
          end

          unless count.is_a?(String)
            count
          end

          if 1 == 1
            count
          end
        end
      end
    RUBY
    path
  end

  it "indexes statically deterministic branch predicates" do
    skip "deterministic guard analysis pending in Rust FactMine (Phase 3)"
    Dir.mktmpdir("nil-kill-deterministic-guard") do |dir|
      path = write_guard_sample(dir)

      idx = NilKill::StaticAnalysis.new(path)
      by_code = idx.deterministic_guards.each_with_object({}) { |guard, h| h[guard["code"]] = guard }

      expect(by_code["name.is_a?(String)"]).to include(
        "proof_tier" => "static_proven",
        "predicate_kind" => "class_guard",
        "truth_value" => true,
        "taken_branch" => "body",
        "origin_kind" => "param",
        "origin_name" => "name"
      )
      expect(by_code["count.is_a?(String)"]).to include(
        "truth_value" => false,
        "branch_kind" => "unless",
        "taken_branch" => "body"
      )
      expect(by_code["1 == 1"]).to include(
        "predicate_kind" => "literal_comparison",
        "truth_value" => true
      )
    end
  end

  it "does not treat arbitrary accessor-call receivers as deterministic nil checks" do
    Dir.mktmpdir("nil-kill-deterministic-accessor") do |dir|
      path = File.join(dir, "accessor.rb")
      File.write(path, <<~RUBY)
        class Node
          def value
          end
        end

        class UsesNode
          def check(node)
            if node.value.nil?
              :empty
            end
          end
        end
      RUBY

      idx = NilKill::StaticAnalysis.new(path)

      expect(idx.deterministic_guards.map { |guard| guard["code"] }).not_to include("node.value.nil?")
    end
  end

  it "keeps class hierarchy proofs conservative" do
    skip "class hierarchy analysis pending in Rust FactMine (Phase 3)"
    Dir.mktmpdir("nil-kill-deterministic-hierarchy") do |dir|
      path = File.join(dir, "hierarchy.rb")
      File.write(path, <<~RUBY)
        class GuardHierarchy
          extend T::Sig

          sig { params(flag: T::Boolean, count: Integer).void }
          def check(flag, count)
            if flag.is_a?(TrueClass)
              flag
            end

            if count.is_a?(Numeric)
              count
            end

            if count.instance_of?(Integer)
              count
            end
          end
        end
      RUBY

      idx = NilKill::StaticAnalysis.new(path)
      by_code = idx.deterministic_guards.each_with_object({}) { |guard, h| h[guard["code"]] = guard }

      expect(by_code["count.is_a?(Numeric)"]).to include(
        "predicate_kind" => "class_guard",
        "truth_value" => true
      )
      expect(by_code).not_to include("flag.is_a?(TrueClass)")
      expect(by_code).not_to include("count.instance_of?(Integer)")
    end
  end

  it "emits review actions during infer without requiring sorbet" do
    skip "infer pipeline analysis pending in Rust FactMine (Phase 3)"
    Dir.mktmpdir("nil-kill-deterministic-infer") do |dir|
      write_guard_sample(dir)

      isolated_env("NIL_KILL_TARGETS" => dir, "NIL_KILL_EXCLUDE_TARGETS" => "") do
        old_stdout = $stdout
        $stdout = StringIO.new
        NilKill::Infer.new(["--no-sorbet"]).run
      ensure
        $stdout = old_stdout
      end

      evidence = NilKill::Store.read
      actions = evidence["actions"].select { |action| action["kind"] == "replace_deterministic_guard" }

      expect(evidence.dig("facts", "deterministic_guards").size).to be >= 3
      expect(actions.map { |action| action.dig("data", "code") }).to include(
        "name.is_a?(String)",
        "count.is_a?(String)",
        "1 == 1"
      )
      expect(actions).to all(include("confidence" => "review"))
    end
  end

  it "renders static and contract-proven guard collapse rows" do
    evidence = {
      "methods" => [],
      "facts" => {
        "deterministic_guards" => [
          { "path" => "src/guard.rb", "line" => 10, "class" => "Guard", "method" => "check",
            "code" => "name.is_a?(String)", "branch_kind" => "if", "truth_value" => true,
            "taken_branch" => "body", "proof_tier" => "static_proven",
            "predicate_kind" => "class_guard", "reason" => "name has static type String" },
        ],
        "type_normalizers" => [
          { "path" => "src/type_guard.rb", "line" => 20, "class" => "Guard", "method" => "normalize",
            "code" => "ti.is_a?(Type)", "origin_kind" => "attr", "origin_name" => "type_info" },
        ],
        "existing_sigs" => [
          { "path" => "src/type_guard.rb", "line" => 18, "class" => "Guard", "method" => "normalize",
            "params" => [] },
        ],
        "unsigned_methods" => [],
        "ivar_runtime" => [
          { "class" => "Guard", "name" => "@type_info", "classes" => ["Type"] },
        ],
      },
    }
    lines = []

    NilKill::Report.new.send(:append_deterministic_guard_collapse, lines, evidence)
    text = lines.join("\n")

    expect(text).to include("### Deterministic Guard Collapse")
    expect(text).to include("contract_proven: 1 guard(s) collapse")
    expect(text).to include("`.type_info`")
    expect(text).to include("static_proven: src/guard.rb:10 Guard#check `name.is_a?(String)` -> always true")
  end
end
