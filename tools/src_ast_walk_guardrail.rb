# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

module SrcAstWalkGuardrail
  extend T::Sig

  class Finding < T::Struct
    const :path, String
    const :line, Integer
    const :call, String
    const :classification, Symbol
    const :allowed, T::Boolean
    const :reason, String
    const :source, String
  end

  SOURCE_WALK_CALL = T.let(
    /
      AST\.(?:walk_body|each_locatable|each_bg_block|each_bg_block_in_stmt)|
      \bwalk_body\s*\(
    /x,
    Regexp,
  )

  ALLOWED_PREFIXES = T.let([
    "src/ast/",
    "src/parser/",
  ].freeze, T::Array[String])

  ALLOWED_FILES = T.let([
    "src/annotator/annotator.rb",
    "src/annotator/domains/errors.rb",
  ].freeze, T::Array[String])

  ALLOWED_ANNOTATOR_PREFIXES = T.let([
    "src/annotator/domains/",
    "src/annotator/helpers/",
    "src/annotator/phases/",
  ].freeze, T::Array[String])

  ALLOWED_HOIST_PREFIXES = T.let([
    "src/mir/hoist.rb",
    "src/mir/lowering/",
  ].freeze, T::Array[String])

  sig { params(root: String, paths: T::Array[String]).returns(T::Array[Finding]) }
  def self.scan(root:, paths:)
    paths.flat_map { |path| scan_file(root: root, path: path) }
  end

  sig { params(root: String, path: String).returns(T::Array[Finding]) }
  def self.scan_file(root:, path:)
    rel = relative_path(root: root, path: path)
    return [] unless rel.start_with?("src/") && rel.end_with?(".rb")

    File.readlines(path).filter_map.with_index do |line, idx|
      next if line.strip.start_with?("#")
      match = line.match(SOURCE_WALK_CALL)
      next unless match

      classification = classify_path(rel)
      allowed = allowed_classification?(classification)
      Finding.new(
        path: rel,
        line: idx + 1,
        call: T.must(match[0]),
        classification: classification,
        allowed: allowed,
        reason: reason_for(classification),
        source: line.strip,
      )
    end
  end

  sig { params(root: String, path: String).returns(String) }
  def self.relative_path(root:, path:)
    value = path.to_s
    prefix = "#{root}/"
    value.start_with?(prefix) ? value.delete_prefix(prefix) : value
  end
  private_class_method :relative_path

  sig { params(path: String).returns(Symbol) }
  def self.classify_path(path)
    return :syntax_or_parser if ALLOWED_PREFIXES.any? { |prefix| path.start_with?(prefix) }
    return :body_typing_or_diagnostic if ALLOWED_FILES.include?(path)
    return :body_typing_or_diagnostic if ALLOWED_ANNOTATOR_PREFIXES.any? { |prefix| path.start_with?(prefix) }
    return :hoist_or_lowering if ALLOWED_HOIST_PREFIXES.any? { |prefix| path.start_with?(prefix) }
    return :forbidden_semantic_rediscovery if path.start_with?("src/semantic/")
    return :forbidden_post_hoist_rediscovery if path.start_with?("src/mir/")

    :unknown
  end

  sig { params(classification: Symbol).returns(T::Boolean) }
  def self.allowed_classification?(classification)
    case classification
    when :syntax_or_parser, :body_typing_or_diagnostic, :hoist_or_lowering
      true
    else
      false
    end
  end
  private_class_method :allowed_classification?

  sig { params(classification: Symbol).returns(String) }
  def self.reason_for(classification)
    case classification
    when :syntax_or_parser
      "syntax construction/validation may traverse source AST"
    when :body_typing_or_diagnostic
      "annotation and diagnostics may traverse source AST before SemanticIndex freezes"
    when :hoist_or_lowering
      "hoist may be the last source-shaped consumer during migration"
    when :forbidden_semantic_rediscovery
      "semantic passes must consume BodyFacts/SemanticIndex instead of rediscovering source facts"
    when :forbidden_post_hoist_rediscovery
      "post-hoist MIR passes must consume hoisted IR/MIR facts instead of source AST"
    else
      "unclassified source AST walk"
    end
  end
  private_class_method :reason_for
end
