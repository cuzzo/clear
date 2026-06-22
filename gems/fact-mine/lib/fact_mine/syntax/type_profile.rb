# frozen_string_literal: true

module FactMine
  module Syntax
    # Language-owned type-system vocabulary and type-expression helpers.
    #
    # This class owns only generic delimiter-aware mechanics. Concrete type
    # names, wrapper names, and broad/intrinsic vocabulary are registered by
    # syntax/<language>.rb files.
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
  end
end
