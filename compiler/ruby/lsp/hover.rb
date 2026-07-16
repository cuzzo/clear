# typed: strict
require "sorbet-runtime"
require_relative "rpc"
require_relative "position"
require_relative "diagnostics"
require_relative "document_store"
require_relative "../ast/diagnostic_registry"
require_relative "../ast/diagnostic_examples"

module LSP
  # `textDocument/hover` handler.
  #
  # The MVP version is diagnostic-driven: when the cursor sits on a
  # token that has an active diagnostic, we render the registered
  # template's metadata (summary / cause / fix_hint) plus any worked
  # example pulled from `spec/error_emission_coverage_spec.rb` via
  # DiagnosticExamples.
  #
  # Returns an LSP `Hover` object — `{contents:, range:}` — or nil
  # when there's nothing to show. nil tells the client to dismiss
  # the hover popup.
  #
  # Identifier-based hover (signature, type, doc-string of any
  # symbol at the cursor) is a follow-up; the registry path covers
  # the highest-value case first.
  module Hover
    extend T::Sig
    HoverResponse = T.type_alias { RPC::OutboundMessage }
    FindingLike = T.type_alias { T.untyped }
    LspPosition = T.type_alias { Position::WirePositionHash }


    # Build a hover response for the document at `position`. Returns
    # nil when no diagnostic overlaps the cursor.
    sig { params(document: T.nilable(DocumentStore::Document), position: LspPosition).returns(T.nilable(HoverResponse)) }
    def self.render(document, position)
      return nil unless document
      result = document.cached_findings
      return nil unless result.is_a?(LSP::AnalysisResult)

      source = document.text
      finding = find_overlapping(result, position, source)
      return nil unless finding

      diag = Diagnostics.from_finding(finding, source)
      code = diag[:code]&.to_sym
      entry = code ? DiagnosticRegistry.lookup(code) : nil
      example = code ? DiagnosticExamples.lookup(code) : nil

      {
        contents: { kind: "markdown", value: build_markdown(diag, entry, example) },
        range:    diag[:range],
      }
    end

    # ---- internals ----

    # Find the most-relevant finding for the cursor position. We try
    # two passes: first an exact range overlap (so the squiggled
    # token always wins when the cursor is on it), then a same-line
    # fallback so the user gets hover anywhere on a line that has a
    # diagnostic. Without the fallback, diagnostics whose range is
    # narrow (e.g. a 2-char `->` arrow anchor used by some fixable
    # findings to position their edit) make hover effectively
    # invisible — the user would have to pinpoint the cursor on the
    # exact token to see anything.
    sig { params(result: LSP::AnalysisResult, position: LspPosition, source: String).returns(T.nilable(FindingLike)) }
    def self.find_overlapping(result, position, source)
      candidates = result.findings.dup
      candidates << T.must(result.fatal_error) if result.fatal?

      # Pass 1 — strict range overlap. Wins for every finding whose
      # token squigglesthe cursor sits on.
      strict = candidates.find do |f|
        diag = Diagnostics.from_finding(f, source)
        Position.position_in_range?(position, diag[:range])
      end
      return strict if strict

      # Pass 2 — same-line fallback. Pick the finding whose start
      # column is nearest the cursor's column on the same line, so
      # the user can hover anywhere on the line and get something
      # relevant.
      cursor_line = position_component(position, :line)
      cursor_char = position_component(position, :character)
      same_line = candidates.filter_map do |f|
        diag = Diagnostics.from_finding(f, source)
        next nil unless diag[:range][:start][:line] == cursor_line
        [f, (diag[:range][:start][:character] - cursor_char).abs]
      end
      return nil if same_line.empty?
      T.must(same_line.min_by { |_, dist| dist }).first
    end

    sig { params(position: LspPosition, key: Symbol).returns(Integer) }
    def self.position_component(position, key)
      T.must(position[key] || position[key.to_s])
    end

    sig do
      params(
        diag: RPC::OutboundMessage,
        entry: T.nilable(DiagnosticRegistry::DiagnosticEntry),
        example: T.nilable(DiagnosticExamples::Example),
      ).returns(String)
    end
    def self.build_markdown(diag, entry, example)
      lines = []
      lines << header_line(diag, entry)
      lines << ""
      lines << (entry && entry[:summary] ? entry[:summary] : diag[:message])

      if entry && entry[:cause]
        lines << ""
        lines << "**Cause:** #{entry[:cause]}"
      end

      if entry && entry[:fix_hint]
        lines << ""
        lines << "**Fix:** #{entry[:fix_hint]}"
      end

      if example
        bad = T.cast(example[:bad], T.nilable(String))
        fix = T.cast(example[:fix], T.nilable(String))
        good = T.cast(example[:good], T.nilable(String))
        if bad
          lines << ""
          lines << "**Example (bad):**"
          lines << "```clear"
          lines << bad.rstrip
          lines << "```"
        end
        if fix && !fix.empty?
          lines << ""
          lines << "**Fix prose:** #{fix.gsub("\n", " ")}"
        end
        if good
          lines << ""
          lines << "**Example (good):**"
          lines << "```clear"
          lines << good.rstrip
          lines << "```"
        end
      end

      lines.join("\n")
    end

    sig { params(diag: RPC::OutboundMessage, entry: T.nilable(DiagnosticRegistry::DiagnosticEntry)).returns(String) }
    def self.header_line(diag, entry)
      severity = severity_label(diag[:severity])
      code     = diag[:code]
      if code && entry
        "**[#{severity}] #{code}**  _#{entry[:category]}_"
      elsif code
        "**[#{severity}] #{code}**"
      else
        "**[#{severity}]**"
      end
    end

    SEVERITY_LABELS = T.let({
      Diagnostics::SEVERITY_ERROR   => "error",
      Diagnostics::SEVERITY_WARNING => "warning",
      Diagnostics::SEVERITY_INFO    => "info",
      Diagnostics::SEVERITY_HINT    => "hint",
    }.freeze, T::Hash[Integer, String])

    sig { params(severity: Integer).returns(String) }
    def self.severity_label(severity)
      SEVERITY_LABELS.fetch(severity, "error")
    end
  private_class_method :build_markdown
  private_class_method :find_overlapping
  private_class_method :header_line
  private_class_method :position_component
  private_class_method :severity_label

end
end
