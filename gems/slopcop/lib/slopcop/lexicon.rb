# frozen_string_literal: true

module SlopCop
  LanguageLexicon = Struct.new(
    :type_guard_patterns, :diagnostic_patterns, :trivial_patterns,
    :nil_literal_patterns,
    keyword_init: true
  ) do
    def type_guard?(text, allow_literal_nil: true)
      source = text.to_s
      return true if allow_literal_nil && matches?(nil_literal_patterns, source)

      matches?(type_guard_patterns, source)
    end

    def diagnostic?(text, extra_names: [])
      source = text.to_s
      matches?(diagnostic_patterns, source) ||
        call_name?(source, Array(extra_names).map(&:to_s))
    end

    def trivial?(text)
      source = text.to_s.strip
      source.empty? || matches?(trivial_patterns, source)
    end

    private

    def matches?(patterns, source)
      Array(patterns).any? { |pattern| source.match?(pattern) }
    end

    def call_name?(source, names)
      names.reject(&:empty?).any? do |name|
        source.match?(/(?:\A|[^\w!?])#{Regexp.escape(name)}[!?]?(?:\s*\(|\b)/)
      end
    end
  end

  GENERIC_LEXICON = LanguageLexicon.new(
    nil_literal_patterns: [/\b(?:nil|null|none|undefined)\b/i].freeze,
    type_guard_patterns: [
      /\b(?:isinstance|typeof|typeid|instanceof)\b/,
      /(?:\?\.|&\.)/,
      /@typeInfo\b/,
      /\bkind\s*(?:==|!=)/
    ].freeze,
    diagnostic_patterns: [
      /\b(?:throw|panic|abort|unreachable)\b/,
      /\breturn\s+error[.\w]*/
    ].freeze,
    trivial_patterns: [
      /\A(?:nil|null|None|undefined|true|false|0|1|break|continue|unreachable)\s*;?\z/,
      /\Areturn\s+(?:nil|null|None|undefined|true|false|0|1)\s*;?\z/
    ].freeze
  ).freeze
  
  RUBY_LEXICON = LanguageLexicon.new(
    nil_literal_patterns: [/\bnil\b/].freeze,
    type_guard_patterns: [
      /(?:\A|[^\w!?])(?:nil\?|is_a\?|kind_of\?|instance_of\?|respond_to\?)(?:\s*\(|\b)/,
      /&\./
    ].freeze,
    diagnostic_patterns: [
      /(?:\A|[^\w!?])(?:raise|fail|abort)[!?]?(?:\s*\(|\b)/
    ].freeze,
    trivial_patterns: [
      /\A(?:nil|true|false|0|1|break|next)\s*;?\z/,
      /\Areturn\s+(?:nil|true|false|0|1)\s*;?\z/
    ].freeze
  ).freeze
  
  PYTHON_LEXICON = LanguageLexicon.new(
    nil_literal_patterns: [/\bNone\b/].freeze,
    type_guard_patterns: [
      /\b(?:isinstance|issubclass|hasattr)\s*\(/,
      /\bis\s+(?:not\s+)?None\b/,
      /\btype\s*\([^)]*\)\s*(?:==|is)\s*/
    ].freeze,
    diagnostic_patterns: [
      /\braise\b/,
      /\bassert\b/,
      /\bsys\.exit\s*\(/
    ].freeze,
    trivial_patterns: [
      /\A(?:None|True|False|0|1|break|continue|pass)\s*;?\z/,
      /\Areturn\s+(?:None|True|False|0|1)\s*;?\z/
    ].freeze
  ).freeze
  
  JAVASCRIPT_LEXICON = LanguageLexicon.new(
    nil_literal_patterns: [/\b(?:null|undefined)\b/].freeze,
    type_guard_patterns: [
      /\btypeof\b/,
      /\binstanceof\b/,
      /(?:\?\.|\b(?:==|!=|===|!==)\s*(?:null|undefined)\b)/
    ].freeze,
    diagnostic_patterns: [
      /\bthrow\b/,
      /\bprocess\.exit\s*\(/
    ].freeze,
    trivial_patterns: [
      /\A(?:null|undefined|true|false|0|1|break|continue)\s*;?\z/,
      /\Areturn\s+(?:null|undefined|true|false|0|1)\s*;?\z/
    ].freeze
  ).freeze
  
  GO_LEXICON = LanguageLexicon.new(
    nil_literal_patterns: [/\bnil\b/].freeze,
    type_guard_patterns: [
      /\bnil\b/,
      /\.\(type\)/,
      /\.\([A-Za-z_]\w*(?:\.[A-Za-z_]\w*)*\)/
    ].freeze,
    diagnostic_patterns: [
      /\bpanic\s*\(/,
      /\breturn\s+error[.\w]*/
    ].freeze,
    trivial_patterns: [
      /\A(?:nil|true|false|0|1|break|continue|fallthrough)\s*;?\z/,
      /\Areturn\s+(?:nil|true|false|0|1)\s*;?\z/
    ].freeze
  ).freeze
  
  RUST_LEXICON = LanguageLexicon.new(
    nil_literal_patterns: [/\bNone\b/].freeze,
    type_guard_patterns: [
      /\b(?:is_some|is_none)\s*\(/,
      /\b(?:Some|None)\b/,
      /\bmatches!\s*\(/
    ].freeze,
    diagnostic_patterns: [
      /\b(?:panic|unreachable|todo|unimplemented)!\s*\(/,
      /\breturn\s+Err\s*\(/
    ].freeze,
    trivial_patterns: [
      /\A(?:None|true|false|0|1|break|continue|unreachable!)\s*;?\z/,
      /\Areturn\s+(?:None|true|false|0|1)\s*;?\z/
    ].freeze
  ).freeze
  
  ZIG_LEXICON = LanguageLexicon.new(
    nil_literal_patterns: [/\bnull\b/].freeze,
    type_guard_patterns: [
      /\bnull\b/,
      /@typeInfo\b/,
      /\bif\s*\([^)]*\)\s*\|/
    ].freeze,
    diagnostic_patterns: [
      /@panic\s*\(/,
      /\bunreachable\b/,
      /\breturn\s+error[.\w]*/
    ].freeze,
    trivial_patterns: [
      /\A(?:null|true|false|0|1|break|continue|unreachable)\s*;?\z/,
      /\Areturn\s+(?:null|true|false|0|1)\s*;?\z/
    ].freeze
  ).freeze
  
  LANGUAGE_LEXICONS = {
    ruby: RUBY_LEXICON,
    python: PYTHON_LEXICON,
    javascript: JAVASCRIPT_LEXICON,
    typescript: JAVASCRIPT_LEXICON,
    go: GO_LEXICON,
    rust: RUST_LEXICON,
    zig: ZIG_LEXICON
  }.freeze

  def self.language_lexicon(language)
    key = language.to_s.empty? ? nil : language.to_sym
    LANGUAGE_LEXICONS.fetch(key, GENERIC_LEXICON)
  end
end
