# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe NilKill::StaticDiffAudit do
  def audit_for(rel, source, added)
    Dir.mktmpdir("nil-kill-static-diff-audit", File.join(NilKill::ROOT, "tmp")) do |dir|
      path = File.join(dir, rel)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, source)
      audit = described_class.new(root: dir, added_lines: { rel => added.to_set })
      return [audit.findings.map(&:to_h), path]
    end
  end

  it "flags added src methods without signatures and signatures with erased types" do
    erased_type = "T." + "untyped"
    findings, = audit_for("src/static_diff_methods.rb", <<~RUBY, [2, 6])
      class StaticDiffMethods
        def missing(value)
          value
        end
        sig { params(value: #{erased_type}).returns(String) }
        def erased(value)
          value.to_s
        end
      end
    RUBY

    expect(findings).to include(a_hash_including(
      "kind" => "missing_sig",
      "path" => include("src/static_diff_methods.rb"),
      "line" => 2
    ))
    expect(findings).to include(a_hash_including(
      "kind" => "untyped_sig",
      "path" => include("src/static_diff_methods.rb"),
      "line" => 6
    ))
  end

  it "flags added untyped ivars, weak collection types, and hash record candidates" do
    erased_type = "T." + "untyped"
    findings, = audit_for("src/static_diff_state.rb", <<~RUBY, [5, 6, 7, 8])
      class StaticDiffState
        extend T::Sig

        def initialize
          @cache = {}
          @typed = T.let({}, T::Hash[String, Integer])
          list = T.let([], T::Array[#{erased_type}])
          record = {name: "n", value: 1}
        end
      end
    RUBY

    expect(findings).to include(a_hash_including("kind" => "untyped_ivar", "line" => 5))
    expect(findings).not_to include(a_hash_including("kind" => "untyped_ivar", "line" => 6))
    expect(findings).to include(a_hash_including("kind" => "untyped_array", "line" => 7))
    expect(findings).to include(a_hash_including("kind" => "hash_record_candidate", "line" => 8))
  end

  it "accepts multiline signatures on added methods" do
    findings, = audit_for("src/static_diff_multiline_sig.rb", <<~RUBY, [7])
      class StaticDiffMultilineSig
        extend T::Sig

        sig do
          params(value: String).returns(String)
        end
        def signed(value)
          value
        end
      end
    RUBY

    expect(findings).not_to include(a_hash_including("kind" => "missing_sig", "line" => 7))
  end

  it "accepts long multiline signatures on added methods" do
    findings, = audit_for("src/static_diff_long_multiline_sig.rb", <<~RUBY, [17])
      class StaticDiffLongMultilineSig
        extend T::Sig

        sig do
          params(
            a: String,
            b: String,
            c: String,
            d: String,
            e: String,
            f: String,
            g: String,
            h: String
          ).returns(String)
        end
        def signed(a:, b:, c:, d:, e:, f:, g:, h:)
          [a, b, c, d, e, f, g, h].join
        end
      end
    RUBY

    expect(findings).not_to include(a_hash_including("kind" => "missing_sig", "line" => 17))
  end

  it "does not flag later writes to ivars initialized with concrete T.let types" do
    findings, = audit_for("src/static_diff_typed_state.rb", <<~RUBY, [7])
      class StaticDiffTypedState
        extend T::Sig

        def initialize
          @cache = T.let({}, T::Hash[String, Integer])
        end

        def reset
          @cache = {}
        end
      end
    RUBY

    expect(findings).not_to include(a_hash_including("kind" => "untyped_ivar", "line" => 7))
  end

  it "does not flag moved module writes to ivars typed elsewhere in src" do
    Dir.mktmpdir("nil-kill-static-diff-audit", File.join(NilKill::ROOT, "tmp")) do |dir|
      FileUtils.mkdir_p(File.join(dir, "src/annotator/domains"))
      File.write(File.join(dir, "src/annotator/annotator.rb"), <<~RUBY)
        class SemanticAnnotator
          def initialize
            @branch_terminated = T.let(false, T::Boolean)
          end
        end
      RUBY
      File.write(File.join(dir, "src/annotator/domains/control_flow.rb"), <<~RUBY)
        module Annotator
          module Domains
            module ControlFlow
              def reset_branch
                @branch_terminated = false
              end
            end
          end
        end
      RUBY

      audit = described_class.new(
        root: dir,
        added_lines: { "src/annotator/domains/control_flow.rb" => [5].to_set }
      )
      findings = audit.findings.map(&:to_h)
      expect(findings).not_to include(a_hash_including("kind" => "untyped_ivar", "line" => 5))
    end
  end

  it "does not flag initialize_copy reassignments for ivars typed in initialize" do
    findings, = audit_for("src/static_diff_copy_state.rb", <<~RUBY, [9])
      class StaticDiffCopyState
        extend T::Sig

        def initialize
          @flow = T.let(Flow.new, Flow)
        end

        def initialize_copy(original)
          @flow = original.flow_snapshot
        end
      end
    RUBY

    expect(findings).not_to include(a_hash_including("kind" => "untyped_ivar", "line" => 9))
  end

  it "does not treat homogeneous lookup maps as hash records" do
    findings, = audit_for("src/static_diff_lookup_map.rb", <<~RUBY, [5])
      class StaticDiffLookupMap
        extend T::Sig

        NAMES = T.let({
          one: "one",
          two: "two",
        }.freeze, T::Hash[Symbol, String])
      end
    RUBY

    expect(findings).not_to include(a_hash_including("kind" => "hash_record_candidate", "line" => 5))
  end

  it "does not treat hash-rocket symbol lookup maps as hash records" do
    findings, = audit_for("src/static_diff_hash_rocket_lookup_map.rb", <<~RUBY, [5])
      class StaticDiffHashRocketLookupMap
        extend T::Sig

        CAPABILITIES = T.let({
          "@shared" => :shared,
          "@multiowned" => :multiowned,
        }.freeze, T::Hash[String, Symbol])
      end
    RUBY

    expect(findings).not_to include(a_hash_including("kind" => "hash_record_candidate", "line" => 5))
  end

  it "does not treat typed struct value maps as hash records" do
    findings, = audit_for("src/static_diff_struct_map.rb", <<~RUBY, [10])
      class StaticDiffStructMap
        extend T::Sig

        class Entry < T::Struct
          const :name, String
        end

        ENTRIES = T.let({
          one: Entry.new(name: "one"),
          two: Entry.new(name: "two"),
        }.freeze, T::Hash[Symbol, Entry])
      end
    RUBY

    expect(findings).not_to include(a_hash_including("kind" => "hash_record_candidate", "line" => 10))
  end
end
