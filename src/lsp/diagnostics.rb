# typed: strict
require "sorbet-runtime"
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
    extend T::Sig
    # LSP DiagnosticSeverity values.
    SEVERITY_ERROR   = 1
    SEVERITY_WARNING = 2
    SEVERITY_INFO    = 3
    SEVERITY_HINT    = 4

    SEVERITY_FOR_LEVEL = T.let({
      error:   SEVERITY_ERROR,
      warning: SEVERITY_WARNING,
      info:    SEVERITY_INFO,
      hint:    SEVERITY_HINT,
    }.freeze, T::Hash[Symbol, Integer])

    SOURCE_NAME = T.let("clear".freeze, String)
    TemplateRegexCache = T.type_alias { T::Hash[String, Regexp] }
    TEMPLATE_REGEX_CACHE = T.let({}, TemplateRegexCache)


    # Convert a single FixableFinding (or synthetic equivalent) to an
    # LSP Diagnostic hash. `source_text` is optional — when provided,
    # we compute exact UTF-16 column offsets for tokens that span
    # multi-byte characters.
    sig { params(finding: T.untyped, source_text: T.untyped).returns(T.untyped) }
    def self.from_finding(finding, source_text = nil)
      tok    = finding.token
      length = token_length(tok, source_text)
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
    sig { params(result: T.untyped, source_text: T.untyped).returns(T.untyped) }
    def self.from_result(result, source_text = nil)
      diags = result.findings.map { |f| from_finding(f, source_text) }
      diags << from_finding(result.fatal_error, source_text) if result.fatal?
      diags
    end

    # ---- internals ----

    # PARSED lexeme), so for STRING tokens it lacks the surrounding
    # quotes and for numeric tokens it's an Integer/Float (whose
    # `to_s` undershoots when the source had separators, a hex/oct/bin
    # prefix, or a type suffix). When `source_text` is provided, scan
    # the source line at tok.column to recover the true byte span;
    # otherwise fall back to a quote-aware heuristic.
    sig { params(tok: T.untyped, source_text: T.untyped).returns(Integer) }
    def self.token_length(tok, source_text = nil)
      val = tok.respond_to?(:value) ? tok.value : nil
      if source_text && tok.respond_to?(:line) && tok.respond_to?(:column)
        if tok.line && tok.column && (line = source_text.lines[tok.line - 1])
          # Token columns are 1-based byte offsets; slice by bytes so
          # multi-byte chars earlier on the line don't shift the index.
          rest = line.byteslice(tok.column - 1, line.bytesize)
          span = literal_span_in(rest)
          return span if span
        end
      end
      fallback_token_length(val)
    end

    # Scan a source slice (starting at the token's column) for the
    # token's textual span. Returns nil when the slice doesn't begin
    # with a recognizable literal — caller falls back.
    sig { params(rest: T.untyped).returns(T.nilable(Integer)) }
    def self.literal_span_in(rest)
      return nil if rest.nil? || rest.empty?
      if rest.start_with?('"""')
        idx = rest.index('"""', 3)
        return idx ? idx + 3 : nil
      end
      if rest.start_with?('"')
        i = 1
        while i < rest.length
          ch = rest[i]
          break if ch == '"'
          i += 1 if ch == '\\' && i + 1 < rest.length
          i += 1
        end
        return i + 1
      end
      m = rest.match(/\A[\d_a-zA-Z.]+/)
      m ? m[0].length : nil
    end

    sig { params(val: T.untyped).returns(Integer) }
    def self.fallback_token_length(val)
      case val
      when String
        len = val.bytesize
        len <= 0 ? 1 : len
      when Integer, Float
        len = val.to_s.length
        len <= 0 ? 1 : len
      else
        1
      end
    end

    # Try to recover the registry code from a finding's message. The
    # registry stores templates with `%{name}` placeholders; we turn
    # each template into an anchored regex (placeholders -> `.+?`) and
    # match the message against it. Templates can share a literal
    # prefix (e.g. CAP_FIELD_NEEDS_WITH_EXCLUSIVE / _SNAPSHOT both
    # start with "Cannot read field '"), so a prefix-only match would
    # mis-stamp; full-template matching disambiguates on the trailing
    # literal segments.
    sig { params(finding: T.untyped).returns(T.nilable(String)) }
    def self.code_for(finding)
      msg = finding.message.to_s
      return nil if msg.empty?

      DiagnosticRegistry::DIAGNOSTICS.each do |code, entry|
        template = entry[:template]
        next unless template
        # Skip umbrella templates whose body is a single placeholder
        # (e.g. "%{message}") — they'd match anything.
        next if template.start_with?('%{') && template.end_with?('}') && template.count('%') == 1
        return code.to_s if msg.match?(template_regex(template))
      end
      nil
    end

    # Convert a registry template into an anchored regex: literal
    # segments are escaped, `%{name}` placeholders become `.+?`, and
    # `.` matches newlines so multi-line messages still match.
    # Strip trailing punctuation/whitespace from the literal tail
    # before anchoring — emitters sometimes drop the template's final
    # `.` (e.g. "Undefined variable '%{name}'." -> message ends in
    # `'doesNotExist'`).
    sig { params(template: T.untyped).returns(Regexp) }
    def self.template_regex(template)
      cache = TEMPLATE_REGEX_CACHE
      cache[template] ||= begin
        parts = template.split(/(%\{[^}]+\})/)
        body = parts.map { |p| p.start_with?('%{') ? '.+?' : Regexp.escape(p) }.join
        body = body.sub(/(?:\\\.|\\!|\\\?|\s)+\z/, '')
        Regexp.new('\A' + body + '[.!?\s]*\z', Regexp::MULTILINE)
      end
    end

    private_class_method :template_regex
  private_class_method :code_for
  private_class_method :fallback_token_length
  private_class_method :literal_span_in
  private_class_method :token_length

end
end
