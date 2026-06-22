# typed: false
# frozen_string_literal: true

module Espalier
  module Languages
    class UnsupportedRuntimeTracer < StandardError; end

    class Provider
      def language
        raise NotImplementedError
      end

      def aliases
        []
      end

      def display_name
        language.to_s
      end

      def extensions
        []
      end

      def static_analysis?
        true
      end

      def static_parser
        "tree_sitter"
      end

      def annotation_systems
        []
      end

      def type_systems
        []
      end

      def type_indexing?
        !type_systems.empty?
      end

      def runtime_tracing?
        false
      end

      def runtime_trace_events
        []
      end

      def runtime_capabilities
        {
          "method_calls" => false,
          "params" => false,
          "returns" => false,
          "exceptions" => false,
          "fields" => false,
          "collections" => false,
          "hash_shapes" => false,
          "call_edges" => false,
          "line_coverage" => false,
        }
      end

      def notes
        ["static Tree-sitter evidence is supported"]
      end

      def capability
        {
          "language" => language.to_s,
          "display_name" => display_name,
          "aliases" => aliases.map(&:to_s),
          "extensions" => extensions.map(&:to_s).sort,
          "static_analysis" => static_analysis?,
          "static_parser" => static_parser,
          "annotation_systems" => annotation_systems.map(&:to_s).sort,
          "type_indexing" => type_indexing?,
          "type_systems" => type_systems.map(&:to_s).sort,
          "runtime_tracing" => runtime_tracing?,
          "runtime_trace_events" => runtime_trace_events.map(&:to_s).sort,
          "runtime_capabilities" => runtime_capabilities,
          "notes" => notes.map(&:to_s),
        }
      end

      def collect_runtime(argv:, root:, output:, targets:, append: false)
        raise UnsupportedRuntimeTracer, "#{display_name} does not have a runtime tracer provider"
      end
    end

    class GenericTreeSitterProvider < Provider
      def initialize(language)
        @language = language.to_s
      end

      def language
        @language
      end
    end

    module Registry
      module_function

      def providers
        @providers ||= {}
      end

      def register(provider)
        names = [provider.language, *provider.aliases].map { |name| normalize(name) }
        names.each { |name| providers[name] = provider }
        provider
      end

      def provider_for(language)
        providers.fetch(normalize(language)) { GenericTreeSitterProvider.new(language) }
      end

      def provider_for_path(path)
        extension = File.extname(path).downcase
        registered_providers.find do |provider|
          provider.extensions.map(&:downcase).include?(extension)
        end
      end

      def registered_providers
        providers.values.uniq.sort_by(&:language)
      end

      def capabilities
        registered_providers.map(&:capability)
      end

      def capability_for(language)
        provider_for(language).capability
      end

      def normalize(language)
        language.to_s.tr("-", "_")
      end
    end

    def self.register(provider)
      Registry.register(provider)
    end

    def self.provider_for(language)
      Registry.provider_for(language)
    end

    def self.provider_for_path(path)
      Registry.provider_for_path(path)
    end

    def self.capabilities
      Registry.capabilities
    end

    def self.capability_for(language)
      Registry.capability_for(language)
    end

    class Ruby < Provider
      def language = "ruby"
      def display_name = "Ruby"
      def extensions = [".rb", ".rbi"]
      def annotation_systems = ["sorbet"]
    end

    class Python < Provider
      def language = "python"
      def aliases = ["py"]
      def display_name = "Python"
      def extensions = %w[.py .pyi]
      def annotation_systems = ["python-typing"]
    end

    class TypeScript < Provider
      def language = "typescript"
      def aliases = ["ts"]
      def display_name = "TypeScript"
      def extensions = %w[.ts .tsx]
      def annotation_systems = ["typescript"]
    end

    class C < Provider
      def language = "c"
      def display_name = "C"
      def extensions = %w[.c .h]
    end

    class Cpp < Provider
      def language = "cpp"
      def aliases = ["c++", "cplusplus"]
      def display_name = "C++"
      def extensions = %w[.cc .cpp .cxx .hh .hpp .hxx]
      def notes = super + ["use --language cpp for C++ .h headers"]
    end

    class CSharp < Provider
      def language = "csharp"
      def aliases = ["c#", "c_sharp", "cs"]
      def display_name = "C#"
      def extensions = [".cs"]
    end

    class Go < Provider
      def language = "go"
      def aliases = ["golang"]
      def display_name = "Go"
      def extensions = [".go"]
    end

    class Java < Provider
      def language = "java"
      def display_name = "Java"
      def extensions = [".java"]
    end

    class Kotlin < Provider
      def language = "kotlin"
      def aliases = ["kt", "kts"]
      def display_name = "Kotlin"
      def extensions = %w[.kt .kts]
    end

    class Lua < Provider
      def language = "lua"
      def display_name = "Lua"
      def extensions = [".lua"]
    end

    class Rust < Provider
      def language = "rust"
      def aliases = ["rs"]
      def display_name = "Rust"
      def extensions = [".rs"]
    end

    class Swift < Provider
      def language = "swift"
      def display_name = "Swift"
      def extensions = [".swift"]
    end

    class Zig < Provider
      def language = "zig"
      def display_name = "Zig"
      def extensions = [".zig"]
    end

    [
      Ruby, Python, TypeScript, C, Cpp, CSharp, Go, Java, Kotlin, Lua, Rust, Swift, Zig
    ].each { |klass| register(klass.new) }
  end
end
