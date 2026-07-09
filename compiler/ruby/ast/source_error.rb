# typed: strict
require "sorbet-runtime"

require_relative 'diagnostic_registry'
require_relative 'lexer'

# Diagnostics may be anchored by real lexer tokens or small token-like
# objects from fix/lint tooling that expose line/column.
DiagnosticToken = T.type_alias { T.nilable(T.any(Lexer::Token, Struct, Object)) }

require_relative 'fixable_error'

module ErrorDefinitions
  # Backward-compat view: the legacy `MESSAGES` hash now derives from
  # the unified `DiagnosticRegistry`. Existing call sites that pass a
  # Symbol code to `error!` continue to look up the same templates.
  # Layer 3 will refactor the ~470 ad-hoc string sites to use registry
  # codes too; until then both paths work.
  MESSAGES = T.let(DiagnosticRegistry::DIAGNOSTICS.transform_values { |e| e[:template] }.freeze, T::Hash[Symbol, String])
end

module ErrorHelper
    extend T::Sig

  include ErrorDefinitions

  # usage:
  #   error!(node, :CODE)                              # no args
  #   error!(node, :CODE, key: value, key2: value2)    # named hash
  #   error!(node, :CODE, arg1, arg2)                  # legacy positional
  #   error!(node, "raw string")                       # legacy raw string
  #
  # Named-hash form is preferred for new code. The template uses Ruby's
  # `%{name}` interpolation against the hash. Legacy positional args
  # against `%s`/`%d` still work for the (shrinking) set of templates
  # that haven't been migrated to named form yet.
  sig { params(node_or_token: T.untyped, code_or_message: T.any(String, Symbol), args: String, kwargs: T.untyped).returns(T.noreturn) }
  def error!(node_or_token, code_or_message, *args, **kwargs)
    T.bind(self, T.untyped) rescue nil
    token = diagnostic_token(node_or_token)

    # 2. Determine Message
    if code_or_message.is_a?(Symbol)
      # A. Look up the template
      template = MESSAGES[code_or_message]
      raise "Internal Compiler Error: Unknown error code :#{code_or_message}" unless template

      # B. Format the string. Named-hash form takes priority — if any
      # kwargs were passed OR the template uses `%{name}` placeholders,
      # interpolate via the hash. Positional form is the fallback.
      message = format_diagnostic_template(template, args, kwargs)
    else
      # C. Legacy Support (Raw String)
      message = code_or_message
    end

    # 3. Raise the specific error class
    err_class = self.class.name&.include?("Parser") ? ParserError : CompilerError
    source_token = source_error_token(token)

      raise err_class.new(
        source_token,
        message,
        diagnostic_source_code
      )
  end

  # Try the hash form first when applicable; fall back to positional;
  # surface any internal mismatch as an "Internal Args Error" suffix.
  sig { params(template: String, args: T::Array[String], kwargs: T::Hash[Symbol, T::Array[Symbol]]).returns(String) }
  def format_diagnostic_template(template, args, kwargs)
    T.bind(self, T.untyped) rescue nil
    DiagnosticRegistry.format_template(template, args, kwargs)
  end

  sig { params(code: Symbol, args: String, kwargs: T.untyped).returns(String) }
  def diagnostic_message(code, *args, **kwargs)
    template = MESSAGES[code]
    Kernel.raise "Internal Compiler Error: Unknown error code :#{code}" unless template

    format_diagnostic_template(template, args, kwargs)
  end

  sig { params(code: Symbol, kwargs: DiagnosticRegistry::DiagnosticKwValue).returns(String) }
  def fix_description(code, **kwargs)
    DiagnosticRegistry.fix_description_from_hash(code, kwargs)
  end

  sig { params(code: Symbol, kwargs: T::Hash[Symbol, DiagnosticRegistry::DiagnosticKwValue]).returns(String) }
  def fix_description_from_hash(code, kwargs)
    DiagnosticRegistry.fix_description_from_hash(code, kwargs)
  end

  # Non-fatal compiler note (printed to stderr, does not halt compilation).
  sig { params(node_or_token: AST::Node, message: String).returns(NilClass) }
  def note!(node_or_token, message)
    T.bind(self, T.untyped) rescue nil
    token = diagnostic_token(node_or_token)
    loc = token ? " (line #{token.line})" : ""
    diagnostic_output("\e[36m[Note]\e[0m #{message}#{loc}")
    nil
  end

  sig { params(node_or_token: AST::Node, message: String).returns(NilClass) }
  def warning!(node_or_token, message)
    T.bind(self, T.untyped) rescue nil
    token = diagnostic_token(node_or_token)
    loc = token ? " (line #{token.line})" : ""
    diagnostic_output("\e[33m[Warning]\e[0m #{message}#{loc}")
    nil
  end

  # Emit a fixable finding — a diagnostic with one or more suggested
  # edits.
  #
  # With `FixCollector` active (`clear fix` mode, future LSP mode), the
  # finding is captured and the caller returns normally — even at
  # `level: :error`. This is what lets the annotator accumulate every
  # diagnostic in a single pass instead of halting on the first one.
  # Downstream phases (MIR, transpile) aren't driven in `clear fix`;
  # the CLI decides what to do based on `FixCollector.has_fatal?`.
  #
  # Without a collector, behaviour matches the legacy compiler:
  #   :hint / :info / :warning — printed to stderr, doesn't halt.
  #   :error                   — raised as CompilerError (like `error!`).
  # `raise_in_collector:` — set to true for errors whose site is unsafe
  # to continue past (e.g., undefined identifier — downstream reads
  # `node.full_type` and cascades on nil). The finding is still
  # captured; the annotator then raises so the collector gets a clean
  # snapshot of what was diagnosed before the cascade would start.
  sig do
    params(
      node_or_token: T.untyped,
      category: Symbol,
      fixes: T::Array[Fix],
      message: T.nilable(String),
      code: T.nilable(Symbol),
      level: Symbol,
      raise_in_collector: T::Boolean,
      kwargs: T.untyped
    ).returns(T.untyped)
  end
  def fixable!(node_or_token, category:, fixes:, message: nil, code: nil, level: :warning, raise_in_collector: false, **kwargs)
    T.bind(self, T.untyped) rescue nil
    rendered_message = message || diagnostic_message(T.must(code), **kwargs)
    token = diagnostic_token(node_or_token)
    finding = FixableFinding.new(
      level: level, message: rendered_message, token: token,
      category: category, fixes: fixes
    )

    if FixCollector.enabled?
      FixCollector.push(finding)
      return unless raise_in_collector
      err_class = self.class.name&.include?("Parser") ? ParserError : CompilerError
      source_token = source_error_token(token)
      raise err_class.new(
        source_token,
        rendered_message,
        diagnostic_source_code
      )
    end

    case level
    when :hint, :info, :warning
      loc = token ? " (line #{token.line})" : ""
      tag = level == :warning ? "\e[33m[Warning]\e[0m" : "\e[36m[#{level.to_s.capitalize}]\e[0m"
      diagnostic_output("#{tag} #{rendered_message}#{loc}")
    when :error
      err_class = self.class.name&.include?("Parser") ? ParserError : CompilerError
      source_token = source_error_token(token)
      raise err_class.new(
        source_token,
        rendered_message,
        diagnostic_source_code
      )
    end
  end

  sig { returns(T.nilable(String)) }
  def diagnostic_source_code
    T.cast(T.unsafe(self).source_code, T.nilable(String))
  end

  sig { params(node_or_token: T.untyped).returns(DiagnosticToken) }
  def diagnostic_token(node_or_token)
    token = node_or_token.respond_to?(:token) ? node_or_token.token : node_or_token
    T.cast(token, DiagnosticToken)
  end

  sig { params(token: DiagnosticToken).returns(T.nilable(Lexer::Token)) }
  def source_error_token(token)
    return token if token.is_a?(Lexer::Token)
    return nil unless token && token.respond_to?(:line) && token.respond_to?(:column)

    Lexer::Token.new(:ANCHOR, nil, T.unsafe(token).line, T.unsafe(token).column)
  end

  sig { params(message: String).returns(NilClass) }
  def diagnostic_output(message)
    Kernel.warn(message)
    nil
  end

  private :format_diagnostic_template, :diagnostic_source_code, :diagnostic_token, :source_error_token, :diagnostic_output

