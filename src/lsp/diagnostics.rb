# typed: true
require_relative "position"
require_relative "../ast/diagnostic_registry"

module LSP
  # Converts CLEAR's FixableFinding (and synthetic findings from the
  # Analyzer) into LSP `Diagnostic` objects. The output shape matches
  # the LSP 3.17 spec: severity (1-4), range (start/end with UTF-16
  # character offsets), code, source, message, and optional related
  # information.
  #
  # The `code` field is the registry symbol when we can recover it —
  # we look up the registered template against the message text. For
  # synthetic errors (ParserError / unrecoverable CompilerError), we
  # leave `code` nil and just surface the message.
  module Diagnostics
    # LSP DiagnosticSeverity values.
    SEVERITY_ERROR   = 1
    SEVERITY_WARNING = 2
    SEVERITY_INFO    = 3
    SEVERITY_HINT    = 4

    SEVERITY_FOR_LEVEL = {
      error:   SEVERITY_ERROR,
      warning: SEVERITY_WARNING,
      info:    SEVERITY_INFO,
      hint:    SEVERITY_HINT,
    }.freeze

    SOURCE_NAME = "clear".freeze

    module_function

    # Convert a single FixableFinding (or synthetic equivalent) to an
    # LSP Diagnostic hash. `source_text` is optional — when provided,
    # we compute exact UTF-16 column offsets for tokens that span
    # multi-byte characters.
    def from_finding(finding, source_text = nil)
      tok    = finding.token
      length = token_length(tok)
      range  = Position.range_for(tok, length, source_text)

      {
        range:    range,
        severity: SEVERITY_FOR_LEVEL.fetch(finding.level, SEVERITY_ERROR),
        source:   SOURCE_NAME,
        message:  finding.message.to_s,
        code:     code_for(finding),
      }.compact
    end

    # Convert a list of findings + an optional fatal error into the
    # array of Diagnostics for a single document.
    def from_result(result, source_text = nil)
      diags = result.findings.map { |f| from_finding(f, source_text) }
      diags << from_finding(result.fatal_error, source_text) if result.fatal?
      diags
    end

    # ---- internals ----

    # The token's length in bytes. CLEAR tokens carry a `value` (the
    # parsed lexeme); its byte size is the column-extent. Synthetic
    # tokens may have an empty value — we floor at 1 so the squiggle
    # is at least one character wide.
    def token_length(tok)
      val = tok.value
      len = val.is_a?(String) ? val.bytesize : 1
      len <= 0 ? 1 : len
    end

    # Try to recover the registry code from a finding's message. The
    # registry stores templates with `%{name}` placeholders; we
    # extract the literal-prefix of each template (everything before
    # the first placeholder) and check if the message starts with it.
    # First match wins. This is best-effort — exact backwards mapping
    # is tricky because messages built via DiagnosticRegistry.format
    # don't carry their code at the call site.
    def code_for(finding)
      msg = finding.message.to_s
      return nil if msg.empty?

      DiagnosticRegistry::DIAGNOSTICS.each do |code, entry|
        template = entry[:template]
        next unless template
        prefix = template.split(/%\{[^}]+\}/, 2).first.to_s
        # Skip umbrella templates like "%{message}" (prefix is empty).
        next if prefix.empty?
        # Strip trailing punctuation/whitespace for a slightly looser
        # match — the template's prefix often ends mid-word.
        return code.to_s if msg.start_with?(prefix)
      end
      nil
    end
  end
end
