# frozen_string_literal: true

require "minitest/autorun"

class FactMineArchitectureInvariantsTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  LIB = File.join(ROOT, "lib", "fact_mine")

  SYNTAX_RB_EXTENSION_HOST_PATTERNS = {
    "clone similarity belongs in syntax/clone_similarity.rb" => /\b(?:CloneCandidate|clone_candidates|CLONE_)/,
    "dispatch facts belong in syntax/dispatch.rb" => /\b(?:DispatchSite|dispatch_sites|DISPATCH_)/,
    "nil guard facts belong in syntax/nil_guards.rb" => /\b(?:NilGuard|redundant_nil_guard_findings)/,
    "local complexity facts belong in syntax/complexity.rb" => /\b(?:LocalComplexity|local_complexity_scores)/
  }.freeze
  SYNTAX_RB_ADAPTER_IMPLEMENTATION_PATTERNS = {
    "concrete language adapters belong under lib/fact_mine/syntax/" =>
      /^\s*class\s+(?!TreeSitterLanguageAdapter\b)\w+SyntaxAdapter\b/,
    "language profiles must instantiate concrete adapters, not the base adapter" =>
      /:\s*TreeSitterLanguageAdapter\.new\(/
  }.freeze
  ADAPTER_LOADER_LANGUAGE_IMPLEMENTATION_PATTERNS = {
    "language lexicons belong in the language adapter file" =>
      /^\s*[A-Z_]+_LEXICON\s*=/,
    "concrete language adapters belong in the language adapter file" =>
      /^\s*class\s+(?!TreeSitterLanguageAdapter\b)\w+SyntaxAdapter\b/
  }.freeze
  LANGUAGE_ADAPTER_FILES = {
    "ruby.rb" => "RubySyntaxAdapter",
    "python.rb" => "PythonSyntaxAdapter",
    "javascript.rb" => "JavaScriptSyntaxAdapter",
    "typescript.rb" => "TypeScriptSyntaxAdapter",
    "go.rb" => "GoSyntaxAdapter",
    "rust.rb" => "RustSyntaxAdapter",
    "zig.rb" => "ZigSyntaxAdapter",
    "lua.rb" => "LuaSyntaxAdapter",
    "c.rb" => "CSyntaxAdapter",
    "cpp.rb" => "CppSyntaxAdapter",
    "csharp.rb" => "CSharpSyntaxAdapter",
    "java.rb" => "JavaSyntaxAdapter",
    "swift.rb" => "SwiftSyntaxAdapter",
    "kotlin.rb" => "KotlinSyntaxAdapter",
    "php.rb" => "PhpSyntaxAdapter"
  }.freeze
  SYNTAX_ENGINE_OWNER_FILES = %w[
    clone_similarity.rb effects.rb protocols.rb
  ].freeze
  SYNTAX_ALLOWED_FILES = %w[
    adapters.rb
    c.rb
    clone_similarity.rb
    complexity.rb
    contracts.rb
    cpp.rb
    csharp.rb
    dispatch.rb
    dynamic_language.rb
    effects.rb
    fact_document.rb
    go.rb
    java.rb
    javascript.rb
    kotlin.rb
    lua.rb
    nil_guards.rb
    normalized_extraction_behavior.rb
    normalized_extractor.rb
    normalized_local_facts.rb
    passes.rb
    php.rb
    protocols.rb
    python.rb
    ruby.rb
    rust.rb
    swift.rb
    typescript.rb
    zig.rb
  ].freeze
  SYNTAX_ADAPTER_ENGINE_PATTERNS = {
    "semantic-effect fact generation belongs in syntax/effects.rb" =>
      /^\s*def\s+semantic_effect_sites\b/,
    "ordered-protocol fact generation belongs in syntax/protocols.rb" =>
      /^\s*def\s+(?:protocol_method_effects|protocol_call_paths)\b/,
    "clone fact generation belongs in syntax/clone_similarity.rb" =>
      /^\s*def\s+clone_candidates\b/,
    "stateful syntax enrichment belongs in syntax/passes.rb" =>
      /^\s*def\s+after_structural_facts\b/
  }.freeze
  CONCRETE_LANGUAGE_TOKENS = /\b(?:ruby|python|lua|typescript|javascript|rust|zig|swift|kotlin|php|go|java|csharp|cpp)\b/i
  AST_GENERIC_FILES = %w[
    ast/normalizer.rb
    ast/adapters/base.rb
  ].freeze
  AST_ALLOWED_FILES = %w[
    cache.rb
    node.rb
    source_map.rb
    semantic_node.rb
    semantic_normalizer.rb
    legacy_normalizer.rb
    normalizer.rb
    adapters.rb
    adapters/base.rb
    adapters/lua.rb
    adapters/python.rb
    adapters/ruby.rb
    adapters/rust.rb
    adapters/typescript.rb
    adapters/zig.rb
  ].freeze

  def test_detector_specific_syntax_extensions_do_not_live_in_syntax_rb
    syntax_rb = File.join(LIB, "syntax.rb")
    offenders = scan_files([syntax_rb], SYNTAX_RB_EXTENSION_HOST_PATTERNS)

    assert_empty offenders, format_offenders(
      "Detector-facing parser extensions must live under lib/fact_mine/syntax/",
      offenders
    )
  end

  def test_language_adapter_implementations_do_not_live_in_syntax_rb
    syntax_rb = File.join(LIB, "syntax.rb")
    offenders = scan_files([syntax_rb], SYNTAX_RB_ADAPTER_IMPLEMENTATION_PATTERNS)

    assert_empty offenders, format_offenders(
      "Core syntax.rb must not absorb concrete language adapter implementation",
      offenders
    )
  end

  def test_each_language_adapter_has_its_own_file
    offenders = LANGUAGE_ADAPTER_FILES.filter_map do |file_name, class_name|
      path = File.join(LIB, "syntax", file_name)
      next "#{file_name}: missing file" unless File.file?(path)

      source = File.read(path)
      next if source.match?(/^\s*class\s+#{Regexp.escape(class_name)}\b/)

      "#{file_name}: missing #{class_name}"
    end

    assert_empty offenders, format_offenders(
      "Every supported language must have an explicit adapter file",
      offenders
    )
  end

  def test_adapter_loader_does_not_absorb_language_implementations
    adapters_rb = File.join(LIB, "syntax", "adapters.rb")
    offenders = scan_files([adapters_rb], ADAPTER_LOADER_LANGUAGE_IMPLEMENTATION_PATTERNS)

    assert_empty offenders, format_offenders(
      "Adapter loader must only load adapters and shared base helpers",
      offenders
    )
  end

  def test_syntax_directory_does_not_gain_unreviewed_helper_files
    files = Dir.glob(File.join(LIB, "syntax", "**", "*.rb")).map do |path|
      path.delete_prefix("#{File.join(LIB, "syntax")}/")
    end.sort
    unexpected = files - SYNTAX_ALLOWED_FILES.sort
    missing = SYNTAX_ALLOWED_FILES.sort - files
    offenders = unexpected.map { |file_name| "#{file_name}: unexpected syntax helper file" } +
                missing.map { |file_name| "#{file_name}: missing syntax file" }

    assert_empty offenders, format_offenders(
      "Syntax helper files are an architecture boundary; update this invariant deliberately",
      offenders
    )
  end

  def test_concrete_syntax_adapter_classes_only_live_in_their_own_files
    files = Dir.glob(File.join(LIB, "syntax", "**", "*.rb"))
    owner_by_class = LANGUAGE_ADAPTER_FILES.invert.transform_values do |file_name|
      File.join(LIB, "syntax", file_name)
    end
    offenders = files.sort.flat_map do |path|
      rel = path.delete_prefix("#{ROOT}/")
      File.readlines(path, chomp: true).each_with_index.filter_map do |line, index|
        next if line.strip.start_with?("#")

        match = line.match(/^\s*class\s+(\w+SyntaxAdapter)\b/)
        next unless match

        class_name = match[1]
        owner = owner_by_class[class_name]
        next unless owner && File.expand_path(path) != File.expand_path(owner)

        owner_rel = owner.delete_prefix("#{ROOT}/")
        "#{rel}:#{index + 1}: #{class_name} belongs in #{owner_rel}: #{line.strip}"
      end
    end

    assert_empty offenders, format_offenders(
      "Concrete syntax adapters must not be split across helper files",
      offenders
    )
  end

  def test_concrete_syntax_adapters_do_not_own_detector_fact_engines
    files = Dir.glob(File.join(LIB, "syntax", "**", "*.rb")).reject do |path|
      SYNTAX_ENGINE_OWNER_FILES.include?(File.basename(path))
    end
    offenders = scan_files(files, SYNTAX_ADAPTER_ENGINE_PATTERNS)

    assert_empty offenders, format_offenders(
      "Concrete syntax adapters may classify grammar shapes but must not own detector fact engines",
      offenders
    )
  end

  def test_syntax_subfiles_do_not_load_additional_helpers
    files = Dir.glob(File.join(LIB, "syntax", "**", "*.rb"))
    offenders = files.sort.flat_map do |path|
      rel = path.delete_prefix("#{ROOT}/")
      File.readlines(path, chomp: true).each_with_index.filter_map do |line, index|
        next if line.strip.start_with?("#")
        next unless line.match?(/^\s*(?:require|require_relative)\b/)

        "#{rel}:#{index + 1}: syntax subfiles must be loaded only by syntax.rb: #{line.strip}"
      end
    end

    assert_empty offenders, format_offenders(
      "Syntax subfiles must not hide behavior behind their own requires",
      offenders
    )
  end

  def test_generic_ast_normalizer_files_do_not_reference_concrete_languages
    files = AST_GENERIC_FILES.map { |file_name| File.join(LIB, file_name) }
    offenders = scan_files(
      files,
      "generic AST normalizer code must not branch on concrete languages" => CONCRETE_LANGUAGE_TOKENS
    )

    assert_empty offenders, format_offenders(
      "Concrete AST normalization behavior belongs in lib/fact_mine/ast/adapters/<language>.rb",
      offenders
    )
  end

  def test_ast_directory_does_not_gain_unreviewed_helper_files
    ast_root = File.join(LIB, "ast")
    files = Dir.glob(File.join(ast_root, "**", "*.rb")).map do |path|
      path.delete_prefix("#{ast_root}/")
    end.sort
    unexpected = files - AST_ALLOWED_FILES.sort
    missing = AST_ALLOWED_FILES.sort - files
    offenders = unexpected.map { |file_name| "#{file_name}: unexpected AST helper file" } +
                missing.map { |file_name| "#{file_name}: missing AST file" }

    assert_empty offenders, format_offenders(
      "AST helper files are an architecture boundary; update this invariant deliberately",
      offenders
    )
  end

  def test_generic_normalized_extractor_does_not_reference_concrete_languages
    generic_extraction_files = %w[
      normalized_extraction_behavior.rb
      normalized_extractor.rb
    ].map { |file_name| File.join(LIB, "syntax", file_name) }
    offenders = scan_files(
      generic_extraction_files,
      "generic normalized fact extraction must not branch on concrete languages" => CONCRETE_LANGUAGE_TOKENS
    )

    assert_empty offenders, format_offenders(
      "Concrete normalized extraction quirks belong in the language syntax adapter files",
      offenders
    )
  end

  def test_generic_normalized_fact_engines_do_not_walk_raw_parser_nodes
    files = %w[
      clone_similarity.rb
      nil_guards.rb
    ].map { |file_name| File.join(LIB, "syntax", file_name) }
    offenders = scan_files(
      files,
      "generic normalized fact engines must consume normalized IR, not parser nodes" =>
        /\b(?:ts_node\?|named_children|named_child_count|named_field|first_token_kind|direct_operator)\b/
    )

    assert_empty offenders, format_offenders(
      "Raw parser traversal belongs in concrete language syntax adapters",
      offenders
    )
  end

  def test_generic_effect_and_protocol_engines_do_not_own_language_vocabularies
    files = %w[
      effects.rb
      protocols.rb
    ].map { |file_name| File.join(LIB, "syntax", file_name) }
    offenders = scan_files(
      files,
      "language vocabularies belong in syntax/<language>.rb" =>
        /\b(?:RUBY_|PYTHON_|JAVASCRIPT_|TYPESCRIPT_|RUST_|ZIG_|LUA_|GO_|CSHARP_|JAVA_|SWIFT_|KOTLIN_|PHP_|COMMON_CALLBACK_SET|T::Struct)\b/
    )

    assert_empty offenders, format_offenders(
      "Generic effect/protocol engines must expose registries, not language lexicons",
      offenders
    )
  end

  def test_normalized_extractor_does_not_own_stateful_enrichment_or_visibility
    file = File.join(LIB, "syntax", "normalized_extractor.rb")
    offenders = scan_files(
      [file],
      "stateful enrichment belongs in syntax/passes.rb or language behavior" =>
        /\b(?:apply_visibility|append_effects_from_calls|dedupe_semantic_effects|visibility_events_from_calls|public protected private)\b/,
      "declaration modifier/type vocabularies belong in language behavior" =>
        /%w\[[^\]]*\b(?:readonly|static|volatile|unsigned|signed|short|long|int|char|float|double|bool|string|var)\b[^\]]*\]/
    )

    assert_empty offenders, format_offenders(
      "NormalizedExtractor must remain a stateless normalized fact scanner",
      offenders
    )
  end

  private

  def scan_files(files, patterns)
    files.sort.flat_map do |path|
      rel = path.delete_prefix("#{ROOT}/")
      File.readlines(path, chomp: true).each_with_index.flat_map do |line, index|
        next if line.strip.start_with?("#")

        patterns.filter_map do |name, pattern|
          next unless line.match?(pattern)

          "#{rel}:#{index + 1}: #{name}: #{line.strip}"
        end
      end.compact
    end
  end

  def format_offenders(message, offenders)
    ([message] + offenders.map { |offender| "  #{offender}" }).join("\n")
  end
end
