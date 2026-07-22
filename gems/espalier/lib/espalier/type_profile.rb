# frozen_string_literal: true

require "set"

module FactMine
  module Syntax
    class TypeExpr < String
      attr_reader :kind, :data, :language

      def initialize(kind, data = nil, language = nil)
        @kind = kind
        @data = data
        @language = language
        super(to_lang_string)
      end

      def to_lang_string
        case @language
        when "python"
          to_python_string
        when "typescript", "javascript"
          to_typescript_string
        when "go"
          to_go_string
        else
          to_sorbet_string
        end
      end

      def to_sorbet_string
        case @kind
        when "Untyped"
          "T.untyped"
        when "NilClass"
          "NilClass"
        when "Primitive"
          @data.to_s
        when "Nilable"
          "T.nilable(#{TypeExpr.from_json(@data, @language)})"
        when "Array"
          "T::Array[#{TypeExpr.from_json(@data, @language)}]"
        when "Hash"
          key = TypeExpr.from_json(@data["key"], @language)
          val = TypeExpr.from_json(@data["value"], @language)
          "T::Hash[#{key}, #{val}]"
        when "Set"
          "T::Set[#{TypeExpr.from_json(@data, @language)}]"
        when "Union"
          parts = Array(@data).map { |d| TypeExpr.from_json(d, @language) }
          "T.any(#{parts.join(', ')})"
        else
          @kind.to_s
        end
      end

      def to_python_string
        case @kind
        when "Untyped"
          "Any"
        when "NilClass"
          "None"
        when "Primitive"
          @data.to_s
        when "Nilable"
          inner = TypeExpr.from_json(@data, @language)
          "#{inner} | None"
        when "Array"
          "list[#{TypeExpr.from_json(@data, @language)}]"
        when "Hash"
          key = TypeExpr.from_json(@data["key"], @language)
          val = TypeExpr.from_json(@data["value"], @language)
          "dict[#{key}, #{val}]"
        when "Set"
          "set[#{TypeExpr.from_json(@data, @language)}]"
        when "Union"
          parts = Array(@data).map { |d| TypeExpr.from_json(d, @language) }
          parts.join(' | ')
        else
          @kind.to_s
        end
      end

      def to_typescript_string
        case @kind
        when "Untyped"
          "any"
        when "NilClass"
          "null"
        when "Primitive"
          @data.to_s
        when "Nilable"
          inner = TypeExpr.from_json(@data, @language)
          "#{inner} | null"
        when "Array"
          "#{TypeExpr.from_json(@data, @language)}[]"
        when "Hash"
          key = TypeExpr.from_json(@data["key"], @language)
          val = TypeExpr.from_json(@data["value"], @language)
          "Record<#{key}, #{val}>"
        when "Set"
          "Set<#{TypeExpr.from_json(@data, @language)}>"
        when "Union"
          parts = Array(@data).map { |d| TypeExpr.from_json(d, @language) }
          parts.join(' | ')
        else
          @kind.to_s
        end
      end

      def to_go_string
        case @kind
        when "Untyped"
          "any"
        when "NilClass"
          "nil"
        when "Primitive"
          @data.to_s
        when "Nilable"
          inner = TypeExpr.from_json(@data, @language)
          "*#{inner}"
        when "Array"
          "[]#{TypeExpr.from_json(@data, @language)}"
        when "Hash"
          key = TypeExpr.from_json(@data["key"], @language)
          val = TypeExpr.from_json(@data["value"], @language)
          "map[#{key}]#{val}"
        when "Set"
          "map[#{TypeExpr.from_json(@data, @language)}]bool"
        when "Union"
          "any"
        else
          @kind.to_s
        end
      end

      def self.from_json(val, language = nil)
        return nil if val.nil?
        case val
        when TypeExpr
          val
        when Hash
          if val.key?("kind") && %w[Untyped NilClass Primitive Nilable Array Hash Set Union].include?(val["kind"])
            TypeExpr.new(val["kind"], val["data"], language)
          else
            val
          end
        else
          val
        end
      end

      def self.wrap_types!(val, current_lang = nil)
        case val
        when Hash
          if val.key?("language")
            current_lang = val["language"].to_s.downcase
          end
          if val.key?("methods") || val.key?("fields") || val.key?("type_definitions") || val.key?("facts")
            langs = []
            langs << val["language"] if val["language"]
            if val["methods"].is_a?(Array)
              langs.concat(val["methods"].map { |m| m.is_a?(Hash) ? m["language"] : nil })
            end
            if val["fields"].is_a?(Array)
              langs.concat(val["fields"].map { |f| f.is_a?(Hash) ? f["language"] : nil })
            end
            if val["type_definitions"].is_a?(Array)
              langs.concat(val["type_definitions"].map { |d| d.is_a?(Hash) ? d["language"] : nil })
            end
            current_lang = langs.compact.map(&:to_s).reject(&:empty?).first&.downcase
          end

          if val.key?("kind") && %w[Untyped NilClass Primitive Nilable Array Hash Set Union].include?(val["kind"])
            return TypeExpr.new(val["kind"], val["data"], current_lang)
          end
          if val.frozen?
            val = val.dup
          end
          val.each do |k, v|
            val[k] = wrap_types!(v, current_lang)
          end
          val
        when Array
          if val.frozen?
            val = val.dup
          end
          val.map! { |v| wrap_types!(v, current_lang) }
          val
        else
          val
        end
      end

      def self.unwrap_types(val)
        case val
        when TypeExpr
          val.as_json
        when Hash
          val.each_with_object({}) do |(k, v), h|
            h[k] = unwrap_types(v)
          end
        when Array
          val.map { |v| unwrap_types(v) }
        else
          val
        end
      end

      def as_json(options = nil)
        {
          "kind" => @kind,
          "data" => TypeExpr.unwrap_types(@data)
        }.compact
      end

      def to_json(*args)
        as_json.to_json(*args)
      end
    end

    class TypeProfile
      DEFAULT_MAX_UNION_TYPES = 3

      attr_reader :language, :type_system

      def initialize(
        language:,
        type_system: nil,
        intrinsic_types: [],
        broad_types: [],
        nil_types: [],
        boolean_types: [],
        collection_types: [],
        generic_wrappers: [],
        alias_wrappers: [],
        union_wrappers: [],
        union_operators: []
      )
        @language = language.to_sym
        @type_system = type_system&.to_s
        @intrinsic_types = string_set(intrinsic_types)
        @broad_types = string_set(broad_types)
        @nil_types = string_set(nil_types)
        @boolean_types = string_set(boolean_types)
        @collection_types = string_set(collection_types)
        @generic_wrappers = string_set(generic_wrappers)
        @alias_wrappers = Array(alias_wrappers).map { |wrapper| wrapper_config(wrapper) }.freeze
        @union_wrappers = Array(union_wrappers).map { |wrapper| wrapper_config(wrapper) }.freeze
        @union_operators = Array(union_operators).map(&:to_s).reject(&:empty?).freeze
      end

      def broad_type?(type_name)
        type_in_set?(@broad_types, type_name)
      end

      def intrinsic_type?(type_name)
        type_in_set?(@intrinsic_types, type_name) || collection_type?(type_name)
      end

      def nil_type?(type_name)
        type_in_set?(@nil_types, type_name)
      end

      def boolean_type?(type_name)
        type_in_set?(@boolean_types, type_name)
      end

      def collection_type?(type_name)
        type_in_set?(@collection_types, type_name)
      end

      def useful_type?(type_name)
        text = normalize_type(type_name)
        !text.empty? && !broad_type?(text)
      end

      def noisy_alias_target?(type_name, max_union_types:, max_length:)
        text = type_name.to_s.strip
        return true if text.empty?
        return true if text.length > max_length.to_i
        return true if broad_type?(text) || contains_broad_type?(text)
        return true if broad_union_type?(text, max: max_union_types)

        owner_references = owner_reference_tokens(text)
        return true if owner_references.empty? && (intrinsic_type?(text) || nil_type?(text) || boolean_type?(text))

        owner_references.empty?
      end

      def owner_reference_tokens(type_expression)
        raw_type_tokens(type_expression).flat_map do |token|
          owner_token_variants(token)
        end.reject do |token|
          non_owner_type_token?(token)
        end.uniq
      end

      def references_alias?(type_expression, aliases)
        current = normalize_type(type_expression)
        Array(aliases).map { |name| normalize_type(name) }
                      .reject(&:empty?)
                      .uniq
                      .any? { |alias_name| alias_type_expression?(current, alias_name) }
      end

      def alias_replacement(current_type, target_type, alias_name)
        current = normalize_type(current_type)
        target = normalize_type(target_type)
        alias_type = normalize_type(alias_name)
        return alias_type if current == target

        @alias_wrappers.each do |wrapper|
          inner = wrapped_inner(current, wrapper)
          next unless inner && normalize_type(inner) == target

          return "#{wrapper.fetch(:name)}#{wrapper.fetch(:open)}#{alias_type}#{wrapper.fetch(:close)}"
        end

        nil
      end

      def broad_union_type?(type_expression, max: DEFAULT_MAX_UNION_TYPES)
        text = type_expression.to_s
        total = 0
        @union_wrappers.each do |wrapper|
          each_wrapped_argument_source(text, wrapper) do |args|
            size = split_top_level(args).size
            return true if size > max.to_i

            total += size
            return true if total > max.to_i
          end
        end

        @union_operators.each do |operator|
          parts = split_top_level(text, delimiter: operator)
          return true if parts.size > max.to_i
        end

        false
      end

      def extract_call_args(source, name)
        text = source.to_s
        idx = text.index("#{name}(")
        return nil unless idx

        balanced_inner(text, idx + name.to_s.length, "(", ")")
      end

      def split_top_level(source, delimiter: ",")
        parts = []
        text = source.to_s
        start = 0
        depth = 0
        quote = nil
        i = 0
        while i < text.length
          char = text[i]
          if quote
            quote = nil if char == quote && text[i - 1] != "\\"
          elsif char == "\"" || char == "'"
            quote = char
          elsif opening_delimiter?(char)
            depth += 1
          elsif closing_delimiter?(char)
            depth -= 1 if depth.positive?
          elsif depth.zero? && text[i, delimiter.length] == delimiter
            parts << text[start...i].strip
            start = i + delimiter.length
            i += delimiter.length - 1
          end
          i += 1
        end
        parts << text[start..].to_s.strip
        parts.reject(&:empty?)
      end

      def normalize_type(type_name)
        type_name.to_s.gsub(/\s+/, "")
      end

      def root_type(type_name)
        text = normalize_type(type_name).delete_prefix("::")
        token = raw_type_tokens(text).first.to_s
        token.empty? ? text : token
      end

      private

      def string_set(values)
        Set.new(Array(values).map(&:to_s).reject(&:empty?)).freeze
      end

      def wrapper_config(wrapper)
        case wrapper
        when Hash
          {
            name: wrapper.fetch(:name).to_s,
            open: wrapper.fetch(:open, "(").to_s,
            close: wrapper.fetch(:close, ")").to_s
          }.freeze
        else
          { name: wrapper.to_s, open: "(", close: ")" }.freeze
        end
      end

      def type_in_set?(set, type_name)
        root = root_type(type_name)
        return true if set.include?(root)

        simple = simple_type_name(root)
        set.include?(simple)
      end

      def contains_broad_type?(type_expression)
        raw_type_tokens(type_expression).any? { |token| broad_type?(token) }
      end

      def non_owner_type_token?(token)
        token.empty? ||
          broad_type?(token) ||
          intrinsic_type?(token) ||
          nil_type?(token) ||
          boolean_type?(token) ||
          generic_wrapper?(token)
      end

      def generic_wrapper?(token)
        root = root_type(token)
        wrapper_names = @generic_wrappers +
          Set.new(@alias_wrappers.map { |wrapper| wrapper.fetch(:name) }) +
          Set.new(@union_wrappers.map { |wrapper| wrapper.fetch(:name) })
        wrapper_names = wrapper_names.flat_map { |name| [name, simple_type_name(name)] }.to_set
        wrapper_names.include?(root) || wrapper_names.include?(simple_type_name(root))
      end

      def raw_type_tokens(type_expression)
        tokens = []
        current = +""
        type_expression.to_s.each_char do |char|
          if type_token_char?(char)
            current << char
          elsif !current.empty?
            tokens << clean_type_token(current)
            current = +""
          end
        end
        tokens << clean_type_token(current) unless current.empty?
        tokens.reject(&:empty?)
      end

      def type_token_char?(char)
        char.match?(/[A-Za-z0-9_$:.]/)
      end

      def clean_type_token(token)
        token.to_s
             .sub(/\A[:.]+/, "")
             .sub(/[:.]+\z/, "")
      end

      def owner_token_variants(token)
        clean = clean_type_token(token)
        return [] if clean.empty?

        variants = [clean]
        if clean.include?("::")
          variants << clean.split("::").last
        elsif clean.include?(".")
          variants << clean.split(".").last
        end
        variants
      end

      def simple_type_name(type_name)
        type_name.to_s.split("::").last.to_s.split(".").last.to_s
      end

      def alias_type_expression?(current, alias_name)
        return false if current.empty? || alias_name.empty?
        return true if current == alias_name

        @alias_wrappers.any? do |wrapper|
          wrapped_inner(current, wrapper) == alias_name
        end
      end

      def wrapped_inner(type_expression, wrapper)
        text = normalize_type(type_expression)
        prefix = "#{wrapper.fetch(:name)}#{wrapper.fetch(:open)}"
        suffix = wrapper.fetch(:close)
        return nil unless text.start_with?(prefix) && text.end_with?(suffix)

        text[prefix.length...(text.length - suffix.length)]
      end

      def each_wrapped_argument_source(type_expression, wrapper)
        prefix = "#{wrapper.fetch(:name)}#{wrapper.fetch(:open)}"
        idx = 0
        while (start = type_expression.index(prefix, idx))
          inner = balanced_inner(type_expression, start + wrapper.fetch(:name).length, wrapper.fetch(:open), wrapper.fetch(:close))
          break unless inner

          yield inner
          idx = start + 1
        end
      end

      def balanced_inner(text, open_index, open_char, close_char)
        return nil unless text[open_index] == open_char

        depth = 0
        quote = nil
        i = open_index
        while i < text.length
          char = text[i]
          if quote
            quote = nil if char == quote && text[i - 1] != "\\"
          elsif char == "\"" || char == "'"
            quote = char
          elsif char == open_char
            depth += 1
          elsif char == close_char
            depth -= 1
            return text[(open_index + 1)...i] if depth.zero?
          end
          i += 1
        end
        nil
      end

      def opening_delimiter?(char)
        char == "(" || char == "[" || char == "{" || char == "<"
      end

      def closing_delimiter?(char)
        char == ")" || char == "]" || char == "}" || char == ">"
      end
    end

    class RubySorbetTypeProfile < TypeProfile
      MAX_UNION_TYPES = 3
      CORE_RUNTIME_GUARD_CLASSES = %w[
        Array Hash Set String Symbol Integer Float NilClass TrueClass FalseClass Numeric Range Regexp Time
      ].freeze
      NUMERIC_GUARD_SUBCLASSES = %w[Integer Float].freeze
      BOOLEAN_GUARD_SUBCLASSES = %w[TrueClass FalseClass].freeze

      def useful_type?(type)
        super && normalize_type(type) != "T.untyped"
      end

      def static_type(types, union_policy: ENV.fetch("NIL_KILL_UNION_POLICY", "untyped"))
        values = Array(types).compact.map(&:to_s).reject(&:empty?)
        return "T.untyped" if values.empty?

        has_nil = false
        others = []
        values.each do |type|
          if type == "NilClass"
            has_nil = true
          elsif type.start_with?("T.nilable(") && type.end_with?(")")
            has_nil = true
            others << type[10..-2]
          else
            others << normalize_static_type(type)
          end
        end

        others = others.uniq.sort
        if others.include?("T.noreturn")
          return has_nil ? "NilClass" : "T.noreturn" if others == ["T.noreturn"]

          others.delete("T.noreturn")
        end
        return "NilClass" if others.empty? && has_nil
        return "T.untyped" if others.empty?

        base =
          if others.all? { |type| %w[TrueClass FalseClass T::Boolean].include?(type) }
            "T::Boolean"
          elsif others.size == 1
            others.first
          elsif union_policy == "any" && others.size <= MAX_UNION_TYPES
            "T.any(#{others.join(", ")})"
          else
            "T.untyped"
          end
        return "T.untyped" if base == "T.untyped"

        has_nil ? "T.nilable(#{base})" : base
      end

      def normalize_static_type(type)
        case type.to_s
        when "Array" then "T::Array[T.untyped]"
        when "Hash" then "T::Hash[T.untyped, T.untyped]"
        when "Set" then "T::Set[T.untyped]"
        else type.to_s
        end
      end

      def extract_param_entries(signature)
        params = extract_call_args(signature, "params")
        return [] unless params

        split_top_level(params).filter_map do |entry|
          name, type = entry.split(/:\s*/, 2)
          next unless name && type

          [name.strip, type.strip]
        end
      end

      def extract_return_type(signature)
        extract_call_args(signature, "returns")
      end

      def strip_nilable_type(type)
        text = type.to_s.strip
        return text unless text.start_with?("T.nilable(")

        extract_call_args(text, "T.nilable") || text
      end

      def nullable_or_untyped?(type)
        raw = type.to_s.strip
        raw.empty? || raw == "T.untyped" || raw == "NilClass" || raw.include?("T.nilable")
      end

      def nil_check_receiver(text)
        text.to_s.strip[/\A([a-z_]\w*)\.nil\?\z/, 1]
      end
    end

    TYPE_PROFILES = {}

    def self.register_type_profile(language, profile)
      raise ArgumentError, "missing Syntax type profile language" if language.to_s.empty?

      key = [language.to_sym, profile.type_system]
      TYPE_PROFILES[key] = profile
      TYPE_PROFILES[[language.to_sym, nil]] ||= profile
    end

    def self.type_profile(language = nil, type_system: nil)
      lang = language.to_s.empty? ? :generic : language.to_sym
      TYPE_PROFILES[[lang, type_system&.to_s]] ||
        TYPE_PROFILES[[lang, nil]] ||
        TYPE_PROFILES.fetch([:generic, nil])
    end

    register_type_profile(:generic, TypeProfile.new(language: :generic))
    register_type_profile(:ruby, RubySorbetTypeProfile.new(
      language: :ruby,
      type_system: "sorbet",
      broad_types: %w[T.untyped T.anything Object BasicObject],
      intrinsic_types: %w[
        Array BasicObject Class Complex Encoding Enumerator Exception FalseClass Fiber Float Hash Integer Module NilClass
        Numeric Object Proc Range Rational Regexp String Struct Symbol Thread Time TrueClass
      ],
      nil_types: %w[NilClass],
      boolean_types: %w[TrueClass FalseClass T::Boolean],
      collection_types: %w[Array Hash Set T::Array T::Hash T::Set],
      generic_wrappers: %w[T.nilable T.any],
      alias_wrappers: [{ name: "T.nilable", open: "(", close: ")" }],
      union_wrappers: [{ name: "T.any", open: "(", close: ")" }]
    ).freeze)

    module_function

    def supported_exts(parser: "tree_sitter")
      %w[.rb .py .pyi .js .ts .tsx .go .rs .zig .c .cpp .cs .kt .java .swift .php .lua .h .hpp]
    end

    def language_for(file)
      case File.extname(file).downcase
      when ".rb" then "ruby"
      when ".py", ".pyi" then "python"
      when ".js" then "javascript"
      when ".ts", ".tsx" then "typescript"
      when ".go" then "go"
      when ".rs" then "rust"
      when ".zig" then "zig"
      when ".c" then "c"
      when ".cpp" then "cpp"
      when ".cs" then "csharp"
      when ".kt" then "kotlin"
      when ".java" then "java"
      when ".swift" then "swift"
      when ".php" then "php"
      when ".lua" then "lua"
      when ".h" then "c"
      when ".hpp" then "cpp"
      else "generic"
      end
    end
  end
