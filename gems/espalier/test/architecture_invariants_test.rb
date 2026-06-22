# frozen_string_literal: true

require "minitest/autorun"

class EspalierArchitectureInvariantsTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  LIB = File.join(ROOT, "lib", "espalier")

  def test_generic_architecture_code_does_not_define_type_builtin_lists
    files = %w[
      alias_recommendations.rb
      architecture_analyzer.rb
      dependency_graph.rb
      static_helpers.rb
    ].map { |file| File.join(LIB, file) }

    offenders = scan_files(
      files,
      "generic Espalier must not own type builtin lists" =>
        /\b(?:CORE_TYPES|CORE_CLASS_CONSTANTS|BROAD_TYPE_PATTERN|owner_type_tokens)\b/
    )

    assert_empty offenders, offenders.join("\n")
  end

  def test_ruby_sorbet_guard_lattice_lives_in_fact_mine_ruby_provider
    file = File.join(LIB, "fact_mine_static_facts.rb")
    offenders = scan_files(
      [file],
      "Ruby guard/type lattice belongs in FactMine syntax/ruby.rb" =>
        /\b(?:CORE_RUNTIME_GUARD_CLASSES|NUMERIC_GUARD_SUBCLASSES|BOOLEAN_GUARD_SUBCLASSES|known_guard_subclass|known_disjoint_guard_classes)\b/
    )

    assert_empty offenders, offenders.join("\n")
  end

  private

  def scan_files(files, patterns)
    files.flat_map do |path|
      rel = path.delete_prefix("#{ROOT}/")
      File.readlines(path, chomp: true).each_with_index.filter_map do |line, index|
        next if line.strip.start_with?("#")

        matches = patterns.filter_map do |message, pattern|
          "#{rel}:#{index + 1}: #{message}: #{line.strip}" if line.match?(pattern)
        end
        matches.empty? ? nil : matches
      end
    end.flatten
  end
end
