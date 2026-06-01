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
end
