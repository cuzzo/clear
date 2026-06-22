# typed: false
# frozen_string_literal: true

begin
  require "espalier/static_evidence"
rescue LoadError
  $LOAD_PATH.unshift(File.expand_path("../../../espalier/lib", __dir__))
  require "espalier/static_evidence"
end

module NilKill
  class StaticEvidence
    def self.build(targets = nil, root: NilKill::ROOT, language: nil, vcs: nil)
      evidence = Espalier::StaticEvidence.build(targets, root: root, language: language, vcs: vcs)
      overlay_nil_kill_language_capabilities!(evidence)
      evidence
    end

    def self.overlay_nil_kill_language_capabilities!(evidence)
      return evidence unless defined?(NilKill::Languages)

      languages = Array(evidence.fetch("files", [])).map { |file| file["language"].to_s }
      languages.concat(Hash(evidence["language_capabilities"]).keys)
      evidence["language_capabilities"] = languages.reject(&:empty?).uniq.sort.to_h do |language|
        [language, NilKill::Languages.capability_for(language)]
      end
      evidence
    end
    private_class_method :overlay_nil_kill_language_capabilities!
  end
end
