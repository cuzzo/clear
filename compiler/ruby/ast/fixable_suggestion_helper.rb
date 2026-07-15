# typed: strict

require "sorbet-runtime"
require_relative "source_error"

# Frontend-neutral typo suggestions. Hosts provide ErrorHelper's error! and
# fixable! methods; no annotation, scope, ownership, or semantic Type state is
# required.
module FixableSuggestionHelper
  extend T::Sig

  NameCandidate = T.type_alias { T.any(String, Symbol) }

  sig { params(input: NameCandidate, candidates: T::Enumerable[NameCandidate], max_distance: Integer).returns(T.nilable(String)) }
  def closest_name(input, candidates, max_distance: 3)
    best = T.let(nil, T.nilable(NameCandidate))
    best_distance = T.let(max_distance + 1, Integer)
    candidates.each do |candidate|
      distance = suggestion_levenshtein(input.to_s, candidate.to_s)
      if distance < best_distance
        best = candidate
        best_distance = distance
      end
    end
    best_distance <= max_distance ? best.to_s : nil
  end

  sig { params(token: T.nilable(TypoToken), name: String, candidates: T::Array[String], message: String, fix_label: String, category: Symbol, cascade: T::Boolean).returns(NilClass) }
  def emit_typo_suggestion!(token, name, candidates, message, fix_label,
                            category: :registry, cascade: true)
    token_line = T.cast(T.unsafe(token).line, Integer)
    token_column = T.cast(T.unsafe(token).column, Integer)
    best = closest_name(name, candidates)
    fixes = T.let([], T::Array[Fix])
    if best
      fixes << Fix.new(
        description: DiagnosticRegistry.fix_description(
          :REPLACE_IDENTIFIER_WITH_CANDIDATE,
          name: name,
          best: best,
          label: fix_label,
        ),
        confidence: :auto,
        edits: [Edit.new(
          span: Span.new(file: nil, line: token_line, col: token_column, length: name.length),
          replacement: best,
        )],
      )
    end

    return T.unsafe(self).error!(token, :TYPO_SUGGESTION_REJECTED, detail: message) if fixes.empty?

    T.unsafe(self).fixable!(token, code: :TYPO_SUGGESTION_REJECTED, detail: message,
                           category: category, level: :error,
                           fixes: fixes, raise_in_collector: cascade)
  end

  private

  sig { params(left: String, right: String).returns(Integer) }
  def suggestion_levenshtein(left, right)
    return right.length if left.empty?
    return left.length if right.empty?

    previous = (0..right.length).to_a
    left.each_char.with_index do |left_char, left_index|
      current = [left_index + 1]
      right.each_char.with_index do |right_char, right_index|
        cost = left_char == right_char ? 0 : 1
        current << [
          T.must(current[right_index]) + 1,
          T.must(previous[right_index + 1]) + 1,
          T.must(previous[right_index]) + cost,
        ].min
      end
      previous = current
    end
    T.must(previous.last)
  end
end
