# frozen_string_literal: true

require_relative "coverage_data"
require_relative "lexicon"

module SlopCop
  # Classifies every never-taken branch arm in a target file into ONE
  # actionable category. Parser-structural, with language text
  # patterns supplied by Decomplex::Syntax lexicons. General -- no
  # project lexicon baked in (see ffi_boundary:).
  #
  # Categories (not all gaps are equal):
  #   :type_norm  arm/decision guards a language-profile type/null
  #               check. Likely dead if runtime contracts were stricter.
  #   :dead       no sibling arm of the decision is ever taken in the
  #               supplied coverage. Audit as unexercised code: it may
  #               be a missing test, or dead only if static reachability
  #               tools agree.
  #   :defensive  live decision, inert/pinned polarity (empty else,
  #               nil, invariant-guaranteed). Accept.
  #   :ffi        a caller-declared external/boundary method -> needs
  #               an integration test.
  #   :diagnostic arm emits a language diagnostic or calls
  #               caller-declared diagnostic helpers ->
  #               invalid-input only.
  #   :genuine    live, reachable, input-determined, none of the above.
  #               The real gap. Ranked by fix-churn downstream.
  module Classifier
    # The gem ships NO project lexicon -- it is general. The consuming
    # project supplies its external/boundary method names via
    # `ffi_boundary:` (CLEAR passes its set from the CLI). Empty here
    # by design.
    Arm = Struct.new(:file, :defn, :line, :span, :decision_span, :category, :source, keyword_init: true)

    module_function

    def merged_branches(resultset, abspath, root: nil)
      coverage_for(resultset, abspath, root: root)&.branches || {}
    end

    # -> [Arm, ...] for every dark arm in abspath.
    def classify_file(resultset, abspath, ffi_boundary: [], diagnostic_mids: [], root: nil, decomplex_verdict: nil)
      file_coverage = coverage_for(resultset, abspath, root: root)
      if tree_sitter_coverage_file?(abspath, file_coverage)
        return classify_coverage_file(
          abspath,
          file_coverage,
          ffi_boundary: ffi_boundary,
          diagnostic_mids: diagnostic_mids,
          decomplex_verdict: decomplex_verdict
        )
      end

      return classify_static_file(abspath,
                                  ffi_boundary: ffi_boundary,
                                  diagnostic_mids: diagnostic_mids,
                                  decomplex_verdict: decomplex_verdict) if tree_sitter_source?(abspath)

      []
    end

    def coverage_for(resultset, abspath, root: nil)
      return nil unless resultset

      root ||= File.dirname(abspath)
      coverage_dataset(resultset, root: root)[abspath]
    rescue StandardError
      nil
    end

    def coverage_dataset(resultset, root:)
      @coverage_cache ||= {}
      key = [File.expand_path(resultset), File.expand_path(root)]
      @coverage_cache[key] ||= SlopCop::CoverageData.load(resultset, root: root)
    end

    def classify_static_file(abspath, ffi_boundary: [], diagnostic_mids: [], decomplex_verdict: nil)
      return [] unless tree_sitter_source?(abspath)

      arms = get_branch_arms(abspath, decomplex_verdict: decomplex_verdict)
      lexicon = SlopCop.language_lexicon(language_for(abspath))
      arms.filter_map do |arm|
        cat = categorize_text(
          arm.fetch("function"),
          arm.fetch("kind").to_sym,
          arm.fetch("body"),
          true,
          arm.fetch("predicate"),
          ffi_boundary,
          diagnostic_mids,
          lexicon: lexicon
        )
        next if cat.nil?

        Arm.new(file: abspath, defn: arm.fetch("function"), line: arm.fetch("line"),
                span: arm.fetch("span"), decision_span: arm.fetch("decision_span"),
                category: cat, source: :tree_sitter_static)
      end
    rescue StandardError => e
      warn "SlopCop::Classifier.classify_static_file error: #{e.message}"
      []
    end

    def classify_coverage_file(abspath, file_coverage, ffi_boundary: [], diagnostic_mids: [], decomplex_verdict: nil)
      return [] unless tree_sitter_source?(abspath)

      arms = get_branch_arms(abspath, decomplex_verdict: decomplex_verdict)
      lexicon = SlopCop.language_lexicon(language_for(abspath))
      
      doc_arms = arms.map do |arm|
        Struct.new(:file, :function, :kind, :line, :span, :decision_line, :decision_span, :predicate, :member, :body, keyword_init: true).new(
          file: arm.fetch("file", abspath),
          function: arm.fetch("function"),
          kind: arm.fetch("kind").to_sym,
          line: arm.fetch("line"),
          span: arm.fetch("span"),
          decision_line: arm.fetch("decision_line", arm.fetch("line")),
          decision_span: arm.fetch("decision_span", arm.fetch("span")),
          predicate: arm.fetch("predicate", ""),
          member: arm.fetch("member", ""),
          body: arm.fetch("body", "")
        )
      end

      covered_arms = SlopCop::CoverageData.branch_arm_coverage(file_coverage, doc_arms)
      groups = covered_arms.group_by do |arm_cov|
        arm = arm_cov.arm
        [arm.kind, arm.decision_line, arm.decision_span]
      end

      covered_arms.filter_map do |arm_cov|
        next if arm_cov.covered

        arm = arm_cov.arm
        group = groups.fetch([arm.kind, arm.decision_line, arm.decision_span], [])
        sibling_taken = group.any?(&:covered)
        cat = categorize_text(
          arm.function,
          arm.kind,
          arm.body,
          sibling_taken,
          arm.predicate,
          ffi_boundary,
          diagnostic_mids,
          lexicon: lexicon
        )
        next if cat.nil?

        Arm.new(file: abspath, defn: arm.function, line: arm.line,
                span: arm.span, decision_span: arm.decision_span,
                category: cat, source: arm_cov.source)
      end
    rescue StandardError => e
      warn "SlopCop::Classifier.classify_coverage_file error: #{e.message}"
      []
    end

    def get_branch_arms(abspath, decomplex_verdict: nil)
      if decomplex_verdict && decomplex_verdict[:branch_arms] && decomplex_verdict[:branch_arms][abspath]
        return decomplex_verdict[:branch_arms][abspath]
      end

      if ENV["DECOMPLEX_FACTS_FILE"] && !ENV["DECOMPLEX_FACTS_FILE"].empty?
        begin
          @facts_file_cache ||= JSON.parse(File.read(ENV["DECOMPLEX_FACTS_FILE"]))
          doc = Array(@facts_file_cache["documents"]).find { |d| File.expand_path(d["file"]) == abspath }
          return doc["branch_arms"] if doc && doc["branch_arms"]
        rescue => e
          warn "Failed to read documents from DECOMPLEX_FACTS_FILE: #{e.message}"
        end
      end

      bin = ENV.fetch("DECOMPLEX_RUST_BINARY", ::File.expand_path("../../../decomplex/target/release/decomplex-rust", __dir__))
      unless ::File.executable?(bin)
        warn "SlopCop::Classifier cannot find executable decomplex-rust at #{bin}"
        return []
      end
      
      lang = language_for(abspath)
      cmd = [bin, "syntax-facts", "--language", lang.to_s, abspath]
      out = IO.popen(cmd, err: [:child, :out]) { |io| io.read }
      raise "decomplex-rust syntax-facts failed: #{out}" unless $?.success?
      
      payload = JSON.parse(out)
      doc = payload.fetch("documents", []).first
      return [] unless doc
      doc.fetch("branch_arms", [])
    end

    def language_for(path)
      ext = ::File.extname(path).downcase
      case ext
      when ".rb" then :ruby
      when ".py" then :python
      when ".js", ".jsx", ".mjs", ".cjs" then :javascript
      when ".java" then :java
      when ".ts", ".tsx" then :typescript
      when ".swift" then :swift
      when ".kt", ".kts" then :kotlin
      when ".go" then :go
      when ".rs" then :rust
      when ".zig" then :zig
      when ".lua" then :lua
      when ".c", ".h" then :c
      when ".cpp", ".cc", ".cxx", ".hpp", ".hh", ".hxx" then :cpp
      when ".cs" then :csharp
      when ".php" then :php
      else nil
      end
    end

    def tree_sitter_source?(abspath)
      lang = language_for(abspath)
      lang && [:ruby, :python, :javascript, :typescript, :go, :rust, :zig, :c, :cpp, :csharp, :java, :kotlin, :swift, :php, :lua].include?(lang)
    end

    def tree_sitter_coverage_file?(abspath, file_coverage)
      return false unless file_coverage && (file_coverage.branch_arm_coverage? || file_coverage.branch_coverage? || file_coverage.line_coverage?)

      tree_sitter_source?(abspath)
    end

    def tree_sitter?
      true
    end

    def categorize_text(method, pkind, body, sibling_taken, predicate = nil,
                        ffi_boundary = [], diagnostic_mids = [],
                        language: :ruby, lexicon: nil)
      lexicon ||= SlopCop.language_lexicon(language)
      return :ffi if ffi_boundary.include?(method)
      return :diagnostic if diagnostic_text?(body, diagnostic_mids, lexicon: lexicon)
      return :type_norm if type_guard_text?(predicate, lexicon: lexicon) ||
                           type_guard_text?(body, allow_literal_nil: false, lexicon: lexicon)
      return :dead unless sibling_taken
      return :defensive if trivial_text?(body, lexicon: lexicon)

      if %i[case if unless ternary while until for loop].include?(pkind)
        :genuine
      else
        :defensive
      end
    end

    def diagnostic_text?(text, diagnostic_mids = [], language: :ruby, lexicon: nil)
      (lexicon || SlopCop.language_lexicon(language)).diagnostic?(
        text,
        extra_names: diagnostic_mids
      )
    end

    def type_guard_text?(text, allow_literal_nil: true, language: :ruby, lexicon: nil)
      (lexicon || SlopCop.language_lexicon(language)).type_guard?(
        text,
        allow_literal_nil: allow_literal_nil
      )
    end

    def trivial_text?(text, language: :ruby, lexicon: nil)
      (lexicon || SlopCop.language_lexicon(language)).trivial?(text)
    end
  end
end
