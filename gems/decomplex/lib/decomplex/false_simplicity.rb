# frozen_string_literal: true

require "set"
require_relative "syntax"

module Decomplex
  # False simplicity: code whose local syntax understates non-local behavior.
  #
  # The detector does not mine language grammar directly. Production scanning
  # consumes Syntax::Document semantic effect sites and owner/function facts;
  # language adapters own language-specific effect lexicons and syntax quirks.
  class FalseSimplicity
    Hit = Struct.new(:kind, :detail, :file, :defn, :line, :span,
                     keyword_init: true)
    ClassRec = Struct.new(:name, :file, :line, :core, :span,
                          keyword_init: true)

    def self.scan(files)
      hits = []
      recs = []
      files.each do |file|
        document = Syntax.parse(file, parser: "tree_sitter")
        hits.concat(hits_for_document(document))
        doc_recs, doc_hits = class_records_for_document(document)
        recs.concat(doc_recs)
        hits.concat(doc_hits)
      end
      Report.new(hits, recs)
    end

    def self.hits_for_document(document)
      document.semantic_effect_sites.map do |site|
        defn = site.function.to_s.empty? ? "(top-level)" : site.function
        Hit.new(kind: site.kind, detail: site.detail, file: site.file,
                defn: defn, line: site.line,
                span: site.span)
      end
    end

    def self.class_records_for_document(document)
      function_owners = document.function_defs.map(&:owner).compact.to_set
      core_names = core_owner_names(document.language)
      recs = []
      hits = []
      document.owner_defs.each do |owner|
        canonical = owner.name.to_s.sub(/\A::/, "")
        next if canonical.empty?
        next unless function_owners.include?(owner.name) || function_owners.include?(canonical)

        simple = canonical.split("::").last
        core = !canonical.include?("::") && core_names.include?(simple)
        rec = ClassRec.new(name: canonical, file: owner.file, line: owner.line,
                           core: core, span: owner.span)
        recs << rec
        next unless core

        hits << Hit.new(kind: :monkeypatch, detail: simple, file: owner.file,
                        defn: simple, line: owner.line, span: owner.span)
      end
      [recs, hits]
    end

    def self.core_owner_names(language)
      Syntax.core_owner_names(language)
    end

    # Groups hits by [kind, detail] and ranks by blast radius:
    # scatter = distinct (file, method) units, support = occurrences.
    # Cross-file project-class reopen (same FQN with methods in >=2
    # files) becomes monkeypatch hits here; core reopens were already
    # emitted per occurrence during the scan.
    class Report
      def initialize(hits, classrecs)
        @hits = hits.dup
        classrecs.group_by(&:name).each_value do |recs|
          next if recs.first.core
          next if recs.map(&:file).uniq.size < 2

          recs.each do |rec|
            @hits << Hit.new(kind: :monkeypatch, detail: "reopen #{rec.name}",
                             file: rec.file, defn: rec.name, line: rec.line,
                             span: rec.span)
          end
        end
      end

      attr_reader :hits

      def findings
        @hits.group_by { |hit| [hit.kind, hit.detail] }.map do |(kind, detail), hits|
          units = hits.map { |hit| [hit.file, hit.defn] }.uniq
          sites = hits.map { |hit| "#{hit.file}:#{hit.defn}:#{hit.line}" }.uniq
          spans = {}
          hits.each { |hit| spans["#{hit.file}:#{hit.defn}:#{hit.line}"] ||= hit.span }
          { kind: kind, detail: detail, support: hits.size,
            scatter: units.size, at: sites.first, sites: sites, spans: spans }
        end.sort_by { |hit| [-hit[:scatter], -hit[:support], hit[:kind].to_s, hit[:detail]] }
      end
    end
  end
end
