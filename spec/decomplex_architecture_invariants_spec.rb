require "rspec"

RSpec.describe "architecture invariants: decomplex syntax boundaries" do
  ROOT = File.expand_path("..", __dir__)
  DECOMPLEX_LIB = File.join(ROOT, "gems", "decomplex", "lib", "decomplex")
  DETECTOR_BASENAMES = %w[
    co_update decision_pressure derived_state false_simplicity fat_union
    flay_similarity function_lcom inconsistent_rename_clone local_flow
    locality_drag miner mutability_pressure operational_discontinuity
    ordered_protocol_mine oversized_predicate path_condition predicate_alias
    redundant_nil_guard semantic_alias sequence_mine site_extractor
    state_branch_density state_mesh structural_topology superfluous_state
    temporal_ordering_pressure weighted_inlined_cognitive_complexity
  ].freeze
  DETECTOR_FILES = DETECTOR_BASENAMES.map { |name| File.join(DECOMPLEX_LIB, "#{name}.rb") }.freeze

  RAW_TREE_SITTER_PATTERNS = {
    "raw child traversal" => /(?<!\.)\.(?:children|named_children)\b/,
    "field lookup on raw nodes" => /\bchild_by_field_name\b/,
    "raw byte offsets" => /\b(?:start_byte|end_byte)\b/,
    "raw point offsets" => /\b(?:start_point|end_point)\b/,
    "Tree-sitter classes" => /\bTreeSitter(?:Adapter|LanguageAdapter|Normalizer|NodeFacade|FacadeContext)?\b/,
    "raw node predicate helpers" => /\b(?:ts_node\?|tree_sitter_node\?)\b/,
    "raw node duck typing" => /respond_to\?\s*\(\s*:children\s*\)/
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

  def scan_files(files, patterns)
    files.sort.flat_map do |path|
      rel = path.delete_prefix("#{ROOT}/")
      File.readlines(path, chomp: true).each_with_index.flat_map do |line, index|
        next if line.strip.start_with?("#")

        patterns.filter_map do |name, pattern|
          "#{rel}:#{index + 1}: #{name}: #{line.strip}" if line.match?(pattern)
        end
      end.compact
    end
  end

  def format_offenders(message, offenders)
    ([message] + offenders.map { |offender| "  #{offender}" }).join("\n")
  end

  it "keeps detectors behind Syntax facts instead of raw Tree-sitter nodes" do
    offenders = scan_files(DETECTOR_FILES, RAW_TREE_SITTER_PATTERNS)

    expect(offenders).to be_empty,
      format_offenders("Detectors must consume Syntax facts instead of raw Tree-sitter nodes", offenders)
  end

  it "keeps detector-facing syntax extensions out of syntax.rb" do
    syntax_rb = File.join(DECOMPLEX_LIB, "syntax.rb")
    offenders = scan_files([syntax_rb], SYNTAX_RB_EXTENSION_HOST_PATTERNS)

    expect(offenders).to be_empty,
      format_offenders("Detector-facing parser extensions must live under lib/decomplex/syntax/", offenders)
  end

  it "keeps concrete language adapter implementation out of syntax.rb" do
    syntax_rb = File.join(DECOMPLEX_LIB, "syntax.rb")
    offenders = scan_files([syntax_rb], SYNTAX_RB_ADAPTER_IMPLEMENTATION_PATTERNS)

    expect(offenders).to be_empty,
      format_offenders("Core syntax.rb must not absorb concrete language adapter implementation", offenders)
  end

  it "keeps one adapter file per supported language" do
    offenders = LANGUAGE_ADAPTER_FILES.filter_map do |file_name, class_name|
      path = File.join(DECOMPLEX_LIB, "syntax", file_name)
      next "#{file_name}: missing file" unless File.file?(path)

      source = File.read(path)
      next if source.match?(/^\s*class\s+#{Regexp.escape(class_name)}\b/)

      "#{file_name}: missing #{class_name}"
    end

    expect(offenders).to be_empty,
      format_offenders("Every supported language must have an explicit adapter file", offenders)
  end

  it "keeps the adapter loader from absorbing language implementations" do
    adapters_rb = File.join(DECOMPLEX_LIB, "syntax", "adapters.rb")
    offenders = scan_files([adapters_rb], ADAPTER_LOADER_LANGUAGE_IMPLEMENTATION_PATTERNS)

    expect(offenders).to be_empty,
      format_offenders("Adapter loader must only load adapters and shared base helpers", offenders)
  end
end
