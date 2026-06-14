# typed: false
# frozen_string_literal: true

module AutoType
  class RewritePlan
    attr_reader :provider, :language, :diagnostics, :text_edits, :legacy_actions, :risk

    def initialize(provider:, language:, supported:, diagnostics: [], text_edits: [], legacy_actions: [],
      risk: "low", requires_verifier: false)
      @provider = provider.to_s
      @language = language.to_s
      @supported = !!supported
      @diagnostics = Array(diagnostics)
      @text_edits = Array(text_edits)
      @legacy_actions = Array(legacy_actions)
      @risk = risk.to_s
      @requires_verifier = !!requires_verifier
    end

    def self.unsupported(provider:, language:, action:, diagnostic:)
      new(
        provider: provider,
        language: language,
        supported: false,
        diagnostics: [diagnostic],
        legacy_actions: [action],
        risk: "unsupported",
        requires_verifier: false,
      )
    end

    def supported?
      @supported
    end

    def requires_verifier?
      @requires_verifier
    end

    def legacy?
      !legacy_actions.empty?
    end

    def edit?
      !text_edits.empty?
    end

    def to_h
      {
        "provider" => provider,
        "language" => language,
        "supported" => supported?,
        "diagnostics" => diagnostics,
        "text_edits" => text_edits.map { |edit| edit.respond_to?(:to_h) ? edit.to_h : edit },
        "legacy_actions" => legacy_actions,
        "risk" => risk,
        "requires_verifier" => requires_verifier?,
      }
    end
  end
end
