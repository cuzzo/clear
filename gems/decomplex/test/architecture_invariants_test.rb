# frozen_string_literal: true

require "minitest/autorun"

class DecomplexArchitectureInvariantsTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  LIB = File.join(ROOT, "lib", "decomplex")
  DETECTOR_BASENAMES = %w[
    co_update decision_pressure derived_state false_simplicity fat_union
    flay_similarity function_lcom inconsistent_rename_clone local_flow
    locality_drag miner mutability_pressure operational_discontinuity
    ordered_protocol_mine oversized_predicate path_condition predicate_alias
    redundant_nil_guard semantic_alias sequence_mine site_extractor
    state_branch_density state_mesh structural_topology superfluous_state
    temporal_ordering_pressure weighted_inlined_cognitive_complexity
  ].freeze
  DETECTOR_FILES = DETECTOR_BASENAMES.map { |name| File.join(LIB, "#{name}.rb") }.freeze
  POST_SYNTAX_CONSUMER_BASENAMES = (
    DETECTOR_BASENAMES + %w[
      convergence delta report report_facts root_cause sarif
    ]
  ).uniq.freeze
  POST_SYNTAX_CONSUMER_FILES =
    POST_SYNTAX_CONSUMER_BASENAMES.map { |name| File.join(LIB, "#{name}.rb") }.freeze

  RAW_TREE_SITTER_PATTERNS = {
    "raw child traversal" => /(?<!\.)\.(?:children|named_children)\b/,
    "field lookup on raw nodes" => /\bchild_by_field_name\b/,
    "raw byte offsets" => /\b(?:start_byte|end_byte)\b/,
    "raw point offsets" => /\b(?:start_point|end_point)\b/,
    "Tree-sitter classes" => /\bTreeSitter(?:Adapter|LanguageAdapter|Normalizer|NodeFacade|FacadeContext)?\b/,
    "raw node predicate helpers" => /\b(?:ts_node\?|tree_sitter_node\?)\b/,
    "raw node duck typing" => /respond_to\?\s*\(\s*:children\s*\)/
  }.freeze
  ADAPTER_BOUNDARY_PATTERNS = RAW_TREE_SITTER_PATTERNS.merge(
    "syntax adapter profile access" => /\bSyntax\.language_profile\b|\blanguage_profile\s*\(/,
    "raw document root access" => /\bdocument\.root\b/,
    "normalized document root access" => /\bdocument\.normalized_root\b/
  ).freeze
  CONCRETE_LANGUAGE_BRANCH_PATTERNS = {
    "concrete language branch" =>
      /\b(?:case|when|if|elsif)\b.*(?::ruby|:python|:javascript|:typescript|:go|:rust|:zig|:lua|:c|:cpp|:csharp|:java|:swift|:kotlin|:php)\b|\blanguage\s*==\s*(?::ruby|:python|:javascript|:typescript|:go|:rust|:zig|:lua|:c|:cpp|:csharp|:java|:swift|:kotlin|:php)\b/
  }.freeze

  SYNTAX_RB_EXTENSION_HOST_PATTERNS = {
    "clone similarity belongs in syntax/clone_similarity.rb" => /\b(?:CloneCandidate|clone_candidates|CLONE_)/,
    "dispatch facts belong in syntax/dispatch.rb" => /\b(?:DispatchSite|dispatch_sites|DISPATCH_)/,
    "nil guard facts belong in syntax/nil_guards.rb" => /\b(?:NilGuard|redundant_nil_guard_findings)/,
    "local complexity facts belong in syntax/complexity.rb" => /\b(?:LocalComplexity|local_complexity_scores)/
  }.freeze
  SYNTAX_RB_ADAPTER_IMPLEMENTATION_PATTERNS = {
    "concrete language adapters belong under lib/decomplex/syntax/" =>
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

  def test_detectors_do_not_talk_to_tree_sitter_nodes_directly
    offenders = scan_files(DETECTOR_FILES, RAW_TREE_SITTER_PATTERNS)

    assert_empty offenders, format_offenders(
      "Detectors must consume Syntax facts instead of raw Tree-sitter nodes",
      offenders
    )
  end

  def test_post_syntax_consumers_do_not_cross_adapter_boundary
    offenders = scan_files(POST_SYNTAX_CONSUMER_FILES, ADAPTER_BOUNDARY_PATTERNS)

    assert_empty offenders, format_offenders(
      "Code after Syntax must consume facts instead of parser or adapter internals",
      offenders
    )
  end

  def test_post_syntax_consumers_do_not_branch_on_concrete_languages
    offenders = scan_files(POST_SYNTAX_CONSUMER_FILES, CONCRETE_LANGUAGE_BRANCH_PATTERNS)

    assert_empty offenders, format_offenders(
      "Code after Syntax must not contain language-specific branches",
      offenders
    )
  end

  def test_detector_specific_syntax_extensions_do_not_live_in_syntax_rb
    syntax_rb = File.join(LIB, "syntax.rb")
    offenders = scan_files([syntax_rb], SYNTAX_RB_EXTENSION_HOST_PATTERNS)

    assert_empty offenders, format_offenders(
      "Detector-facing parser extensions must live under lib/decomplex/syntax/",
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
