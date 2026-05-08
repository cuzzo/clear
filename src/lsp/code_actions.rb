# typed: true
require_relative "position"
require_relative "diagnostics"

module LSP
  # Converts FixableFinding fixes into LSP CodeActions.
  #
  # The client sends `textDocument/codeAction` with a uri + range.
  # We return every fix attached to a finding whose token range
  # overlaps the requested range. Each CodeAction carries:
  #
  #   - title       — fix.description (shown in the quick-fix menu)
  #   - kind        — 'quickfix' for :auto, 'refactor' for :interactive
  #   - diagnostics — the originating Diagnostic (lets the client
  #                   group actions under their error)
  #   - edit        — a WorkspaceEdit with a TextDocumentEdit array;
  #                   each TextEdit's range comes from the Fix's
  #                   Edit span.
  #   - isPreferred — true for :auto fixes (Neovim picks these by
  #                   default when binding `<leader>ca`).
  #
  # No new analysis runs here. We read from `DocumentStore`'s
  # cached findings, populated by `Server#analyze_and_publish`.
  module CodeActions
    KIND_QUICKFIX = "quickfix".freeze
    KIND_REFACTOR = "refactor".freeze

    module_function

    # Build the CodeAction array for `request_range` against the
    # document. Returns an empty array when there's nothing relevant
    # (no findings, no overlap, or no fixes).
    def for_range(document, request_range)
      return [] unless document
      result = document.cached_findings
      return [] unless result

      source = document.text
      out    = []

      result.findings.each do |finding|
        next if finding.fixes.empty?
        diag = Diagnostics.from_finding(finding, source)
        next unless ranges_overlap?(diag[:range], request_range)

        finding.fixes.each do |fix|
          out << build_action(fix, finding, diag, document, source)
        end
      end

      out
    end

    # ---- internals ----

    def build_action(fix, _finding, diag, document, source)
      kind = fix.confidence == :auto ? KIND_QUICKFIX : KIND_REFACTOR
      edits = fix.edits.map { |e| build_text_edit(e, source) }

      action = {
        title:       fix.description,
        kind:        kind,
        diagnostics: [diag],
        edit: {
          documentChanges: [
            {
              textDocument: { uri: document.uri, version: document.version },
              edits:        edits,
            },
          ],
        },
      }
      action[:isPreferred] = true if fix.confidence == :auto
      action
    end

    # Convert a Fix's Edit (line/col/length-based) into an LSP
    # TextEdit (range/newText).
    def build_text_edit(edit, source)
      {
        range:   Position.range_for_span(edit.span, source),
        newText: edit.replacement,
      }
    end

    # LSP range overlap. Two ranges overlap unless one ends strictly
    # before the other begins. Each range is `{start: {line, character},
    # end: {line, character}}`. Compare via `<=>` since Array#<
    # isn't defined.
    def ranges_overlap?(a, b)
      return false if (range_position(a, :end) <=> range_position(b, :start)) < 0
      return false if (range_position(b, :end) <=> range_position(a, :start)) < 0
      true
    end

    # Pack a range's start or end into a comparable [line, char]
    # tuple. Tolerates string-keyed positions from the LSP wire.
    def range_position(range, side)
      pos = range[side]
      pos ||= range[side.to_s]
      [pos[:line] || pos["line"], pos[:character] || pos["character"]]
    end
  end
end
