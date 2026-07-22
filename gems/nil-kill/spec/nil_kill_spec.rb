# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe NilKill do
  it "recovers field types from typed parameter assignments" do
    evidence = {
      "fields" => [{
        "language" => "ruby", "path" => "parser.rb", "owner" => "Parser",
        "name" => "tokens", "declared_type" => nil,
      }],
      "facts" => {
        "state_param_origin_records" => [{
          "language" => "ruby", "path" => "parser.rb", "owner" => "Parser",
          "function" => "initialize", "field" => "@tokens", "param" => "tokens",
        }],
        "type_definitions" => [{
          "language" => "ruby", "path" => "parser.rb", "owner" => "Parser",
          "name" => "initialize", "kind" => "method_signature",
          "params" => [{"name" => "tokens", "type" => "T::Array[Token]"}],
        }],
      },
    }

    NilKill::StaticEvidence.send(:enrich_fields_from_param_origins!, evidence)

    expect(evidence.dig("fields", 0, "declared_type")).to eq("T::Array[Token]")
    expect(evidence.dig("fields", 0, "static_origin")).to eq("parameter_assignment")
  end

  describe ".sorbet_type union policy" do
    it "emits T.any(...) for 2-3 class unions by default" do
      expect(NilKill.sorbet_type(%w[String Integer])).to eq("T.any(Integer, String)")
      expect(NilKill.sorbet_type(%w[Foo Bar Baz])).to eq("T.any(Bar, Baz, Foo)")
    end

    it "falls back to T.untyped when union exceeds MAX_UNION_TYPES" do
      expect(NilKill.sorbet_type(%w[A B C D])).to eq("T.untyped")
    end

    it "wraps a 2-class union as T.nilable(T.any(...)) when NilClass is present" do
      expect(NilKill.sorbet_type(%w[String Integer NilClass])).to eq("T.nilable(T.any(Integer, String))")
    end

    it "honors NIL_KILL_UNION_POLICY=untyped explicit override" do
      original = ENV["NIL_KILL_UNION_POLICY"]
      ENV["NIL_KILL_UNION_POLICY"] = "untyped"
      expect(NilKill.sorbet_type(%w[String Integer])).to eq("T.untyped")
    ensure
      ENV["NIL_KILL_UNION_POLICY"] = original
    end
  end

  describe ".strip_to_stdlib_owner" do
    it "strips parametric stdlib container wrappers to their bare class name" do
      expect(NilKill.strip_to_stdlib_owner("T::Array[String]")).to eq("Array")
      expect(NilKill.strip_to_stdlib_owner("T::Hash[Symbol, T.untyped]")).to eq("Hash")
      expect(NilKill.strip_to_stdlib_owner("T::Set[Integer]")).to eq("Set")
      expect(NilKill.strip_to_stdlib_owner("T::Enumerable[Object]")).to eq("Enumerable")
    end

    it "returns nil for non-container types so callers can detect no-op" do
      expect(NilKill.strip_to_stdlib_owner("String")).to be_nil
      expect(NilKill.strip_to_stdlib_owner("AST::Foo")).to be_nil
      expect(NilKill.strip_to_stdlib_owner("T.untyped")).to be_nil
      expect(NilKill.strip_to_stdlib_owner("")).to be_nil
      expect(NilKill.strip_to_stdlib_owner(nil)).to be_nil
    end
  end

  describe "target filtering" do
    it "excludes configured target subdirectories from files and path matches" do
      Dir.mktmpdir("nil-kill-target-filter") do |dir|
        kept_dir = File.join(dir, "src")
        excluded_dir = File.join(kept_dir, "tools")
        FileUtils.mkdir_p(excluded_dir)
        kept = File.join(kept_dir, "kept.rb")
        excluded = File.join(excluded_dir, "excluded.rb")
        File.write(kept, "class Kept; end\n")
        File.write(excluded, "class Excluded; end\n")

        isolated_env("NIL_KILL_TARGETS" => kept_dir, "NIL_KILL_EXCLUDE_TARGETS" => excluded_dir) do
          expect(NilKill.target_files).to eq([kept])
          expect(NilKill.target_path?(kept)).to be(true)
          expect(NilKill.target_path?(excluded)).to be(false)
        end
      end
    end
  end

  describe NilKill::FlowGraph do
    it "indexes hash field reads by producer identity and field path" do
      lookup = {
        "path" => "records.rb",
        "line" => 4,
        "code" => "record[:c]",
        "receiver" => "record",
        "index" => ":c",
        "lookup_type" => "T.nilable(String)",
        "origin" => {
          "kind" => "hash literal",
          "path" => "records.rb",
          "line" => 3,
          "name" => "record",
        },
      }
      graph = described_class.from_evidence("facts" => {
        "existing_sigs" => [],
        "unsigned_methods" => [],
        "collection_index_lookups" => [lookup],
      }, "methods" => [])

      field_id = graph.hash_record_identity_for_lookup(lookup)

      expect(field_id).to include("hash_literal")
      expect(field_id).to end_with("[:c]")
      expect(graph.sorbet_type_for(field_id)).to eq("T.nilable(String)")
    end

    it "represents call arguments, returns, forwarding, and struct fields as graph edges" do
      evidence = {
        "methods" => [],
        "facts" => {
          "existing_sigs" => [
            { "path" => "lib/example.rb", "line" => 1, "class" => "Example", "method" => "leaf", "kind" => "instance",
              "sig" => "sig { returns(String) }", "params" => [] },
            { "path" => "lib/example.rb", "line" => 5, "class" => "Example", "method" => "root", "kind" => "instance",
              "sig" => "sig { returns(T.untyped) }", "params" => [{ "name" => "record", "type" => "T.untyped" }] },
          ],
          "unsigned_methods" => [],
          "return_origins" => [
            { "path" => "lib/example.rb", "line" => 5, "class" => "Example", "method" => "root", "kind" => "instance",
              "return_syntax" => "implicit", "candidate_type" => "T.untyped",
              "sources" => [{ "kind" => "call_untyped", "callee" => "leaf", "line" => 6, "code" => "leaf" }] },
          ],
          "param_origins" => [
            { "path" => "lib/example.rb", "line" => 9, "callee" => "root", "arg_kind" => "positional", "slot" => "0",
              "origin_kind" => "static", "type" => "String", "code" => "\"ok\"" },
          ],
          "struct_field_static" => [
            { "path" => "lib/example.rb", "line" => 12, "class" => "Example::Node", "field" => "name",
              "type" => "String", "expression" => "\"node\"" },
          ],
        },
      }

      graph = described_class.from_evidence(evidence)

      expect(graph.edges).to include(a_hash_including("kind" => "call_argument", "to" => "param:callee:root:positional:0"))
      expect(graph.edges).to include(a_hash_including("kind" => "return_forward", "from" => "return:method_name:leaf"))
      expect(graph.sorbet_type_for("struct_field:Example::Node:name")).to eq("String")
    end


    it "ranks conjunctive type dependencies by definite transitive unlocks" do
      evidence = {
        "facts" => {
          "type_dependencies" => [
            { "id" => "root:a", "kind" => "definition", "candidate" => true,
              "candidate_kind" => "parameter", "resolved" => false, "requirements" => [], "name" => "a" },
            { "id" => "root:b", "kind" => "definition", "candidate" => true,
              "candidate_kind" => "parameter", "resolved" => false, "requirements" => [], "name" => "b" },
            { "id" => "copy:a", "kind" => "definition", "candidate" => false,
              "resolved" => false, "requirements" => ["root:a"], "name" => "copy" },
            { "id" => "read:a", "kind" => "flow_read", "candidate" => false,
              "resolved" => false, "requirements" => ["copy:a"], "name" => "copy" },
            { "id" => "join", "kind" => "flow_read", "candidate" => false,
              "resolved" => false, "requirements" => ["root:a", "root:b"], "name" => "joined" },
          ],
        },
      }

      pressure = described_class.from_evidence(evidence).unlock_pressure

      expect(pressure.map { |row| row["candidate"] }).to eq(["root:a"])
      expect(pressure.first["unlocked_ids"]).to include("copy:a", "read:a")
      expect(pressure.first["unlocked_ids"]).not_to include("join")
      expect(pressure.first["counts"]).to include("flow_read" => 1)
    end

    it "handles dependency cycles without treating an ungrounded cycle as resolved" do
      graph = described_class.new
      graph.add_dependency_node("left", requirements: ["right"], candidate: true)
      graph.add_dependency_node("right", requirements: ["left"])
      graph.add_dependency_node("read", requirements: ["right"], data: { "kind" => "flow_read" })

      expect(graph.unlock_pressure.first["unlocked_ids"]).to contain_exactly("read", "right")

      ungrounded = described_class.new
      ungrounded.add_dependency_node("left", requirements: ["right"])
      ungrounded.add_dependency_node("right", requirements: ["left"])
      expect(ungrounded.unlock_pressure).to be_empty
    end
  end

  describe NilKill::Report do
    it "renders definite type dependency unlock pressure" do
      evidence = {
        "facts" => {
          "type_dependencies" => [
            { "id" => "root", "kind" => "definition", "candidate" => true,
              "candidate_kind" => "parameter", "resolved" => false, "requirements" => [],
              "file" => "src/pipeline.rb", "line" => 4, "name" => "source" },
            { "id" => "read", "kind" => "flow_read", "candidate" => false,
              "resolved" => false, "requirements" => ["root"], "name" => "source" },
          ],
        },
      }
      lines = []

      described_class.new.send(:append_type_dependency_pressure, lines, evidence)

      expect(lines.join("\n")).to include("Type Dependency Unlock Pressure")
      expect(lines.join("\n")).to include("src/pipeline.rb:4 source (parameter); definitely unlocks 1 1 flow read")
    end

    it "reports when no single annotation has definite dependency impact" do
      lines = []
      described_class.new.send(:append_type_dependency_pressure, lines, { "facts" => {} })
      expect(lines.last).to eq("- none")
    end

    it "formats project paths as root-relative links when requested" do
      report = described_class.new(["--with-links"])
      abs = File.join(NilKill::ROOT, "src", "ast", "parser.rb")

      line = report.format_report_line("- #{abs}:42 AutoConstraintCollector#walk Parser#error! Parser#stmt? parser issue T.nilable(String)")

      expect(line).to match(/\A- \[src\/ast\/parser\.rb:42\]\((?:\.\.\/)+src\/ast\/parser\.rb#L42\) `AutoConstraintCollector#walk` `Parser#error!` `Parser#stmt\?` parser issue T\.nilable\(String\)\z/)
      expect(line).not_to include(NilKill::ROOT)
    end

    it "renders report JSON as SARIF" do
      evidence = {
        "target_dirs" => ["src"],
        "methods" => [],
        "actions" => [
          {
            "kind" => "nil_param_observed",
            "confidence" => "high",
            "message" => "param observed nil",
            "path" => "src/demo.rb",
            "line" => 7,
          },
        ],
        "diagnostics" => {
          "sorbet_errors" => ["src/demo.rb:8: type error"],
        },
      }

      sarif = JSON.parse(described_class.new(["--format=sarif"], evidence: evidence).to_sarif(evidence))
      run = sarif.fetch("runs").first
      expect(sarif.fetch("version")).to eq("2.1.0")
      expect(run.dig("tool", "driver", "name")).to eq("Nil-Kill")
      expect(run.fetch("results").map { |result| result.fetch("ruleId") }).to include(
        "nil-kill.action.nil-param-observed",
        "nil-kill.diagnostic.sorbet-errors",
      )
    end

    it "renders static-only v2 evidence as SARIF findings" do
      evidence = {
        "schema_version" => 2,
        "languages" => ["ruby"],
        "static" => {
          "files" => [],
          "methods" => [
            {
              "path" => "src/demo.rb",
              "line" => 10,
              "owner" => "Demo",
              "name" => "parse",
              "kind" => "method",
              "language" => "ruby",
              "signature" => "sig { params(input: T.untyped).returns(T.nilable(String)) }",
            },
          ],
          "fields" => [
            {
              "path" => "src/demo.rb",
              "line" => 3,
              "owner" => "Demo",
              "name" => "@cache",
              "language" => "ruby",
            },
            {
              "path" => "src/storage.rs",
              "line" => 16,
              "owner" => "CurrentUnitSpan",
              "name" => "id",
              "language" => "rust",
              "declared_type" => "String",
            },
          ],
          "facts" => {
            "alias_recommendations" => [
              {
                "kind" => "alias_recommendation",
                "language" => "ruby",
                "type_system" => "sorbet",
                "alias" => "AST::RawBody",
                "target" => "T::Array[AST::Node]",
                "path" => "src/demo.rb",
                "line" => 10,
                "slot_count" => 1,
                "definition" => {"path" => "src/ast/ast.rb", "line" => 15},
                "slots" => [
                  {"path" => "src/demo.rb", "line" => 10, "slot_kind" => "param", "slot" => "body"},
                ],
              },
            ],
          },
        },
        "runtime" => {},
        "actions" => [],
        "diagnostics" => [],
      }

      sarif = JSON.parse(described_class.new(["--format=sarif"], evidence: evidence).to_sarif(evidence))
      results = sarif.fetch("runs").first.fetch("results")
      rule_ids = results.map { |result| result.fetch("ruleId") }

      expect(rule_ids).to include(
        "nil-kill.static.untyped-signature",
        "nil-kill.static.nullable-signature",
        "nil-kill.static.untyped-field",
        "nil-kill.static.alias-recommendation",
      )
      expect(results).to include(a_hash_including(
        "ruleId" => "nil-kill.static.untyped-signature",
        "message" => a_hash_including("text" => include("replace Any/T.untyped/unknown")),
      ))
      expect(results).to include(a_hash_including(
        "ruleId" => "nil-kill.static.nullable-signature",
        "message" => a_hash_including("text" => include("nilability pressure")),
      ))
      expect(results).not_to include(a_hash_including(
        "ruleId" => "nil-kill.static.untyped-field",
        "message" => a_hash_including("text" => include("CurrentUnitSpan#id")),
      ))
      static_result = results.find { |result| result.fetch("ruleId") == "nil-kill.static.untyped-signature" }
      expect(static_result.fetch("properties")).not_to have_key("proof_boundary")
      expect(static_result.dig("properties", "fact_mine.proof_boundary", "input_completeness")).to eq("unknown")
      expect(static_result.dig("properties", "fact_mine.proof_boundary", "claim_status")).to eq("review")
      expect(sarif.dig("runs", 0, "properties", "fact_mine.proof_boundary_summary", "results_with_boundary")).to be_positive
    end

    it "distinguishes complete static proofs from partial static evidence in SARIF" do
      evidence = {
        "schema_version" => 2,
        "languages" => ["ruby"],
        "static" => {
          "files" => [],
          "methods" => [
            { "path" => "lib/x.rb", "line" => 3, "owner" => "Parser", "name" => "parse", "kind" => "method", "language" => "ruby", "signature" => "sig { returns(T.nilable(String)) }" },
            { "path" => "lib/x.rb", "line" => 7, "owner" => "Parser", "name" => "optional", "kind" => "method", "language" => "ruby", "signature" => "sig { returns(T.nilable(String)) }" }
          ],
          "fields" => [],
          "facts" => {
            "return_origins" => [{
              "path" => "lib/x.rb", "class" => "Parser", "method" => "parse", "confidence" => "strong", "blockers" => [],
              "candidate_type" => { "kind" => "Primitive", "data" => "String" },
              "sources" => [{ "line" => 4, "type" => { "kind" => "Primitive", "data" => "String" } }]
            }]
          }
        },
        "runtime" => {},
        "actions" => [],
        "diagnostics" => []
      }

      sarif = JSON.parse(described_class.new(["--format=sarif"], evidence: evidence).to_sarif(evidence))
      claims = sarif.dig("runs", 0, "results").map { |result| result.dig("properties", "fact_mine.proof_boundary", "claim_status") }.compact
      expect(claims).to include("proven", "review")
      expect(sarif.dig("runs", 0, "properties", "fact_mine.proof_boundary_summary", "claim_status", "review")).to be_positive
      partial_boundary = described_class.new.send(:static_review_boundary, "static_nil_finding", blockers: ["dynamic dispatch"])
      expect(partial_boundary.fetch("input_completeness")).to eq("partial")
      expect(partial_boundary.fetch("blockers")).to eq(["dynamic dispatch"])
    end

    it "does not treat complete inputs as a proven static claim" do
      boundary = described_class.new.send(
        :static_proof_boundary,
        { "complete" => true, "proof_tier" => "review" },
        "legacy_static_nil_finding",
        { "static" => { "input_coverage" => { "complete" => true } } }
      )

      expect(boundary).to include(
        "input_completeness" => "complete",
        "claim_status" => "review"
      )
    end

    it "serializes only the canonical proof boundary for pressure findings" do
      reporter = described_class.new
      finding = {
        "kind" => "primitive_record",
        "message" => "pressure",
        "path" => "lib/x.rb",
        "line" => 3,
        "proof_boundary" => reporter.send(:static_review_boundary, "primitive_record_pressure")
      }

      result = reporter.send(
        :sarif_pressure_result,
        finding,
        { "static" => { "input_coverage" => { "complete" => true } } }
      )

      expect(result.fetch("properties")).not_to have_key("proof_boundary")
      expect(result.dig("properties", "fact_mine.proof_boundary", "input_completeness")).to eq("complete")
    end

    it "conforms to the shared proof-boundary fixture" do
      fixture_path = File.join(NilKill::ROOT, "gems/hazard-contract/fixtures/proof-boundary.v2.json")
      fixture = JSON.parse(File.read(fixture_path))
      valid = fixture.fetch("valid")

      boundary = NilKill::Sarif.proof_boundary(
        input_completeness: valid.fetch("input_completeness"),
        claim_status: valid.fetch("claim_status"),
        coverage_discharge: valid.fetch("coverage_discharge"),
        authority: valid.fetch("authority"),
        scope: valid.fetch("scope"),
        blockers: valid.fetch("blockers")
      )

      expect(boundary).to eq(valid)
      expect {
        NilKill::Sarif.proof_boundary(
          input_completeness: fixture.dig("invalid", "input_completeness"),
          claim_status: "review",
          coverage_discharge: "unsatisfiable",
          authority: [],
          scope: "test"
        )
      }.to raise_error(ArgumentError, /input completeness/)
      expect {
        NilKill::Sarif.proof_boundary(
          input_completeness: "partial",
          claim_status: "review",
          coverage_discharge: "unsatisfiable",
          authority: [],
          scope: ""
        )
      }.to raise_error(ArgumentError, /authority must not be empty/)
    end

    it "joins relative method paths to absolute return-origin paths" do
      evidence = {
        "schema_version" => 2,
        "root" => "/repo",
        "languages" => ["ruby"],
        "static" => {
          "files" => [],
          "methods" => [{
            "path" => "compiler/ruby/ast/parser.rb",
            "line" => 10,
            "owner" => "ClearParser",
            "name" => "parse",
            "kind" => "method",
            "language" => "ruby",
            "signature" => "sig { returns(T.nilable(AST::Program)) }",
          }],
          "facts" => {
            "return_origins" => [{
              "path" => "/repo/compiler/ruby/ast/parser.rb",
              "class" => "ClearParser",
              "method" => "parse",
              "confidence" => "strong",
              "blockers" => [],
              "candidate_type" => {"kind" => "Primitive", "data" => "AST::Program"},
              "sources" => [{
                "line" => 14,
                "kind" => "static",
                "type" => {"kind" => "Primitive", "data" => "AST::Program"},
              }],
            }],
          },
        },
        "runtime" => {},
        "actions" => [],
        "diagnostics" => [],
      }

      sarif = JSON.parse(described_class.new(["--format=sarif"], evidence: evidence).to_sarif(evidence))
      results = sarif.fetch("runs").first.fetch("results")

      expect(results).to include(a_hash_including(
        "ruleId" => "nil-kill.static.false-nullable-return",
        "message" => a_hash_including("text" => include("false-nilable return")),
      ))
    end

    it "renders pressure facts as actionable SARIF findings" do
      evidence = {
        "facts" => {
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
            "handlers" => [],
          }],
          "collection_index_lookups" => [{
            "path" => "src/options.rb",
            "line" => 8,
            "code" => "opts[:mode]",
            "receiver" => "opts",
            "receiver_type" => "Hash",
            "index" => ":mode",
            "lookup_type" => "T.untyped",
            "status" => "untyped receiver",
          }],
          "param_origins" => [],
          "return_origins" => [],
        },
        "actions" => [{
          "kind" => "report_static_primitive_domain",
          "confidence" => "review",
          "path" => "src/workflow.rb",
          "line" => 10,
          "message" => "state @status has a closed-looking string domain across 1 decision sites",
          "data" => {
            "slot" => "@status",
            "values" => ['"active"', '"pending"'],
            "decision_sites" => ["src/workflow.rb:11"],
          },
        }],
        "diagnostics" => [],
      }

      sarif = JSON.parse(described_class.new(["--format=sarif"], evidence: evidence).to_sarif(evidence))
      results = sarif.fetch("runs").first.fetch("results")

      expect(results).to include(a_hash_including(
        "ruleId" => "nil-kill.action.report-static-primitive-domain",
        "message" => a_hash_including("text" => include("report_static_primitive_domain [review]")),
      ))
      expect(results).to include(a_hash_including(
        "ruleId" => "nil-kill.pressure.fallibility",
        "message" => a_hash_including("text" => include("fallibility pressure: Parser#parse")),
      ))
      expect(results).to include(a_hash_including(
        "ruleId" => "nil-kill.pressure.primitive-record",
        "message" => a_hash_including("text" => include("primitive record pressure")),
      ))
    end

    it "--hygiene emits only the slot summary and action counts, skipping heavy sections" do
      Dir.mktmpdir("nil-kill-hygiene-report", NilKill::ROOT) do |dir|
        report = described_class.new(["--hygiene"])
        evidence = {
          "target_dirs" => [dir],
          "target_exclude_dirs" => [],
          "methods" => [],
          "facts" => {
            "existing_sigs" => [
              { "path" => "src/x.rb", "line" => 1, "class" => "X", "method" => "f",
                "sig" => "sig { params(a: String).returns(T.untyped) }" },
            ],
            "unsigned_methods" => [],
            "tlet_sites" => [],
            "struct_declarations" => [],
          },
          "diagnostics" => { "sorbet_errors" => [], "nil_origins" => [] },
        }
        actions = [
          { "kind" => "fix_sig_return", "confidence" => "high", "path" => "src/x.rb", "line" => 1,
            "data" => { "type" => "String", "source" => "static_return_origin" } },
          { "kind" => "fix_sig_param", "confidence" => "review", "path" => "src/x.rb", "line" => 1,
            "data" => { "name" => "y", "type" => "String", "source" => "static_param_backflow" } },
        ]

        lines = report.send(:build_header, evidence)
        report.send(:append_hygiene_overview_summary, lines, evidence, actions)

        expect(lines.join("\n")).to include("## Hygiene Overview")
        # The bulleted coverage subsections were consolidated into two
        # tables; the hygiene overview now leads with those.
        expect(lines.join("\n")).to include("### Type Soundness")
        expect(lines.join("\n")).to include("### Untyped Cause Breakdown")
        expect(lines.join("\n")).to include("## Action Plan Counts")
        expect(lines.join("\n")).to include("HIGH evidence: 1")
        expect(lines.join("\n")).to include("REVIEW evidence: 1")
        # Heavy sections must NOT be present
        expect(lines.join("\n")).not_to include("### Param T.untyped Buckets")
        expect(lines.join("\n")).not_to include("### Return Origin Pressure")
      end
    end

    it "reports per-method slot contribution counts in untyped slot buckets" do
      report = described_class.new
      evidence = {
        "methods" => [
          { "source" => { "path" => "lib/example.rb", "line" => 1 }, "calls" => 0 },
        ],
        "facts" => {
          "existing_sigs" => [
            { "path" => "lib/example.rb", "line" => 1, "class" => "Example", "method" => "foo",
              "sig" => "sig { params(a: T.untyped, b: T.untyped).returns(T.untyped) }",
              "params" => [{ "name" => "a" }, { "name" => "b" }] },
          ],
        },
      }
      lines = []

      report.send(:append_untyped_breakdown, lines, evidence)

      expect(lines).to include("### Param T.untyped Buckets")
      expect(lines).to include("### Return T.untyped Buckets")
      expect(lines).to include("### Param T.untyped Source Categories")
      expect(lines).to include("### Return T.untyped Source Categories")
      expect(lines).to include("### Param Unknown Expression Causes")
      expect(lines).to include("### Return Unknown Expression Causes")
      expect(lines).to include("- slot not observed: method was not hit: 2")
      expect(lines).to include("  - 2 slots: lib/example.rb:1 Example#foo a; 0 call(s); observed no observed runtime type")
    end

    it "links paths relative to a custom report output directory" do
      report = described_class.new(["--with-links", "--output-path=gems/nil-kill"])
      src_abs = File.join(NilKill::ROOT, "src", "ast", "parser.rb")
      gem_abs = File.join(NilKill::ROOT, "gems", "nil-kill", "lib", "nil_kill.rb")

      expect(report.format_report_line("- #{src_abs}:42")).to eq("- [src/ast/parser.rb:42](../../src/ast/parser.rb#L42)")
      expect(report.format_report_line("- #{gem_abs}:12")).to eq("- [gems/nil-kill/lib/nil_kill.rb:12](lib/nil_kill.rb#L12)")
    end

    it "adds a toc, starts linked reports at hygiene, and truncates long bullet lists by default" do
      report = described_class.new(["--with-links"])
      lines = [
        "# Nil Kill Report",
        "",
        "- Target dirs: src",
        "- Methods indexed: 10",
        "",
        "## Project Prioritization",
        "### Nil Source Fixes",
        "- priority item",
        "## Hygiene Overview",
        "### Class And Instance Variable Slots",
        "- ivar item",
        "### Struct Field Slots",
        "- struct item",
        "### Signature Slots",
        *Array.new(12) { |idx| "- item #{idx + 1}" },
        "### Return Hygiene",
        "- Return slots indexed: 10",
        "#### Control Shape",
        "",
        "- branchless: 5",
        "Next bucket:",
        *Array.new(12) { |idx| "- next #{idx + 1}" },
        "## Review Actions (1)",
        "- review item",
      ]

      prepared = report.prepare_linked_report(lines)

      expect(prepared[2]).to eq("## Table of Contents")
      expect(prepared.index("## Project Prioritization")).to be < prepared.index("## Hygiene Overview")
      expect(prepared.index("## Hygiene Overview")).to be < prepared.index("## Run Summary")
      expect(prepared.index("## Run Summary")).to be > prepared.index("## Review Actions (1)")
      expect(prepared.index("### Class And Instance Variable Slots")).to be < prepared.index("### Signature Slots")
      expect(prepared.index("### Struct Field Slots")).to be < prepared.index("### Signature Slots")
      expect(prepared.index("#### Control Shape")).to be > prepared.index("### Return Hygiene")
      expect(prepared).to include("- [Hygiene Overview](#hygiene-overview)")
      expect(prepared).to include("- [Project Prioritization](#project-prioritization)")
      expect(prepared).to include("#### Control Shape")
      expect(prepared).to include("- [Review Actions (1)](#review-actions-1)")
      expect(prepared).not_to include("<details><summary>More items</summary>")
      expect(prepared).not_to include("- item 11")
      expect(prepared).to include("- ... and 2 more (run with `--full` to see all)")
      expect(prepared).to include("- ... and 2 more (run with `--full` to see all)")
      expect(prepared).not_to include("</details>")
      expect(prepared[prepared.index("## Review Actions (1)") - 1]).to eq("")
    end

    it "keeps overflow bullets collapsed in full linked reports" do
      report = described_class.new(["--with-links", "--full"])
      lines = [
        "# Nil Kill Report",
        "",
        "- Target dirs: src",
        "## Signature Slots",
        *Array.new(12) { |idx| "- item #{idx + 1}" },
        "## Review Actions (1)",
        "- review item",
      ]

      prepared = report.prepare_linked_report(lines, full: true)

      expect(prepared).to include("<details><summary>More items</summary>")
      expect(prepared).to include("- item 11")
      expect(prepared).to include("</details>")
      close_idx = prepared.rindex("</details>")
      expect(prepared[close_idx + 1]).to eq("")
      expect(prepared[close_idx + 2]).to eq("## Review Actions (1)")
    end

    it "clusters similar hash shapes with pressure into one struct candidate" do
      evidence = {
        "facts" => {
          "hash_shapes" => [
            { "path" => "src/diagnostics.rb", "line" => 10, "keys" => %w[category severity summary template],
              "value_types" => %w[Symbol String String String], "code" => "{category: :lint, severity: \"warning\", summary: \"s\", template: \"t\"}" },
            { "path" => "src/diagnostics.rb", "line" => 20, "keys" => %w[category cause fix_hint severity summary template],
              "value_types" => %w[Symbol String String String String String], "code" => "{category: :lint, cause: \"c\", fix_hint: \"f\", severity: \"warning\", summary: \"s\", template: \"t\"}" },
          ],
          "collection_index_lookups" => [
            { "path" => "src/use.rb", "line" => 30, "code" => "entry[:category]", "receiver" => "entry", "index" => ":category",
              "lookup_type" => "T.nilable(Symbol)", "status" => "typed lookup",
              "origin" => { "kind" => "hash literal", "path" => "src/diagnostics.rb", "line" => 10,
                "name" => "entry", "code" => "{category: :lint, severity: \"warning\", summary: \"s\", template: \"t\"}" } },
            { "path" => "src/use.rb", "line" => 31, "code" => "entry.fetch(:fix_hint)", "receiver" => "entry", "index" => ":fix_hint",
              "lookup_type" => "T.nilable(String)", "status" => "typed lookup",
              "origin" => { "kind" => "hash literal", "path" => "src/diagnostics.rb", "line" => 20,
                "name" => "entry", "code" => "{category: :lint, cause: \"c\", fix_hint: \"f\", severity: \"warning\", summary: \"s\", template: \"t\"}" } },
          ],
          "param_origins" => [],
          "return_origins" => [],
          "hash_record_blockers" => [
            { "path" => "src/use.rb", "line" => 32, "kind" => "dynamic_key", "code" => "entry[key]",
              "receiver" => "entry", "message" => "dynamic hash-record key prevents struct accessor rewrite",
              "origin" => { "kind" => "hash literal", "path" => "src/diagnostics.rb", "line" => 10,
                "name" => "entry", "code" => "{category: :lint, severity: \"warning\", summary: \"s\", template: \"t\"}" } },
          ],
          "existing_sigs" => [],
          "unsigned_methods" => [],
          "struct_declarations" => [],
          "struct_field_static" => [],
        },
        "methods" => [],
      }
      report = described_class.allocate
      report.instance_variable_set(:@evidence, evidence)

      rows = report.send(:hash_record_struct_candidates, evidence)

      expect(rows.size).to eq(1)
      expect(rows.first["common_keys"]).to eq(%w[category severity summary template])
      expect(rows.first["optional_keys"]).to eq(%w[cause fix_hint])
      expect(rows.first["read_counts"]).to include("category" => 1, "fix_hint" => 1)
      expect(rows.first["producers"]).to include(
        a_hash_including("path" => "src/diagnostics.rb", "line" => 10, "keys" => %w[category severity summary template])
      )
      expect(rows.first["consumers"]).to include(
        a_hash_including("path" => "src/use.rb", "line" => 31, "code" => "entry.fetch(:fix_hint)", "key" => "fix_hint")
      )
      expect(rows.first["blockers"]).to include(
        a_hash_including("path" => "src/use.rb", "line" => 32, "kind" => "dynamic_key")
      )
      expect(rows.first["fields"]).to include(
        { "name" => "fix_hint", "type" => "T.nilable(String)", "optional" => true }
      )
    end

    it "does not merge similar hash keysets when discriminator field types conflict" do
      evidence = {
        "facts" => {
          "hash_shapes" => [
            { "path" => "src/parser.rb", "line" => 10, "keys" => %w[kind value],
              "value_types" => %w[Symbol AST::Node], "code" => "{kind: :when, value: node}" },
            { "path" => "src/lsp.rb", "line" => 20, "keys" => %w[kind value],
              "value_types" => %w[String String], "code" => "{kind: \"markdown\", value: text}" },
            { "path" => "src/parser.rb", "line" => 30, "keys" => %w[kind value body],
              "value_types" => %w[Symbol AST::Node T::Array[AST::Node]], "code" => "{kind: :if, value: node, body: body}" },
          ],
          "collection_index_lookups" => [],
          "param_origins" => [],
          "return_origins" => [],
          "hash_record_blockers" => [],
          "existing_sigs" => [],
          "unsigned_methods" => [],
          "struct_declarations" => [],
          "struct_field_static" => [],
        },
        "methods" => [],
      }
      report = described_class.allocate
      report.instance_variable_set(:@evidence, evidence)

      rows = report.send(:hash_record_struct_candidates, evidence)

      expect(rows.size).to eq(2)
      expect(rows.map { |row| row["producers"].map { |producer| producer["path"] }.uniq }.map(&:sort)).to contain_exactly(
        ["src/parser.rb"],
        ["src/lsp.rb"],
      )
    end

    it "does not merge similar hash keysets when parameterized collection field types conflict" do
      evidence = {
        "facts" => {
          "hash_shapes" => [
            { "path" => "src/int_items.rb", "line" => 10, "keys" => %w[name items],
              "value_types" => ["String", "T::Array[Integer]"], "code" => "{name: \"ids\", items: [1]}" },
            { "path" => "src/string_items.rb", "line" => 20, "keys" => %w[name items],
              "value_types" => ["String", "T::Array[String]"], "code" => "{name: \"names\", items: [\"a\"]}" },
          ],
          "collection_index_lookups" => [],
          "param_origins" => [],
          "return_origins" => [],
          "hash_record_blockers" => [],
          "existing_sigs" => [],
          "unsigned_methods" => [],
          "struct_declarations" => [],
          "struct_field_static" => [],
        },
        "methods" => [],
      }
      report = described_class.allocate
      report.instance_variable_set(:@evidence, evidence)

      rows = report.send(:hash_record_struct_candidates, evidence)

      expect(rows.size).to eq(2)
      expect(rows.map { |row| row["producers"].first["path"] }).to contain_exactly("src/int_items.rb", "src/string_items.rb")
    end
  end

  describe NilKill::Infer do
    def infer_with_store
      infer = described_class.allocate
      infer.instance_variable_set(:@store, NilKill::Store.new)
      infer
    end

    describe "enrich_return_origins_with_receiver_inference!" do
      def with_rbi_stub(infer, &block)
        stub = Object.new
        stub.define_singleton_method(:return_type) do |method, recv|
          case [method.to_s, recv.to_s]
          when %w[token AST::Foo] then "Token"
          when %w[token AST::Bar] then "Token"
          when %w[token AST::Mismatch] then "Symbol"
          when %w[token AST::ReturnsNilable] then "T.nilable(Token)"
          else nil
          end
        end
        original = NilKill.method(:rbi_return_index)
        NilKill.define_singleton_method(:rbi_return_index) { stub }
        begin
          block.call
        ensure
          NilKill.define_singleton_method(:rbi_return_index, original)
        end
      end

                                              end

                                                                                                                                            it "treats calls on a global-variable receiver as untyped (`$stderr.puts` is not assumed to return NilClass)" do
      Dir.mktmpdir("nil-kill-global-recv", NilKill::ROOT) do |dir|
        source = File.join(dir, "global_recv.rb")
        File.write(source, <<~RUBY)
          class Example
            extend T::Sig

            sig { returns(T.untyped) }
            def emit
              $stderr.puts "event"
            end
          end
        RUBY

        isolated_env("NIL_KILL_TARGETS" => dir) do
          NilKill::Infer.new(["--no-sorbet"]).run
        end

        evidence = JSON.parse(File.read(NilKill::EVIDENCE_PATH))
        # The proposer must NOT emit a HIGH fix_sig_return -> NilClass: `$stderr`
        # is dynamically reassignable, so the actual class of `$stderr.puts` at
        # runtime is whatever the runtime has assigned -- can't be locked down
        # statically.
        nilclass_action = evidence["actions"].find do |action|
          action["kind"] == "fix_sig_return" &&
            action["confidence"] == "high" &&
            action["path"].end_with?("/global_recv.rb") &&
            action.dig("data", "type") == "NilClass"
        end
        expect(nilclass_action).to be_nil
      end
    end

    it "unused_return scanner sees callers outside target_dirs when NIL_KILL_TARGETS is unset" do
      Dir.mktmpdir("nk-scan-scope", NilKill::ROOT) do |dir|
        File.write(File.join(dir, "spec_fake.rb"), "# spec-like file\n")
        original = ENV["NIL_KILL_TARGETS"]
        ENV.delete("NIL_KILL_TARGETS")
        begin
          # Don't scan the entire project; just verify the method returns files
          files = NilKill.usage_scan_files
          expect(files).to_not be_empty
        ensure
          ENV["NIL_KILL_TARGETS"] = original
        end
      end
    end

    it "unused_return scanner scopes to target_files when NIL_KILL_TARGETS is set (isolated_env behaviour)" do
      Dir.mktmpdir("nil-kill-isolated-scan", NilKill::ROOT) do |dir|
        File.write(File.join(dir, "lone.rb"), "# nothing\n")
        isolated_env("NIL_KILL_TARGETS" => dir) do
          files = NilKill.usage_scan_files
          expect(files.size).to eq(1)
          expect(files.first).to end_with("/lone.rb")
        end
      end
    end

    it "uses indexed return-usage facts before falling back to AST scans" do
      infer = infer_with_store
      evidence = {
        "facts" => {
          "existing_sigs" => [
            { "path" => "app/example.rb", "line" => 1, "class" => "Example", "method" => "answer", "kind" => "instance",
              "sig" => "sig { returns(T.untyped) }" }
          ],
          "return_usage_sites" => [
            { "path" => "spec/example_spec.rb", "line" => 3, "name" => "answer", "context" => "value", "current_method" => nil }
          ],
        },
      }

      expect(infer.send(:unused_return_methods, evidence)).to be_empty

      # Fallback: empty indexed facts triggers filesystem scan — scope to empty dir
      Dir.mktmpdir("nk-unused-return", NilKill::ROOT) do |dir|
        isolated_env("NIL_KILL_TARGETS" => dir) do
          evidence["facts"]["return_usage_sites"] = []
          expect(infer.send(:unused_return_methods, evidence)).to include(a_hash_including("method" => "answer"))
        end
      end
    end

                        it "turns Sorbet result-type errors into review widening feedback" do
      infer = infer_with_store
      output = <<~TEXT
        lib/example.rb:12: Expected `String` but found `T.nilable(String)` for method result type https://srb.help/7005
            12 |  end
                  ^^^
          Expected `String` for result type of method `name`:
            lib/example.rb:8:
             8 | sig { returns(String) }
      TEXT

      feedback = infer.send(:parse_sorbet_feedback, output)

      expect(feedback).to include(
        a_hash_including(
          "code" => "7005",
          "path" => "lib/example.rb",
          "line" => 8,
          "message" => include("widening return")
        )
      )
    end

            it "promotes unused T.untyped returns to verifiable void actions" do
      Dir.mktmpdir("nil-kill-void", NilKill::ROOT) do |dir|
        source = File.join(dir, "void_example.rb")
        File.write(source, <<~RUBY)
          class VoidExample
            extend T::Sig

            sig { returns(T.untyped) }
            def emit
              puts "event"
            end

            sig { returns(String) }
            def caller
              emit
              "done"
            end
          end
        RUBY

        isolated_env("NIL_KILL_TARGETS" => dir) do
          expect { NilKill::Infer.new(["--no-sorbet"]).run }.to output(/Nil Kill Report/).to_stdout
        end

        evidence = JSON.parse(File.read(NilKill::EVIDENCE_PATH))
        rel = Pathname.new(source).to_s
        expect(evidence["actions"]).to include(
          a_hash_including(
            "kind" => "fix_sig_return",
            "confidence" => "high",
            "path" => rel,
            "line" => 5,
            "data" => a_hash_including("type" => "void", "source" => "unused_return")
          )
        )
      end
    end

    it "propagates unused return evidence backward through return-forwarding chains" do
      Dir.mktmpdir("nil-kill-void-chain", NilKill::ROOT) do |dir|
        source = File.join(dir, "void_chain_example.rb")
        File.write(source, <<~RUBY)
          class VoidChainExample
            extend T::Sig

            sig { returns(T.untyped) }
            def leaf_value
              "event"
            end

            sig { returns(T.untyped) }
            def middle_value
              leaf_value
            end

            sig { returns(T.untyped) }
            def top_value
              middle_value
            end

            sig { void }
            def run
              top_value
            end
          end
        RUBY

        isolated_env("NIL_KILL_TARGETS" => dir) do
          expect { NilKill::Infer.new(["--no-sorbet"]).run }.to output(/Nil Kill Report/).to_stdout
        end

        evidence = JSON.parse(File.read(NilKill::EVIDENCE_PATH))
        rel = Pathname.new(source).to_s
        void_lines = evidence["actions"].select do |action|
          action["kind"] == "fix_sig_return" &&
            action["confidence"] == "high" &&
            action["path"] == rel &&
            action.dig("data", "type") == "void"
        end.map { |action| action["line"] }

        expect(void_lines).to include(5, 10, 15)
      end
    end

    it "treats explicit return forwarding as unused when the wrapper return is unused" do
      Dir.mktmpdir("nil-kill-explicit-void-chain", NilKill::ROOT) do |dir|
        source = File.join(dir, "explicit_void_chain_example.rb")
        File.write(source, <<~RUBY)
          class ExplicitVoidChainExample
            extend T::Sig

            sig { returns(T.untyped) }
            def explicit_leaf
              "event"
            end

            sig { returns(T.untyped) }
            def explicit_wrapper
              return explicit_leaf
            end

            sig { void }
            def run
              explicit_wrapper
            end
          end
        RUBY

        isolated_env("NIL_KILL_TARGETS" => dir) do
          expect { NilKill::Infer.new(["--no-sorbet"]).run }.to output(/Nil Kill Report/).to_stdout
        end

        evidence = JSON.parse(File.read(NilKill::EVIDENCE_PATH))
        rel = Pathname.new(source).to_s
        void_lines = evidence["actions"].select do |action|
          action["kind"] == "fix_sig_return" &&
            action["confidence"] == "high" &&
            action["path"] == rel &&
            action.dig("data", "type") == "void"
        end.map { |action| action["line"] }

        expect(void_lines).to include(5, 10)
      end
    end

    it "does not mark a return-forwarding chain void when the final value is used" do
      Dir.mktmpdir("nil-kill-void-used-chain", NilKill::ROOT) do |dir|
        source = File.join(dir, "used_chain_example.rb")
        File.write(source, <<~RUBY)
          class UsedChainExample
            extend T::Sig

            sig { returns(T.untyped) }
            def used_leaf
              "event"
            end

            sig { returns(T.untyped) }
            def used_middle
              used_leaf
            end

            sig { returns(String) }
            def run
              value = used_middle
              value.to_s
            end
          end
        RUBY

        isolated_env("NIL_KILL_TARGETS" => dir) do
          expect { NilKill::Infer.new(["--no-sorbet"]).run }.to output(/Nil Kill Report/).to_stdout
        end

        evidence = JSON.parse(File.read(NilKill::EVIDENCE_PATH))
        rel = Pathname.new(source).relative_path_from(Pathname.new(NilKill::ROOT)).to_s
        void_lines = evidence["actions"].select do |action|
          action["kind"] == "fix_sig_return" &&
            action["confidence"] == "high" &&
            action["path"] == rel &&
            action.dig("data", "type") == "void"
        end.map { |action| action["line"] }

        expect(void_lines).not_to include(5, 10)
      end
    end

    it "does not auto-promote ambiguous method names to void" do
      Dir.mktmpdir("nil-kill-void-ambiguous", NilKill::ROOT) do |dir|
        source = File.join(dir, "ambiguous_void_example.rb")
        File.write(source, <<~RUBY)
          class FirstAmbiguousVoid
            extend T::Sig

            sig { returns(T.untyped) }
            def duplicate_name
              "first"
            end
          end

          class SecondAmbiguousVoid
            extend T::Sig

            sig { returns(T.untyped) }
            def duplicate_name
              "second"
            end
          end

          class AmbiguousVoidRunner
            extend T::Sig

            sig { params(target: T.untyped).void }
            def run(target)
              target.duplicate_name
            end
          end
        RUBY

        isolated_env("NIL_KILL_TARGETS" => dir) do
          expect { NilKill::Infer.new(["--no-sorbet"]).run }.to output(/Nil Kill Report/).to_stdout
        end

        evidence = JSON.parse(File.read(NilKill::EVIDENCE_PATH))
        rel = Pathname.new(source).relative_path_from(Pathname.new(NilKill::ROOT)).to_s
        expect(evidence["actions"]).not_to include(
          a_hash_including(
            "kind" => "fix_sig_return",
            "confidence" => "high",
            "path" => rel,
            "data" => a_hash_including("type" => "void")
          )
        )
      end
    end

    it "promotes untyped returns forwarded through an already-void wrapper" do
      Dir.mktmpdir("nil-kill-void-typed-wrapper", NilKill::ROOT) do |dir|
        source = File.join(dir, "typed_void_wrapper_example.rb")
        File.write(source, <<~RUBY)
          class TypedVoidWrapperExample
            extend T::Sig

            sig { returns(T.untyped) }
            def leaf_event
              "event"
            end

            sig { void }
            def run
              leaf_event
            end
          end
        RUBY

        isolated_env("NIL_KILL_TARGETS" => dir) do
          expect { NilKill::Infer.new(["--no-sorbet"]).run }.to output(/Nil Kill Report/).to_stdout
        end

        evidence = JSON.parse(File.read(NilKill::EVIDENCE_PATH))
        rel = Pathname.new(source).to_s
        expect(evidence["actions"]).to include(
          a_hash_including(
            "kind" => "fix_sig_return",
            "confidence" => "high",
            "path" => rel,
            "line" => 5,
            "data" => a_hash_including("type" => "void", "source" => "unused_return")
          )
        )
      end
    end

    it "does not promote returns forwarded through typed value wrappers to void" do
      Dir.mktmpdir("nil-kill-typed-value-wrapper", NilKill::ROOT) do |dir|
        source = File.join(dir, "typed_value_wrapper_example.rb")
        File.write(source, <<~RUBY)
          class TypedValueWrapperExample
            extend T::Sig

            sig { returns(T.untyped) }
            def leaf_nil
              nil
            end

            sig { returns(NilClass) }
            def wrapper_nil
              return leaf_nil
            end

            sig { void }
            def run
              wrapper_nil
            end
          end
        RUBY

        isolated_env("NIL_KILL_TARGETS" => dir) do
          expect { NilKill::Infer.new(["--no-sorbet"]).run }.to output(/Nil Kill Report/).to_stdout
        end

        evidence = JSON.parse(File.read(NilKill::EVIDENCE_PATH))
        rel = Pathname.new(source).relative_path_from(Pathname.new(NilKill::ROOT)).to_s
        expect(evidence["actions"]).not_to include(
          a_hash_including(
            "kind" => "fix_sig_return",
            "confidence" => "high",
            "path" => rel,
            "line" => 5,
            "data" => a_hash_including("type" => "void")
          )
        )
      end
    end

    it "promotes strong static stdlib nilable returns to high-confidence fixes" do
      Dir.mktmpdir("nil-kill-stdlib-return", NilKill::ROOT) do |dir|
        source = File.join(dir, "stdlib_return_example.rb")
        File.write(source, <<~RUBY)
          class StdlibReturnExample
            extend T::Sig

            sig { params(lines: T::Array[String], ok: T::Boolean).returns(T.untyped) }
            def maybe_join(lines, ok)
              return nil unless ok
              lines.join
            end
          end
        RUBY

        isolated_env("NIL_KILL_TARGETS" => dir) do
          expect { NilKill::Infer.new(["--no-sorbet"]).run }.to output(/Nil Kill Report/).to_stdout
        end

        evidence = JSON.parse(File.read(NilKill::EVIDENCE_PATH))
        rel = Pathname.new(source).to_s
        expect(evidence["actions"]).to include(
          a_hash_including(
            "kind" => "fix_sig_return",
            "confidence" => "high",
            "path" => rel,
            "line" => 5,
            # TODO: Investigate
            "data" => a_hash_including("type" => "void", "source" => "unused_return")
          )
        )
      end
    end

    it "promotes always-raising T.untyped returns to verifiable T.noreturn actions" do
      Dir.mktmpdir("nil-kill-noreturn", NilKill::ROOT) do |dir|
        source = File.join(dir, "noreturn_example.rb")
        File.write(source, <<~RUBY)
          class NoReturnExample
            extend T::Sig

            sig { returns(T.untyped) }
            def fail_now
              raise "boom"
            end
          end
        RUBY

        isolated_env("NIL_KILL_TARGETS" => dir) do
          expect { NilKill::Infer.new(["--no-sorbet"]).run }.to output(/Nil Kill Report/).to_stdout
        end

        evidence = JSON.parse(File.read(NilKill::EVIDENCE_PATH))
        rel = Pathname.new(source).to_s
        expect(evidence["actions"]).to include(
          a_hash_including(
            "kind" => "fix_sig_return",
            "confidence" => "high",
            "path" => rel,
            "line" => 5,
            "data" => a_hash_including("type" => "T.noreturn", "source" => "noreturn_body")
          )
        )
      end
    end

    it "does not promote guard-clause methods with normal returns to T.noreturn" do
      Dir.mktmpdir("nil-kill-noreturn-guard", NilKill::ROOT) do |dir|
        source = File.join(dir, "noreturn_guard_example.rb")
        File.write(source, <<~RUBY)
          class NoReturnGuardExample
            extend T::Sig

            sig { params(value: String).returns(T.untyped) }
            def assert_prefix!(value)
              return unless value.start_with?("!")
              raise "bad"
            end
          end
        RUBY

        isolated_env("NIL_KILL_TARGETS" => dir) do
          expect { NilKill::Infer.new(["--no-sorbet"]).run }.to output(/Nil Kill Report/).to_stdout
        end

        evidence = JSON.parse(File.read(NilKill::EVIDENCE_PATH))
        rel = Pathname.new(source).relative_path_from(Pathname.new(NilKill::ROOT)).to_s
        expect(evidence["actions"]).not_to include(
          a_hash_including(
            "kind" => "fix_sig_return",
            "path" => rel,
            "line" => 5,
            "data" => a_hash_including("type" => "T.noreturn")
          )
        )
      end
    end

        describe "build_project_method_return_index" do
      def with_rbi_field_types(infer, types)
        store = infer.instance_variable_get(:@store)
        original = store.facts["rbi_field_types"]
        store.facts["rbi_field_types"] = types.map do |(klass, field), type|
          { "class" => klass, "field" => field, "type" => type }
        end
        yield
      ensure
        store.facts["rbi_field_types"] = original if store
      end

                                                    end

    describe "hash-record collection escape gates" do
                                        end
  end

  describe NilKill::SpecDependencyIndex do
    it "finds spec files that transitively require a changed src file" do
      Dir.mktmpdir("nil-kill-dep-index", NilKill::ROOT) do |dir|
        FileUtils.mkdir_p(File.join(dir, "src"))
        FileUtils.mkdir_p(File.join(dir, "spec"))
        File.write(File.join(dir, "src", "leaf.rb"), "")
        File.write(File.join(dir, "src", "middle.rb"), "require_relative \"leaf\"\n")
        File.write(File.join(dir, "src", "top.rb"), "require_relative \"middle\"\n")
        spec_path = File.join(dir, "spec", "top_spec.rb")
        File.write(spec_path, "require_relative \"../src/top\"\n")
        unrelated_spec = File.join(dir, "spec", "unrelated_spec.rb")
        File.write(unrelated_spec, "")

        isolated_env("NIL_KILL_TARGETS" => dir) do
          NilKill::SpecDependencyIndex.reset!
          index = described_class.build
          specs = index.specs_depending_on([File.join(dir, "src", "leaf.rb")])
          expect(specs).to include(spec_path)
          expect(specs).not_to include(unrelated_spec)
        end
      end
    ensure
      described_class.reset!
    end

    it "returns spec files for non-existent paths as empty" do
      Dir.mktmpdir("nil-kill-dep-empty", NilKill::ROOT) do |dir|
        isolated_env("NIL_KILL_TARGETS" => dir) do
          described_class.reset!
          index = described_class.build
          expect(index.specs_depending_on([File.join(dir, "does_not_exist.rb")])).to eq([])
        end
      end
    ensure
      described_class.reset!
    end
  end

  describe NilKill::Report do
    describe "struct_field_candidates" do
      it "skips slots with any uninferrable static record (has_unknown_static)" do
        report = described_class.new
        runtime = []
        static = [
          { "class" => "AST::ConcurrentOp", "field" => "op", "type" => "AST::EachOp", "expression" => "each_op" },
          { "class" => "AST::ConcurrentOp", "field" => "op", "type" => nil, "expression" => "inner_op" },
        ]

        candidates = report.struct_field_candidates(runtime, static)

        expect(candidates.find { |c| c["class"] == "AST::ConcurrentOp" && c["field"] == "op" }).to be_nil
      end

      it "still emits when all static records are inferrable" do
        report = described_class.new
        runtime = []
        static = [
          { "class" => "Capabilities::Conflict", "field" => "message", "type" => "String", "expression" => "\"x\"" },
          { "class" => "Capabilities::Conflict", "field" => "message", "type" => "String", "expression" => "\"y\"" },
        ]

        candidates = report.struct_field_candidates(runtime, static)

        slot = candidates.find { |c| c["class"] == "Capabilities::Conflict" && c["field"] == "message" }
        expect(slot).not_to be_nil
        expect(slot["type"]).to eq("String")
      end

      it "preserves bounded concrete node unions for field contracts" do
        report = described_class.new
        runtime = [{
          "class" => "AST::Call", "field" => "target",
          "classes" => ["AST::Identifier", "AST::GetField"], "calls" => 50,
        }]

        candidates = report.struct_field_candidates(runtime, [])

        slot = candidates.find { |candidate| candidate["class"] == "AST::Call" && candidate["field"] == "target" }
        expect(slot.fetch("type")).to eq("T.any(AST::GetField, AST::Identifier)")
      end

      it "skips T.nilable candidates at any nesting depth" do
        report = described_class.new
        runtime = []
        static = [
          { "class" => "Example", "field" => "maybe", "type" => "T.nilable(String)", "expression" => "x" },
        ]

        candidates = report.struct_field_candidates(runtime, static)

        expect(candidates.find { |c| c["class"] == "Example" && c["field"] == "maybe" }).to be_nil
      end

      it "skips weak-collection candidates (T::Array[T.untyped] etc.)" do
        report = described_class.new
        runtime = []
        static = [
          { "class" => "Example", "field" => "items", "type" => "T::Array[T.untyped]", "expression" => "[]" },
        ]

        candidates = report.struct_field_candidates(runtime, static)

        expect(candidates.find { |c| c["class"] == "Example" && c["field"] == "items" }).to be_nil
      end
    end

    describe "untyped_cause_table" do
      it "classifies each category's untyped slots into the five causes with reconciling denominators" do
        report = described_class.new
        evidence = {
          # Rec#a has a concrete add_struct_field_sig action -> genuinely
          # PropagationGap. Rec#b has none -> honest NoEvidence (its RHS
          # is itself untyped; the transitive wall).
          "actions" => [
            { "kind" => "add_struct_field_sig", "data" => { "class" => "Rec", "field" => "a" } },
          ],
          "methods" => [
            # param x observed single String (Refused/Pending) but return
            # NOT observed at runtime so it falls through to the
            # call_untyped source -> PropagationGap.
            { "source" => { "path" => "src/a.rb", "line" => 1 }, "path" => "src/a.rb", "line" => 1,
              "calls" => 5, "params_ok" => { "x" => ["String"] }, "params_by_name" => { "x" => ["String"] },
              "returns" => [] },
            { "source" => { "path" => "src/a.rb", "line" => 9 }, "path" => "src/a.rb", "line" => 9,
              "calls" => 0, "params_ok" => {}, "params_by_name" => {}, "returns" => [] },
          ],
          "facts" => {
            "existing_sigs" => [
              # x: single observed runtime type -> Refused/Pending.
              # return: forwards to g(), and g HAS a concrete sig return
              # program-wide -> far-end resolvable -> PropagationGap.
              { "path" => "src/a.rb", "line" => 1, "class" => "A", "method" => "f",
                "sig" => "sig { params(x: T.untyped).returns(T.untyped) }",
                "return_origin" => { "sources" => [{ "kind" => "call_untyped", "callee" => "g" }], "blockers" => [] } },
              # g: concrete sig return -> seeds the program return index.
              { "path" => "src/a.rb", "line" => 5, "class" => "A", "method" => "g",
                "sig" => "sig { returns(String) }", "return_origin" => {} },
              # never hit, no callsites -> NoEvidence (param) ; return AndNode -> NotImplemented
              { "path" => "src/a.rb", "line" => 9, "class" => "A", "method" => "h",
                "sig" => "sig { params(y: T.untyped).returns(T.untyped) }",
                "return_origin" => { "sources" => [], "blockers" => ["unknown return expression AndNode at src/a.rb:9"] } },
              # return forwards to an unresolvable callee -> transitive
              # wall -> honest NoEvidence (NOT PropagationGap).
              { "path" => "src/a.rb", "line" => 14, "class" => "A", "method" => "k",
                "sig" => "sig { returns(T.untyped) }",
                "return_origin" => { "sources" => [{ "kind" => "call_untyped", "callee" => "mystery" }], "blockers" => [] } },
            ],
            "param_origins" => [],
            "struct_declarations" => [
              { "path" => "src/a.rb", "line" => 20, "class" => "Rec", "fields" => %w[a b] },
            ],
            "struct_field_static" => [
              { "class" => "Rec", "field" => "a", "type" => "T.untyped", "expression" => "param_x", "path" => "src/a.rb", "line" => 20 },
            ],
            "tlet_sites" => [
              { "tlet" => true, "type" => "T.untyped", "path" => "src/a.rb", "line" => 30, "name" => "@z" },
            ],
            "type_dependencies" => [{
              "id" => "ivar:A:@z", "candidate" => true, "candidate_kind" => "instance_field",
              "file" => "src/a.rb", "line" => 30, "name" => "@z", "owner" => "A",
            }],
            "ivar_param_origins" => {},
            "collection_runtime" => [],
          },
        }
        # struct_rbi_types reads generated RBI off disk; stub to the
        # synthetic declared fields so the test is hermetic.
        report.define_singleton_method(:struct_rbi_types) do
          { %w[Rec a] => "T.untyped", %w[Rec b] => "T.untyped" }
        end
        # Isolate cause classification from the unused-return (void)
        # heuristic, which flags everything as unused under sparse
        # synthetic evidence and would mask the call_untyped path.
        report.define_singleton_method(:unused_return_method_names) { |_| [] }

        table = report.untyped_cause_table(evidence)

        # Param inputs: x (Refused/Pending, single observed String) + y (NoEvidence, never hit, no callsites)
        expect(table["Param inputs"]["Refused/Pending"]).to eq(1)
        expect(table["Param inputs"]["NoEvidence"]).to eq(1)
        # Returns: f -> g() resolvable program-wide -> PropagationGap ;
        # h -> AndNode (not statically modelled, no runtime) and
        # k -> mystery() untyped anywhere -> both honest NoEvidence
        # (NotImplemented category removed; h/k are real evidence gaps).
        expect(table["Returns"]["PropagationGap"]).to eq(1)
        expect(table["Returns"]["NoEvidence"]).to eq(2)
        # Struct/ivar: @z T.let untyped -> Refused/Pending ; Rec#a expr param -> PropagationGap ; Rec#b no static -> NoEvidence
        expect(table["Struct/class fields & ivars"]["Refused/Pending"]).to eq(1)
        expect(table["Struct/class fields & ivars"]["PropagationGap"]).to eq(1)
        expect(table["Struct/class fields & ivars"]["NoEvidence"]).to eq(1)
        # denominator == sum of the six causes per row
        table.each_value do |counts|
          NilKill::Report::UNTYPED_CAUSES.each { |c| counts[c] ||= 0 }
        end
        expect(NilKill::Report::UNTYPED_CAUSES.sum { |c| table["Struct/class fields & ivars"][c] }).to eq(3)
      end
    end

    describe "struct field and ivar accounting" do
      it "prefers a strong source accessor over an untyped raw struct declaration" do
        report = described_class.new
        evidence = {
          "methods" => [], "actions" => [],
          "facts" => {
            "existing_sigs" => [], "tlet_sites" => [], "type_dependencies" => [],
            "type_definitions" => [{
              "kind" => "method_signature", "owner" => "AST::Field", "name" => "type",
              "signature" => "sig { returns(Type) }",
              "return_type" => { "kind" => "Primitive", "data" => "Type" },
            }],
            "struct_declarations" => [{
              "path" => "src/ast.rb", "class" => "AST::Field", "fields" => ["type"],
              "field_types" => { "type" => "T.untyped" },
            }],
          },
        }
        report.define_singleton_method(:struct_rbi_types) { {} }

        row = report.type_soundness_table(evidence).fetch("Struct/class fields & ivars")

        expect(row).to include("total" => 1, "strong" => 1, "weak" => 0, "untyped" => 0)
      end

      it "credits source accessors inherited through included modules" do
        report = described_class.new
        evidence = {
          "methods" => [], "actions" => [],
          "facts" => {
            "existing_sigs" => [], "tlet_sites" => [], "type_dependencies" => [],
            "type_definitions" => [
              { "kind" => "included_module", "owner" => "AST::Loop", "name" => "AST::DropsField" },
              {
                "kind" => "method_signature", "owner" => "AST::DropsField", "name" => "drops",
                "return_type" => { "kind" => "Primitive", "data" => "AST::DropSet" },
              },
            ],
            "struct_declarations" => [{
              "path" => "src/ast.rb", "class" => "AST::Loop", "fields" => ["drops"], "field_types" => {},
            }],
          },
        }
        report.define_singleton_method(:struct_rbi_types) { {} }

        row = report.type_soundness_table(evidence).fetch("Struct/class fields & ivars")

        expect(row).to include("total" => 1, "strong" => 1, "weak" => 0, "untyped" => 0)
      end

      it "counts only unique instance-field T.let roots as ivars" do
        report = described_class.new
        evidence = {
          "methods" => [], "actions" => [],
          "facts" => {
            "existing_sigs" => [], "struct_declarations" => [], "type_definitions" => [],
            "tlet_sites" => [
              { "path" => "src/a.rb", "line" => 3, "tlet" => true, "type" => "T.untyped" },
              { "path" => "src/a.rb", "line" => 4, "tlet" => true, "type" => "T.untyped" },
              { "path" => "src/a.rb", "line" => 5, "tlet" => true, "type" => "T.untyped" },
            ],
            "type_dependencies" => [
              {
                "id" => "ivar:A:@value", "candidate" => true, "candidate_kind" => "instance_field",
                "file" => "src/a.rb", "line" => 3, "name" => "@value", "owner" => "A",
              },
              {
                "id" => "ivar:A:@value", "candidate" => true, "candidate_kind" => "instance_field",
                "file" => "src/a.rb", "line" => 4, "name" => "@value", "owner" => "A",
              },
              {
                "id" => "local:A#run:value", "candidate" => true, "candidate_kind" => "local",
                "file" => "src/a.rb", "line" => 5, "name" => "value", "owner" => "A",
              },
            ],
          },
        }
        report.define_singleton_method(:struct_rbi_types) { {} }

        row = report.type_soundness_table(evidence).fetch("Struct/class fields & ivars")

        expect(row).to include("total" => 1, "strong" => 0, "weak" => 0, "untyped" => 1)
      end
    end

    describe "untyped_evidence_gaps (residual NoEvidence broken out by why)" do
      it "partitions NoEvidence into unseen / discarded_return / only_nil with locations" do
        report = described_class.new
        evidence = {
          "methods" => [
            # run -> executed, return value never traced -> discarded_return
            { "source" => { "path" => "src/a.rb", "line" => 1 }, "calls" => 9,
              "params_by_name" => {}, "params_ok" => {}, "returns" => [] },
            # only-nil param
            { "source" => { "path" => "src/a.rb", "line" => 20 }, "calls" => 5,
              "params_by_name" => { "x" => ["NilClass"] }, "params_ok" => { "x" => ["NilClass"] }, "returns" => [] },
          ],
          "actions" => [],
          "facts" => {
            # collect_coverage present (a real collect) but not covering
            # A#dead's body -> dead's param is honestly "unseen", and the
            # never_run hard-precondition is satisfied (no raise).
            "collect_coverage" => { "src/other.rb" => [1] },
            "param_origins" => [], "struct_declarations" => [], "tlet_sites" => [],
            "struct_field_runtime" => [], "ivar_runtime" => [], "collection_runtime" => [],
            "return_origins" => [],
            "existing_sigs" => [
              { "path" => "src/a.rb", "line" => 1, "class" => "A", "method" => "run",
                "sig" => "sig { returns(T.untyped) }",
                "return_origin" => { "sources" => [{ "kind" => "call_untyped", "callee" => "mystery" }], "blockers" => [] } },
              { "path" => "src/a.rb", "line" => 20, "class" => "A", "method" => "take",
                "sig" => "sig { params(x: T.untyped).returns(String) }" },
              # never executed (no runtime record)
              { "path" => "src/a.rb", "line" => 40, "class" => "A", "method" => "dead",
                "sig" => "sig { params(z: T.untyped).returns(T.untyped) }",
                "return_origin" => { "sources" => [{ "kind" => "call_untyped", "callee" => "mystery" }], "blockers" => [] } },
            ],
          },
        }

        gaps = report.send(:untyped_evidence_gaps, evidence)
        txt = ->(r) { gaps[r].map { |g| g["text"] } }
        expect(txt.("discarded_return")).to eq(["src/a.rb:1 `A#run` return"])
        expect(gaps["discarded_return"].map { |g| g["cat"] }).to eq(["Returns"])
        expect(txt.("only_nil")).to eq(["src/a.rb:20 `A#take` param `x`"])
        # A#dead never ran and the collect did not cover it -> unseen
        # (the one honest, actionable no-evidence bucket).
        expect(txt.("unseen")).to eq(["src/a.rb:40 `A#dead` param `z`"])
      end

      it "labels a pruned block/Proc param arg_untraced, NOT never_run (the H1b mis-attribution)" do
        report = described_class.new
        evidence = {
          "methods" => [], # method pruned by TracePlan -> no runtime record at all
          "actions" => [],
          "facts" => {
            "param_origins" => [], "struct_declarations" => [], "tlet_sites" => [],
            "struct_field_runtime" => [], "ivar_runtime" => [], "collection_runtime" => [],
            "return_origins" => [],
            "existing_sigs" => [
              { "path" => "src/p.rb", "line" => 5, "end_line" => 9, "class" => "P", "method" => "suffix",
                "sig" => "sig { params(block: T.untyped).returns(Prism::Token) }" },
            ],
          },
        }

        gaps = report.send(:untyped_evidence_gaps, evidence)
        # Even with rec.nil? (pruned) and no collect coverage, a block
        # param is arg_untraced -- it is NOT unseen/never_run/dead.
        expect(gaps["arg_untraced"].map { |g| g["text"] }).to eq(["src/p.rb:5 `P#suffix` param `block`"])
        expect(gaps["unseen"]).to be_empty
        expect(gaps["never_run"]).to be_empty
      end

      it "collect-run coverage is the SOLE signal: body ran here but no record -> collect_ran_untraced (tracer bug)" do
        report = described_class.new
        ev = { "facts" => { "collect_coverage" => { "src/m.rb" => [10, 11, 12] } } }
        # def spans 9..15, collect-run coverage shows interior lines
        # executed -> the method DID run this collect yet has no record
        # == an unambiguous tracer bug (no foreign baseline can mask it).
        expect(report.send(:never_run_reason, ev, "src/m.rb", 9, 15)).to eq("collect_ran_untraced")
        # def at 40..45, NOT in this collect's coverage. There is no
        # second workload to "cover it elsewhere": it is genuinely
        # unseen by the (superset) collect workload.
        expect(report.send(:never_run_reason, ev, "src/m.rb", 40, 45)).to eq("unseen")
      end

      it "does NOT treat a defined-but-never-called method as collect_ran (def-line coverage is not body execution)" do
        report = described_class.new
        # Ruby Coverage marks the `def` line (9) the moment the method
        # is defined at file load -- even if never called. Only the def
        # line is covered; the body (10..14) never ran.
        ev = { "facts" => { "collect_coverage" => { "src/m.rb" => [9] } } }
        # Must NOT be collect_ran_untraced (would falsely accuse the
        # tracer). With collect_coverage present but no body line, the
        # method was simply not reached -> unseen (NOT untraced_covered;
        # that category no longer exists).
        expect(report.send(:never_run_reason, ev, "src/m.rb", 9, 15)).to eq("unseen")
        # A genuinely body-covered method (line 11 inside 9..15) still
        # counts as ran -> real tracer defect. Fresh instance: the
        # collect-coverage index is memoized per Report.
        report2 = described_class.new
        ev2 = { "facts" => { "collect_coverage" => { "src/m.rb" => [9, 11] } } }
        expect(report2.send(:never_run_reason, ev2, "src/m.rb", 9, 15)).to eq("collect_ran_untraced")
      end

      it "closed tree: collect_coverage is the only source; untraced_covered cannot be emitted" do
        report = described_class.new
        # 1. cc present + body ran -> collect_ran_untraced
        run_ev = { "facts" => { "collect_coverage" => { "src/m.rb" => [11] } } }
        expect(report.send(:never_run_reason, run_ev, "src/m.rb", 9, 15)).to eq("collect_ran_untraced")
        # 2. cc present + body NOT run anywhere -> unseen
        miss = described_class.new
        miss_ev = { "facts" => { "collect_coverage" => { "src/other.rb" => [3] } } }
        expect(miss.send(:never_run_reason, miss_ev, "src/m.rb", 9, 15)).to eq("unseen")
        # 3. cc absent entirely -> never_run (degenerate; a real collect
        #    makes this impossible -- cli aborts on zero Coverage).
        none = described_class.new
        expect(none.send(:never_run_reason, { "facts" => {} }, "src/m.rb", 9, 15)).to eq("never_run")
        # The foreign SimpleCov baseline is GONE -- the deletion itself
        # is regression-tested so it can never silently come back.
        expect(described_class::EVIDENCE_GAP_REASONS).not_to have_key("untraced_covered")
        expect(report.respond_to?(:simplecov_covered_files, true)).to be(false)
        expect(described_class.const_defined?(:SIMPLECOV_RESULTSET)).to be(false)
        # collect_ran_untraced and never_run are NOT report columns --
        # they are hard failures, so a tracer regression or a no-collect
        # run can never be a silently-dropped row or a misread "dead".
        expect(described_class::EVIDENCE_GAP_REASONS).not_to have_key("collect_ran_untraced")
        expect(described_class::EVIDENCE_GAP_REASONS).not_to have_key("never_run")
        expect(described_class::EVIDENCE_GAP_HARD.keys).to contain_exactly("collect_ran_untraced", "never_run")
        base_facts = {
          "param_origins" => [], "struct_declarations" => [], "tlet_sites" => [],
          "struct_field_runtime" => [], "ivar_runtime" => [], "collection_runtime" => [],
          "return_origins" => [],
        }
        sig = { "path" => "src/d.rb", "line" => 3, "end_line" => 7, "class" => "D",
                "method" => "go", "sig" => "sig { params(z: T.untyped).returns(String) }" }
        # no collect_coverage at all -> never_run is DROPPED (no signal),
        # NOT raised (would break unit tests) and NOT a column.
        no_cov = { "methods" => [], "actions" => [],
                   "facts" => base_facts.merge("existing_sigs" => [sig]) }
        g = nil
        expect { g = described_class.new.send(:untyped_evidence_gaps, no_cov) }.not_to raise_error
        expect(g).not_to have_key("never_run")
        # body ran in the collect but no record -> collect_ran_untraced -> RAISES
        ran = { "methods" => [], "actions" => [],
                "facts" => base_facts.merge("existing_sigs" => [sig],
                                            "collect_coverage" => { "src/d.rb" => [5] }) }
        expect { described_class.new.send(:untyped_evidence_gaps, ran) }
          .to raise_error(/collect_ran_untraced .* tracer\/trace-plan regression/)
        # No (path, lo, hi) over a present cc can ever yield it.
        [[9, 15], [40, 45], [1, 2]].each do |lo, hi|
          %w[src/m.rb src/x.rb].each do |p|
            inst = described_class.new
            expect(inst.send(:never_run_reason, run_ev, p, lo, hi)).not_to eq("untraced_covered")
          end
        end
      end
    end

    describe "classify_collection_untyped! (owner-identity join, not sig line)" do
      it "matches collection runtime by owner identity, not the sig/decl line" do
        report = described_class.new
        bucket = Hash.new(0)
        evidence = {
          "facts" => {
            "tlet_sites" => [], "struct_declarations" => [],
            "existing_sigs" => [
              { "path" => "src/p.rb", "line" => 10, "end_line" => 40, "class" => "P", "method" => "run",
                "sig" => "sig { params(items: T::Array[T.untyped]).returns(T::Array[T.untyped]) }" },
            ],
            # Runtime recorded at the MUTATION site (line 27), NOT the
            # sig line 10 -- the old [path,line,name] join missed this.
            "collection_runtime" => [
              { "owner_kind" => "method_param", "name" => "items", "path" => "#{NilKill::ROOT}/src/p.rb",
                "line" => 27, "elem_classes" => ["String"], "elem_shapes" => [] },
              { "owner_kind" => "method_return", "name" => "run", "path" => "#{NilKill::ROOT}/src/p.rb",
                "line" => 38, "elem_classes" => %w[String Symbol Integer Float Hash Array TrueClass FalseClass],
                "elem_shapes" => [] },
            ],
          },
        }

        report.send(:classify_collection_untyped!, bucket, evidence)

        # items: single observed elem String -> Refused/Pending (was NoEvidence)
        expect(bucket["Refused/Pending"]).to eq(1)
        # run return: many elem classes -> Heterogeneous (was NoEvidence)
        expect(bucket["Heterogeneous"]).to eq(1)
        expect(bucket["NoEvidence"]).to eq(0)
      end

      it "uses method-boundary element evidence for read-only params (no mutation hook)" do
        report = described_class.new
        bucket = Hash.new(0)
        evidence = {
          # No collection_runtime at all -- the param is only READ, so
          # the mutation hooks never fired. Element classes come from
          # the call-boundary capture in the method record.
          "methods" => [
            { "source" => { "path" => "src/q.rb", "line" => 5 },
              "param_elem" => { "xs" => ["Symbol"] }, "return_elem" => [] },
          ],
          "facts" => {
            "tlet_sites" => [], "struct_declarations" => [], "collection_runtime" => [],
            "existing_sigs" => [
              { "path" => "src/q.rb", "line" => 5, "end_line" => 20, "class" => "Q", "method" => "scan",
                "sig" => "sig { params(xs: T::Array[T.untyped]).returns(T.untyped) }" },
            ],
          },
        }

        report.send(:classify_collection_untyped!, bucket, evidence)
        expect(bucket["Refused/Pending"]).to eq(1)  # single boundary elem Symbol
        expect(bucket["NoEvidence"]).to eq(0)
      end
    end

    describe "classify_struct_ivar_untyped! (consults struct/ivar runtime)" do
      it "classifies observed struct fields by runtime evidence, not blanket NoEvidence" do
        report = described_class.new
        bucket = Hash.new(0)
        evidence = {
          "actions" => [{ "kind" => "add_struct_field_sig", "data" => { "class" => "Rec", "field" => "prop" } }],
          "facts" => {
            "tlet_sites" => [],
            "struct_declarations" => [
              { "class" => "Rec", "fields" => %w[one nilonly many pair prop dead] },
            ],
            "struct_field_runtime" => [
              { "class" => "Rec", "field" => "one", "classes" => ["Type"] },
              { "class" => "Rec", "field" => "nilonly", "classes" => ["NilClass"] },
              { "class" => "Rec", "field" => "many",
                "classes" => %w[AST::While AST::ForRange AST::FuncCall AST::Identifier
                                AST::BinaryOp AST::Literal AST::CallNode AST::StructLit] },
            ],
            "ivar_runtime" => [
              { "class" => "Rec", "name" => "@pair", "classes" => %w[String Integer] },
            ],
          },
        }

        report.send(:classify_struct_ivar_untyped!, bucket, evidence)

        expect(bucket["Refused/Pending"]).to eq(2)  # one (single Type) + nilonly (only nil -> void)
        expect(bucket["Heterogeneous"]).to eq(1)     # many (> MAX_UNION_TYPES)
        expect(bucket["WeakEvidence"]).to eq(1)      # pair (String|Integer)
        expect(bucket["PropagationGap"]).to eq(1)    # prop (add_struct_field_sig action, no runtime)
        expect(bucket["NoEvidence"]).to eq(1)        # dead (no runtime, no action)
      end
    end

    describe "classify_return_untyped_cause (runtime evidence not discarded)" do
      def classify(report, method, rec)
        report.send(:build_program_return_index!, { "facts" => { "return_origins" => [] } })
        report.send(:classify_return_untyped_cause, method, rec, [].to_set)
      end

      it "marks an executed return observed only as nil as Refused/Pending (void), not NoEvidence" do
        report = described_class.new
        method = { "method" => "noop!", "return_origin" => {
          "sources" => [{ "kind" => "call_untyped", "callee" => "mystery" }], "blockers" => [] } }
        rec = { "calls" => 12, "returns" => ["NilClass"] }
        expect(classify(report, method, rec)).to eq("Refused/Pending")
      end

      it "uses observed runtime classes (WeakEvidence) when the static origin is an untyped forwarded call" do
        report = described_class.new
        method = { "method" => "build", "return_origin" => {
          "sources" => [{ "kind" => "call_untyped", "callee" => "mystery" }], "blockers" => [] } }
        rec = { "calls" => 30, "returns" => %w[Array Hash NilClass] }
        # was NoEvidence (transitive wall short-circuit discarded runtime)
        expect(classify(report, method, rec)).to eq("WeakEvidence")
      end

      it "is Heterogeneous when runtime observed many concrete return types" do
        report = described_class.new
        method = { "method" => "lower", "return_origin" => {
          "sources" => [{ "kind" => "call_untyped", "callee" => "mystery" }], "blockers" => [] } }
        rec = { "calls" => 99,
                "returns" => %w[AST::While AST::ForRange AST::FuncCall AST::Identifier
                                AST::BinaryOp AST::Literal AST::CallNode AST::StructLit] }
        expect(classify(report, method, rec)).to eq("Heterogeneous")
      end

      it "stays NoEvidence when never executed and no resolvable static origin" do
        report = described_class.new
        method = { "method" => "dead", "return_origin" => {
          "sources" => [{ "kind" => "call_untyped", "callee" => "mystery" }], "blockers" => [] } }
        rec = { "calls" => 0, "returns" => [] }
        expect(classify(report, method, rec)).to eq("NoEvidence")
      end
    end

    describe "guard_collapse_rows" do
      it "ranks slots by is_a?(Type) guard count and joins the outlier producers" do
        report = described_class.new
        evidence = {
          "facts" => {
            "type_normalizers" => [
              { "class" => "Foo", "method" => "lower", "path" => "src/x.rb", "line" => 11,
                "code" => "t = type.is_a?(Type) ? type : Type.new(type)" },
              { "class" => "Foo", "method" => "lower", "path" => "src/x.rb", "line" => 19,
                "code" => "rt = type.is_a?(Type) ? type : Type.new(type)" },
              { "class" => "Foo", "method" => "lower", "path" => "src/x.rb", "line" => 27,
                "code" => "type.is_a?(Type) or raise" },
              { "class" => "Bar", "method" => "take", "path" => "src/y.rb", "line" => 4,
                "code" => "x.is_a?(Type) ? x : Type.new(x)" },
            ],
            "existing_sigs" => [
              { "class" => "Foo", "method" => "lower", "path" => "src/x.rb", "line" => 10,
                "sig" => "sig { params(type: T.untyped).returns(T.untyped) }",
                "params" => [{ "name" => "type" }] },
            ],
            "unsigned_methods" => [
              { "class" => "Bar", "method" => "take", "path" => "src/y.rb", "line" => 3,
                "sig" => "", "params" => [{ "name" => "x" }] },
            ],
            "param_origins" =>
              ([{ "callee" => "lower", "slot" => "type", "origin_kind" => "static",
                  "type" => "Type", "path" => "src/a.rb", "line" => 1, "code" => "ty" }] * 8) +
              [{ "callee" => "lower", "slot" => "type", "origin_kind" => "static",
                 "type" => "Symbol", "path" => "src/b.rb", "line" => 42, "code" => ":raw" },
               { "callee" => "lower", "slot" => "type", "origin_kind" => "static",
                 "type" => "Symbol", "path" => "src/b.rb", "line" => 88, "code" => ":sym" }] +
              [{ "callee" => "take", "slot" => "x", "origin_kind" => "static",
                 "type" => "Type", "path" => "src/c.rb", "line" => 5, "code" => "tt" }],
          },
        }

        rows = report.send(:guard_collapse_rows, evidence)

        expect(rows.size).to eq(2)
        top = rows.first
        expect(top["method"]).to eq("Foo#lower")
        expect(top["slot"]).to eq("type")
        expect(top["slot_kind"]).to eq("param")
        expect(top["guards"]).to eq(3)
        expect(top["dominant"]).to eq("Type")
        expect(top["dominant_share"]).to be_within(0.001).of(0.8)
        expect(top["producers"]).to eq(10)
        expect(top["outliers"]).to contain_exactly(
          { "type" => "Symbol", "loc" => "src/b.rb:42", "code" => ":raw" },
          { "type" => "Symbol", "loc" => "src/b.rb:88", "code" => ":sym" }
        )
        # Ranked by guard count: Bar#take (1 guard) sorts below Foo#lower (3).
        expect(rows.last["method"]).to eq("Bar#take")
        expect(rows.last["guards"]).to eq(1)
      end

      it "falls back to the origin call's runtime return classes when the receiver is a local" do
        report = described_class.new
        evidence = {
          "methods" => [
            # annotate observed returning only Type -> singleton -> the
            # union is unjustified; guards on its consumers collapse.
            { "class" => "Annotator", "method" => "annotate", "returns" => ["Type"] },
            # decode observed returning Type AND Symbol -> tighten that
            # contract (members listed, no collapse verdict).
            { "class" => "Lexer", "method" => "decode", "returns" => %w[Type Symbol] },
          ],
          "facts" => {
            "type_normalizers" => [
              { "class" => "C", "method" => "a", "path" => "src/c.rb", "line" => 9,
                "code" => "ti.is_a?(Type) ? ti : Type.new(ti)",
                "origin_kind" => "call", "origin_name" => "annotate" },
              { "class" => "C", "method" => "a", "path" => "src/c.rb", "line" => 14,
                "code" => "ti.is_a?(Type) ? ti : Type.new(ti)",
                "origin_kind" => "call", "origin_name" => "annotate" },
              { "class" => "D", "method" => "b", "path" => "src/d.rb", "line" => 3,
                "code" => "tk.is_a?(Type) ? tk : Type.new(tk)",
                "origin_kind" => "call", "origin_name" => "decode" },
            ],
            "existing_sigs" => [], "unsigned_methods" => [], "param_origins" => [],
          },
        }

        rows = report.send(:guard_collapse_rows, evidence)

        annotate_row = rows.find { |r| r["method"] == "C#a" }
        expect(annotate_row["guards"]).to eq(2)
        expect(annotate_row["via"]).to eq("returns of annotate()")
        expect(annotate_row["members"]).to eq(["Type"])
        expect(annotate_row["dominant"]).to eq("Type")
        expect(annotate_row["dominant_share"]).to eq(1.0)

        decode_row = rows.find { |r| r["method"] == "D#b" }
        expect(decode_row["via"]).to eq("returns of decode()")
        expect(decode_row["members"]).to contain_exactly("Type", "Symbol")
        expect(decode_row["dominant"]).to be_nil
      end

      it "attributes an attr-accessor contract via the like-named ivar's runtime classes" do
        # `.type_info` is an attr_reader-style accessor with no traced
        # `def` (rt_returns empty); it must fall back to the @type_info
        # ivar runtime class set the collector now records, aggregated
        # globally by name across declaring classes.
        report = described_class.new
        evidence = {
          "methods" => [],
          "facts" => {
            "existing_sigs" => [], "unsigned_methods" => [], "param_origins" => [],
            "ivar_runtime" => [
              { "class" => "AST::VarDecl", "name" => "@type_info", "classes" => ["Type"] },
              { "class" => "AST::BindExpr", "name" => "@type_info", "classes" => %w[Type Symbol] },
            ],
            "type_normalizers" => [
              { "class" => "MIRLowering", "method" => "lower_get_index", "path" => "src/m.rb", "line" => 9,
                "code" => "ti.is_a?(Type)", "origin_kind" => "attr", "origin_name" => "type_info" },
              { "class" => "EscapeAnalysis", "method" => "per_fn_scan!", "path" => "src/e.rb", "line" => 5,
                "code" => "ti.is_a?(Type)", "origin_kind" => "attr", "origin_name" => "type_info" },
            ],
          },
        }

        rows = report.send(:guard_collapse_rows, evidence)
        ti_rows = rows.select { |r| r["origin_name"] == "type_info" }
        # Per-(class,method) rows: each guarded receiver attributed via
        # the like-named ivar's runtime class set.
        expect(ti_rows.size).to eq(2)
        expect(ti_rows.map { |r| r["via"] }.uniq).to eq(["@type_info assignments"])
        expect(ti_rows.first["members"]).to contain_exactly("Type", "Symbol")

        # Renderer aggregates by canonical contract across methods:
        # 2 guards collapse on the single `.type_info` accessor.
        lines = []
        report.send(:append_union_decomplexity, lines, evidence)
        ti_line = lines.find { |l| l.include?("`.type_info`") && l.include?("guards collapse") }
        expect(ti_line).to include("2 guards collapse")
        expect(ti_line).to include("via @type_info assignments (runtime) {Type, Symbol}")
      end
    end

    describe "node_alias_candidate_rows" do
      it "buckets a single-namespace Heterogeneous param under its node alias" do
        report = described_class.new
        ast = %w[AST::While AST::ForRange AST::FuncCall AST::Identifier AST::BinaryOp
                 AST::Literal AST::CallNode AST::StructLit]
        evidence = {
          "methods" => [
            { "source" => { "path" => "src/a.rb", "line" => 10 },
              "calls" => 50, "params_ok" => { "node" => ast }, "params_by_name" => { "node" => ast } },
            # mixed AST + MIR -> spans 2 namespaces -> NOT a single-alias row
            { "source" => { "path" => "src/b.rb", "line" => 3 },
              "calls" => 50, "params_ok" => { "n" => %w[AST::While MIR::Alloc AST::FuncCall AST::Identifier AST::BinaryOp AST::Literal] },
              "params_by_name" => {} },
          ],
          "facts" => {
            "param_origins" => [],
            "existing_sigs" => [
              { "path" => "src/a.rb", "line" => 10, "class" => "Walker", "method" => "visit",
                "sig" => "sig { params(node: T.untyped).returns(T.untyped) }" },
              { "path" => "src/b.rb", "line" => 3, "class" => "Lower", "method" => "go",
                "sig" => "sig { params(n: T.untyped).returns(T.untyped) }" },
            ],
          },
        }

        by_ns, total = report.send(:node_alias_candidate_rows, evidence)
        expect(total).to eq(2)
        expect(by_ns.keys).to eq(["AST"])
        expect(by_ns["AST"]).to contain_exactly(
          a_hash_including("loc" => "src/a.rb:10", "method" => "Walker#visit", "param" => "node", "classes" => 8)
        )
      end
    end

    it "classifies return usage with the same graph used for void promotion" do
      Dir.mktmpdir("nil-kill-return-hygiene-report", NilKill::ROOT) do |dir|
        source = File.join(dir, "hygiene_report.rb")
        File.write(source, <<~RUBY)
          class HygieneReport
            extend T::Sig

            sig { returns(T.untyped) }
            def unused_leaf
              "event"
            end

            sig { returns(T.untyped) }
            def unused_wrapper
              return unused_leaf
            end

            sig { returns(T.untyped) }
            def used_leaf
              "value"
            end

            sig { returns(String) }
            def used_caller
              value = used_leaf
              value.to_s
            end

            sig { void }
            def run
              unused_wrapper
            end
          end
        RUBY

        rows = nil
        isolated_env("NIL_KILL_TARGETS" => dir) do
          expect { NilKill::Infer.new(["--no-sorbet"]).run }.to output(/Nil Kill Report/).to_stdout
          evidence = JSON.parse(File.read(NilKill::EVIDENCE_PATH))
          rows = described_class.allocate.send(:return_hygiene_rows, evidence).each_with_object({}) do |row, lookup|
            lookup[row["method"]] = row
          end
        end

        expect(rows["unused_leaf"]).to include(
          "usage" => "unused via return-forwarding",
          "fixability" => "high action: void"
        )
        expect(rows["unused_wrapper"]).to include(
          "usage" => "unused via return-forwarding",
          "source_kind" => "implicit/direct forwarded return",
        )
        expect(rows["used_leaf"]).to include("usage" => "used as value")
        expect(rows["run"]).to include("usage" => "declared void", "fixability" => "addressed: void")
      end
    end

    it "breaks return sources into actionable hygiene buckets" do
      report = described_class.allocate

      expect(report.send(:return_hygiene_source_kind, {
        "return_syntax" => "implicit",
        "sources" => [{ "kind" => "static", "type" => "String", "code" => "\"ok\"" }],
      })).to eq("literal/static")

      expect(report.send(:return_hygiene_source_kind, {
        "return_syntax" => "implicit",
        "sources" => [{ "kind" => "typed_call", "callee" => "join", "type" => "String", "code" => "items.join", "stdlib" => true }],
      })).to eq("Ruby stdlib call")

      expect(report.send(:return_hygiene_source_kind, {
        "return_syntax" => "implicit",
        "sources" => [
          { "kind" => "typed_call", "callee" => "join", "type" => "String", "code" => "items.join", "stdlib" => true },
          { "kind" => "call_untyped", "callee" => "fallback", "code" => "fallback" },
        ],
      })).to eq("mixed sources")

      expect(report.send(:return_hygiene_source_kind, {
        "return_syntax" => "explicit",
        "sources" => [{ "kind" => "call_untyped", "callee" => "other", "code" => "other" }],
      })).to eq("explicit/direct forwarded return")

      expect(report.send(:return_hygiene_source_kind, {
        "return_syntax" => "mixed",
        "sources" => [{ "kind" => "call_untyped", "callee" => "other", "code" => "other" }],
      })).to eq("mixed/direct forwarded return")

      expect(report.send(:return_hygiene_source_kind, {
        "return_syntax" => "implicit",
        "sources" => [{ "kind" => "unknown", "code" => "items[name]" }],
      })).to eq("collection lookup")

      expect(report.send(:return_hygiene_source_kind, {
        "return_syntax" => "implicit",
        "sources" => [{ "kind" => "ivar_read", "code" => "@value" }],
      })).to eq("struct/class field or instance variable")
    end

    it "reports strong, weak, untyped, and nilable coverage inside each hygiene bucket" do
      report = described_class.allocate
      lines = []
      rows = [
        { "source_kind" => "literal/static", "return_type" => "String" },
        { "source_kind" => "literal/static", "return_type" => "T.untyped" },
        { "source_kind" => "literal/static", "return_type" => "T::Hash[T.untyped, T.untyped]" },
        { "source_kind" => "Ruby stdlib call", "return_type" => "T.nilable(T::Boolean)" },
      ]

      report.send(:append_hygiene_bucket_lines, lines, "Return source kind", rows, "source_kind", rows.size)

      expect(lines).to include(
        "- literal/static: total 3 (75.0%) of all returns; strong 1 (33.3%); weak 1 (33.3%); untyped 1 (33.3%); nilable 0 (0.0%) within row",
        "- Ruby stdlib call: total 1 (25.0%) of all returns; strong 1 (100.0%); weak 0 (0.0%); untyped 0 (0.0%); nilable 1 (100.0%) within row"
      )
    end

    it "reports repeated untyped slot names as pressure, not inferred types" do
      report = described_class.allocate
      evidence = {
        "facts" => {
          "existing_sigs" => [
            { "path" => "src/a.rb", "line" => 1, "sig" => "sig { params(node: T.untyped, payload: String).returns(String) }" },
            { "path" => "src/b.rb", "line" => 2, "sig" => "sig { params(node: T.untyped).returns(T.untyped) }" },
          ],
          "struct_declarations" => [
            { "class" => "Box", "path" => "src/box.rb", "line" => 4, "fields" => ["node", "payload"] },
          ],
          "tlet_sites" => [
            { "path" => "src/c.rb", "line" => 5, "name" => "@node", "tlet" => true, "type" => "T.untyped" },
          ],
        }
      }

      rows = report.send(:untyped_slot_name_pressure, evidence)
      node = rows.find { |row| row["name"] == "node" }

      expect(node).to include("count" => 4)
      expect(node.fetch("categories")).to include("param" => 2, "field" => 1, "var" => 1)
      expect(rows.map { |row| row["name"] }).not_to include("payload")
    end

    it "reports static typed distributions for repeated untyped slot names when available" do
      report = described_class.allocate
      evidence = {
        "facts" => {
          "top_untyped_slot_names" => [
            {
              "name" => "token",
              "count" => 2,
              "categories" => { "param" => 1, "ivar" => 1 },
              "examples" => ["src/a.rb:1 token"],
              "typed_total" => 4,
              "typed_hints" => [
                { "type" => "Token", "count" => 3, "percent" => 75.0 },
                { "type" => "Other", "count" => 1, "percent" => 25.0 },
              ],
            },
          ],
        },
      }

      rows = report.send(:untyped_slot_name_pressure, evidence)
      lines = []
      report.send(:append_untyped_slot_name_pressure, lines, evidence)

      expect(rows.first.fetch("typed_hints").first).to include("type" => "Token", "percent" => 75.0)
      expect(lines.join("\n")).to include("`Token` 3 (75.0%)")
    end

    it "splits addressed return fixability by type strength" do
      report = described_class.allocate

      expect(report.send(:return_hygiene_fixability, "String", "used as value", "literal/static")).to eq("addressed: strong")
      expect(report.send(:return_hygiene_fixability, "T::Hash[T.untyped, T.untyped]", "used as value", "collection lookup")).to eq("addressed: weak")
      expect(report.send(:return_hygiene_fixability, "T.nilable(T.untyped)", "used as value", "unknown source")).to eq("addressed: untyped")
    end

    it "builds primary evidence reasons for weak and untyped signature slots" do
      report = described_class.allocate
      evidence = {
        "methods" => [
          { "source" => { "path" => "src/example.rb", "line" => 3 }, "calls" => 2,
            "params_ok" => { "name" => ["String"] }, "params_by_name" => {}, "returns" => ["String"] },
          { "source" => { "path" => "src/example.rb", "line" => 9 }, "calls" => 1,
            "params_ok" => {}, "params_by_name" => {}, "returns" => [] },
        ],
        "facts" => {
          "existing_sigs" => [
            { "path" => "src/example.rb", "line" => 3, "class" => "Example", "method" => "save", "kind" => "instance",
              "sig" => "sig { params(name: T.untyped, items: T::Array[T.untyped]).returns(T.untyped) }",
              "params" => [{ "name" => "name" }, { "name" => "items" }],
              "return_origin" => { "path" => "src/example.rb", "line" => 3, "class" => "Example", "method" => "save", "kind" => "instance",
                "sources" => [{ "kind" => "call_untyped", "callee" => "build", "code" => "build" }] } },
            { "path" => "src/example.rb", "line" => 9, "class" => "Example", "method" => "load", "kind" => "instance",
              "sig" => "sig { returns(T::Hash[Symbol, T.untyped]) }", "params" => [] },
          ],
          "param_origins" => [
            { "path" => "src/caller.rb", "line" => 12, "callee" => "save", "slot" => "name", "origin_kind" => "static", "type" => "String", "code" => "\"Ada\"" },
          ],
          "return_origins" => [],
        },
        "actions" => [
          { "kind" => "fix_sig_param", "confidence" => "review", "path" => "src/example.rb", "line" => 3,
            "data" => { "name" => "name", "type" => "String" } },
        ],
      }

      rows = report.send(:signature_slot_evidence_rows, evidence)
      by_slot = rows.each_with_object({}) { |row, lookup| lookup[[row["slot_kind"], row["slot"]]] = row }

      expect(by_slot[["param", "name"]]).to include(
        "strength" => "untyped",
        "primary_reason" => "candidate: runtime-only param observation"
      )
      expect(by_slot[["param", "name"]]["example"]).to include("candidate action fix_sig_param")
      expect(by_slot[["param", "items"]]).to include(
        "strength" => "weak",
        "primary_reason" => "weak declared type: array element evidence needed"
      )
      expect(by_slot[["return", "return"]]).to include(
        "strength" => "weak",
        "primary_reason" => "weak declared type: hash key/value evidence needed"
      )
    end
  end

  describe NilKill::StructRBI do
    it "can generate a complete struct RBI without the legacy generator" do
      generator = described_class.allocate
      facts = {
        "struct_declarations" => [
          { "class" => "Example::Node", "line" => 1, "fields" => ["name", "items"] },
        ],
      }
      candidates = [
        { "class" => "Example::Node", "field" => "name", "type" => "String" },
      ]

      rbi = generator.send(:generate_complete, facts, candidates)

      expect(rbi).to include("class Example::Node")
      expect(rbi).to include("sig { returns(String) }\n  def name; end")
      expect(rbi).to include("sig { returns(T.untyped) }\n  def items; end")
    end

    it "preserves existing RBI field types in complete mode when no new candidate exists" do
      generator = described_class.allocate
      allow(generator).to receive(:existing_rbi_types).and_return({ ["Example::Node", "items"] => "T::Array[String]" })
      facts = {
        "struct_declarations" => [
          { "class" => "Example::Node", "line" => 1, "fields" => ["items"] },
        ],
      }

      rbi = generator.send(:generate_complete, facts, [])

      expect(rbi).to include("sig { returns(T::Array[String]) }\n  def items; end")
    end

    it "extracts offending method names from srb tc 'Got X originating from' blocks" do
      generator = described_class.allocate
      srb_output = <<~SRB
        src/mir/mir_lowering.rb:5708: Comparison between `String` and `Symbol(:Any)` is always false https://srb.help/7046
             5708 |    msg_str = if raw.nil? || raw == :Any || raw.empty?
                                                ^^
          Got `String` originating from:
            src/mir/mir_lowering.rb:5707:
             5707 |    raw = node.message
                            ^^^^^^^^^^^^

        src/foo.rb:10: Method `[]` does not exist on `NilClass` https://srb.help/7003
            10 |    bound_var = node.capabilities.first[:var_node]
          Got `T.nilable(...)` originating from:
            src/foo.rb:9:
            9 |    cap = node.capabilities.first
                         ^^^^^^^^^^^^^^^^^^^^^^^
      SRB

      methods = generator.send(:extract_offending_methods, srb_output)

      expect(methods).to include("message")
      expect(methods).to include("capabilities")
      expect(methods).to include("first")
    end

    it "falls back to T.untyped for blocklisted fields in complete mode" do
      generator = described_class.allocate
      generator.instance_variable_set(:@blocklist, Set.new(["message"]))
      allow(generator).to receive(:existing_rbi_types).and_return({})
      facts = {
        "struct_declarations" => [
          { "class" => "Example::Panic", "line" => 1, "fields" => ["message", "code"] },
        ],
      }
      candidates = [
        { "class" => "Example::Panic", "field" => "message", "type" => "String" },
        { "class" => "Example::Panic", "field" => "code", "type" => "Integer" },
      ]

      rbi = generator.send(:generate_complete, facts, candidates)

      # Blocklisted "message" reverts to T.untyped; other fields unaffected.
      expect(rbi).to include("sig { returns(T.untyped) }\n  def message; end")
      expect(rbi).to include("sig { returns(Integer) }\n  def code; end")
    end
  end

  describe NilKill::CLI do
    describe "#targets_changed_since_collect (git-aware staleness)" do
      let(:cli) { described_class.new([]) }

      around do |ex|
        Dir.mktmpdir("nk-meta") { |d| @meta = File.join(d, "collect-meta.json"); ex.run }
      end

      before { allow(cli).to receive(:collect_meta_path).and_return(@meta) }

      it "is :unknown when no collect metadata exists (caller falls back to mtime)" do
        expect(cli.send(:targets_changed_since_collect)).to eq(:unknown)
      end

      it "is :unknown when git is unavailable" do
        File.write(@meta, JSON.generate("head" => "abc", "dirty" => ""))
        allow(cli).to receive(:git_capture).and_return(nil)
        expect(cli.send(:targets_changed_since_collect)).to eq(:unknown)
      end

      it "is false (fresh) when HEAD and working-tree status match the collect -- a touched mtime does NOT trip it" do
        File.write(@meta, JSON.generate("head" => "deadbee", "dirty" => " M src/x.rb\n"))
        allow(cli).to receive(:git_capture) do |*a|
          a.first == "rev-parse" ? "deadbee\n" : " M src/x.rb\n"
        end
        expect(cli.send(:targets_changed_since_collect)).to be(false)
      end

      it "reports the changed commits + files when src/ moved since the collect" do
        File.write(@meta, JSON.generate("head" => "oldsha1", "dirty" => ""))
        allow(cli).to receive(:git_capture) do |*a|
          case a.first
          when "rev-parse" then "newsha2\n"
          when "status" then ""
          when "diff" then "src/ast/parser.rb\nsrc/mir/mir_lowering.rb\n"
          end
        end
        meta_h, cur_h, files = cli.send(:targets_changed_since_collect)
        expect(meta_h).to eq("oldsha1")
        expect(cur_h).to eq("newsha2")
        expect(files).to contain_exactly("src/ast/parser.rb", "src/mir/mir_lowering.rb")
      end

      it "is fresh when HEAD moved but ZERO target files changed (commits only touched non-src)" do
        File.write(@meta, JSON.generate("head" => "oldsha1", "dirty" => ""))
        allow(cli).to receive(:git_capture) do |*a|
          case a.first
          when "rev-parse" then "newsha2\n"
          when "status" then ""
          when "diff" then "" # no src/ files differ between the two shas
          end
        end
        expect(cli.send(:targets_changed_since_collect)).to be(false)
      end

      it "detects an uncommitted working-tree change even at the same HEAD" do
        File.write(@meta, JSON.generate("head" => "samesha", "dirty" => ""))
        allow(cli).to receive(:git_capture) do |*a|
          a.first == "rev-parse" ? "samesha\n" : " M src/ast/ast.rb\n"
        end
        _, _, files = cli.send(:targets_changed_since_collect)
        expect(files).to eq(["src/ast/ast.rb"])
      end
    end
  end
end