end

module Decomplex
  module SourceFilter
    DEFAULT_EXCLUDE_PATTERNS = %w[
      **/.clear-cache/**
      **/.clear-transpile-cache/**
      **/.global-zig-cache/**
      **/.zig-cache/**
      **/zig-cache/**
      **/zig-out/**
      **/node_modules/**
      **/all-tests.zig
    ].freeze

    module_function

    def collect(targets, parser: "tree_sitter", root: Dir.pwd, exclude: [], include_defaults: true)
      Array(targets).flat_map do |target|
        expand_target(target)
      end.select do |path|
        source_file?(path, parser: parser, root: root, exclude: exclude,
                          include_defaults: include_defaults)
      end.uniq.sort
    end

    def source_file?(path, parser: "tree_sitter", root: Dir.pwd, exclude: [], include_defaults: true)
      expanded = expanded_path(path, root)
      file_path = File.file?(path) ? path : expanded
      return false unless File.file?(file_path)
      return false if File.basename(file_path).start_with?(".")
      return false unless FactMine::Syntax.supported_exts(parser: parser).include?(File.extname(file_path).downcase)

      !excluded_path?(path, root: root, exclude: exclude, include_defaults: include_defaults)
    end

    def excluded_path?(path, root: Dir.pwd, exclude: [], include_defaults: true)
      patterns = exclude_patterns(exclude, include_defaults: include_defaults)
      return false if patterns.empty?

      variants = path_variants(path, root)
      patterns.any? do |pattern|
        pat = pattern.to_s.tr("\\", "/")
        variants.any? do |candidate|
          directory_exclude_match?(candidate, pat) ||
            File.fnmatch?(pat, candidate, File::FNM_PATHNAME | File::FNM_EXTGLOB) ||
            File.fnmatch?(pat, candidate, File::FNM_EXTGLOB)
        end
      end
    end

    def path_variants(path, root)
      raw = path.to_s.tr("\\", "/")
      expanded = expanded_path(path, root).tr("\\", "/")
      rel = relative_path(expanded, root).tr("\\", "/")
      base = File.basename(raw)
      [raw, expanded, rel, base].uniq
    end

    def exclude_patterns(exclude, include_defaults: true)
      patterns = Array(exclude).compact.flat_map { |value| value.to_s.split(File::PATH_SEPARATOR) }
      patterns = DEFAULT_EXCLUDE_PATTERNS + patterns if include_defaults
      patterns.map(&:strip).reject(&:empty?)
    end

    def directory_exclude_match?(path, pattern)
      return false unless pattern.end_with?("/**")

      prefix = pattern.delete_suffix("/**")
      if prefix.start_with?("**/")
        suffix = prefix.delete_prefix("**/")
        path == suffix || path.start_with?("#{suffix}/") || path.include?("/#{suffix}/")
      else
        path == prefix || path.start_with?("#{prefix}/")
      end
    end

    def expand_target(target)
      path = target.to_s
      if File.directory?(path)
        Dir.glob(File.join(path, "**", "*"))
      elsif glob_pattern?(path)
        Dir.glob(path)
      else
        [path]
      end
    end

    def glob_pattern?(path)
      path.match?(/[*?\[\]{]/)
    end

    def expanded_path(path, root)
      raw = path.to_s
      raw.start_with?("/") ? File.expand_path(raw) : File.expand_path(raw, root)
    end

    def relative_path(path, root)
      root = File.expand_path(root).tr("\\", "/").chomp("/")
      expanded = File.expand_path(path).tr("\\", "/")
      prefix = "#{root}/"
      expanded.start_with?(prefix) ? expanded[prefix.length..] : path.to_s
    end
  end

  module Sarif
    module_function

    SCHEMA = "https://json.schemastore.org/sarif-2.1.0.json"
    PROOF_BOUNDARY_PROPERTY = "fact_mine.proof_boundary"
    PROOF_BOUNDARY_SUMMARY_PROPERTY = "fact_mine.proof_boundary_summary"
    PROOF_BOUNDARY_SCHEMA = "fact-mine.proof-boundary.v2"

    # Separates fact completeness, claim strength, and coverage discharge.
    # Producers must use `unknown` when FactMine supplied no completeness fact.
    def proof_boundary(input_completeness:, claim_status:, coverage_discharge:, authority:, scope:, blockers: [])
      raise ArgumentError, "invalid input completeness: #{input_completeness}" unless %w[complete partial unknown].include?(input_completeness.to_s)
      raise ArgumentError, "invalid claim status: #{claim_status}" unless %w[proven observed review].include?(claim_status.to_s)
      raise ArgumentError, "invalid coverage discharge: #{coverage_discharge}" unless %w[satisfiable unsatisfiable not_applicable unknown].include?(coverage_discharge.to_s)

      {
        "schema" => PROOF_BOUNDARY_SCHEMA,
        "input_completeness" => input_completeness.to_s,
        "claim_status" => claim_status.to_s,
        "coverage_discharge" => coverage_discharge.to_s,
        "authority" => Array(authority).map(&:to_s),
        "scope" => scope.to_s,
        "blockers" => Array(blockers).map(&:to_s).uniq.sort
      }
    end

    # Counts each dimension independently; review is not a completeness tier.
    def proof_boundary_summary(results)
      input = { "complete" => 0, "partial" => 0, "unknown" => 0 }
      claims = { "proven" => 0, "observed" => 0, "review" => 0 }
      coverage = { "satisfiable" => 0, "unsatisfiable" => 0, "not_applicable" => 0, "unknown" => 0 }
      Array(results).each do |result|
        boundary = result.dig("properties", PROOF_BOUNDARY_PROPERTY)
        next unless boundary.is_a?(Hash)

        input[input.key?(boundary["input_completeness"]) ? boundary["input_completeness"] : "unknown"] += 1
        claims[claims.key?(boundary["claim_status"]) ? boundary["claim_status"] : "review"] += 1
        coverage[coverage.key?(boundary["coverage_discharge"]) ? boundary["coverage_discharge"] : "unknown"] += 1
      end
      with_boundary = input.values.sum
      {
        "schema" => PROOF_BOUNDARY_SCHEMA,
        "result_count" => Array(results).size,
        "results_with_boundary" => with_boundary,
        "input_completeness" => input,
        "claim_status" => claims,
        "coverage_discharge" => coverage
      }
    end

    def document(tool_name:, rules:, results:, information_uri: nil, properties: {})
      normalized_rules = unique_rules(rules)
      rule_index = normalized_rules.each_with_index.to_h { |rule, idx| [rule.fetch("id"), idx] }
      normalized_results = Array(results).map do |result|
        result = compact_hash(json_safe_value(result))
        rule_id = result["ruleId"]
        result["ruleIndex"] = rule_index[rule_id] if rule_id && rule_index.key?(rule_id)
        result
      end

      run = compact_hash(
        {
          "tool" => {
            "driver" => compact_hash(
              {
                "name" => tool_name,
                "informationUri" => information_uri,
                "rules" => normalized_rules
              }
            )
          },
          "results" => normalized_results,
          "properties" => json_safe_value(properties)
        }
      )
      run["results"] = normalized_results

      compact_hash(
        {
          "version" => "2.1.0",
          "$schema" => SCHEMA,
          "runs" => [run]
        }
      )
    end

    def json(**kwargs)
      JSON.pretty_generate(document(**kwargs))
    end

    def rule(id:, name: nil, short_description: nil, full_description: nil,
             default_level: "warning", help_uri: nil, properties: {})
      compact_hash(
        {
          "id" => id.to_s,
          "name" => name || id.to_s,
          "shortDescription" => { "text" => short_description || name || id.to_s },
          "fullDescription" => (full_description ? { "text" => full_description } : nil),
          "defaultConfiguration" => { "level" => default_level },
          "helpUri" => help_uri,
          "properties" => json_safe_value(properties)
        }
      )
    end

    def result(rule_id:, message:, path: nil, line: nil, start_column: nil,
               end_line: nil, end_column: nil, level: "warning",
               properties: {}, partial_fingerprints: nil)
      compact_hash(
        {
          "ruleId" => rule_id.to_s,
          "level" => level,
          "message" => { "text" => message.to_s },
          "locations" => sarif_locations(
            path: path,
            line: line,
            start_column: start_column,
            end_line: end_line,
            end_column: end_column
          ),
          "partialFingerprints" => json_safe_value(partial_fingerprints),
          "properties" => json_safe_value(properties)
        }
      )
    end

    def sarif_locations(path:, line:, start_column: nil, end_line: nil, end_column: nil)
      return [] if path.to_s.empty?

      [
        {
          "physicalLocation" => compact_hash(
            {
              "artifactLocation" => { "uri" => normalize_path(path) },
              "region" => compact_hash(
                {
                  "startLine" => positive_int(line, 1),
                  "startColumn" => positive_int(start_column),
                  "endLine" => positive_int(end_line),
                  "endColumn" => positive_int(end_column)
                }
              )
            }
          )
        }
      ]
    end

    def normalize_path(path)
      path.to_s.tr("\\", "/").sub(%r{\A\./}, "")
    end

    def slug(value)
      value.to_s.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-|-+\z/, "")
    end

    def json_safe_value(value)
      case value
      when Hash
        value.to_h { |key, child| [key.to_s, json_safe_value(child)] }
      when Array
        value.map { |child| json_safe_value(child) }
      when Symbol
        value.to_s
      else
        value
      end
    end

    def compact_hash(hash)
      hash.each_with_object({}) do |(key, value), out|
        next if value.nil?
        next if value.respond_to?(:empty?) && value.empty?

        out[key] = value
      end
    end

    def positive_int(value, fallback = nil)
      number = value.nil? ? fallback : value
      return nil if number.nil?

      number = number.to_i
      number.positive? ? number : fallback
    end

    def unique_rules(rules)
      seen = {}
      Array(rules).filter_map do |rule|
        rule = json_safe_value(rule)
        id = rule["id"].to_s
        next if id.empty? || seen[id]

        seen[id] = true
        compact_hash(rule)
      end
    end
  end
end