end

class SourceError < StandardError
    extend T::Sig

  attr_reader :token, :original_message, :source_code

  sig { params(token: T.nilable(Lexer::Token), message: String, source_code: T.nilable(String)).void }
  def initialize(token, message, source_code)
    @token = T.let(token, T.nilable(Lexer::Token))
    @original_message = message
    @source_code = source_code
    super(build_message)
  end

  # Child classes override this for the header title
  sig { returns(String) }
  def error_type; "Error"; end

  private

  sig { returns(String) }
  def build_message
    # Handle EOF or missing token
    if @token.nil? || @token.type == :EOF
      return "\n\e[31m[#{error_type}]\e[0m #{@original_message} (at End of File)\n"
    end

    line_num = @token.line
    col_num = @token.column

    return "[#{error_type}] #{@original_message} (Line #{line_num})" if @source_code.nil? || @source_code.empty?

    lines = @source_code.split("\n")
    raw_line = lines[line_num - 1] || ""

    # 1. Header
    out = "\n\e[31m[#{error_type}]\e[0m #{@original_message}\n"
    out += "\e[90mLocation:\e[0m Line #{line_num}, Column #{col_num}\n\n"

    # 2. The Code Snippet
    gutter_width = line_num.to_s.length
    out += "  #{' ' * gutter_width} | \n"
    out += "  #{line_num} | #{raw_line}\n"

    # 3. The Caret
    prefix = raw_line[0...col_num-1] || ""
    visual_offset = prefix.gsub("\t", "  ").length

    out += "  #{' ' * gutter_width} | \e[31m#{' ' * visual_offset}^\e[0m\n"
    out += "  #{' ' * gutter_width} | \n"

    out
  end
end

class ParserError < SourceError
    extend T::Sig

  sig { returns(String) }
  def error_type; "Parser Error"; end
end

class CompilerError < SourceError
    extend T::Sig

  sig { returns(String) }
  def error_type; "Compiler Error"; end
end
