# frozen_string_literal: true

require "minitest/autorun"
require "tempfile"
require_relative "../lib/decomplex/operational_discontinuity"

class OperationalDiscontinuityTest < Minitest::Test
  def test_flags_blank_or_comment_boundary_where_locals_reset
    out = scan(<<~RB)
      class Importer
        def run(input)
          raw = input.fetch(:raw)
          normalized = raw.strip
          valid = normalized != ""

          # load side table
          path = "/tmp/table"
          bytes = File.read(path)
          checksum = bytes.hash
          checksum
        end
      end
    RB

    run = out.find { |finding| finding[:method] == "run" }

    refute_nil run
    assert_equal 1, run[:resets]
    reset = run[:reset_points].first
    assert_includes reset[:dead], "raw"
    assert_includes reset[:dead], "normalized"
    assert_includes reset[:new], "path"
    assert_includes reset[:new], "checksum"
    assert_equal :comment, reset[:kind]
    assert_equal :review, run[:confidence]
    assert_empty run[:confidence_reasons]
  end

  def test_does_not_flag_boundary_when_prior_variable_continues
    out = scan(<<~RB, min_score: 1)
      class Importer
        def run(input)
          raw = input.fetch(:raw)
          normalized = raw.strip

          payload = normalized.upcase
          write(payload)
        end
      end
    RB

    assert_empty out
  end

  def test_marks_repeated_or_explicit_phase_resets_high_confidence
    out = scan(<<~RB)
      class Importer
        def run(input)
          raw = input.fetch(:raw)
          normalized = raw.strip
          valid = normalized != ""

          # Phase 2: load side table
          path = "/tmp/table"
          bytes = File.read(path)
          checksum = bytes.hash

          # Phase 3: emit summary
          payload = checksum.to_s
          destination = "/tmp/out"
          File.write(destination, payload)
        end
      end
    RB

    run = out.find { |finding| finding[:method] == "run" }

    refute_nil run
    assert_equal :high, run[:confidence]
    assert_includes run[:confidence_reasons], :repeated_resets
    assert_includes run[:confidence_reasons], :explicit_phase_marker
  end

  def test_keeps_parser_grammar_resets_review_confidence_without_phase_marker
    out = scan(<<~RB)
      class Parser
        def parse_body(token)
          result = parse_rule(token)
          rule = result.rule

          expr = parse_expr
          binding_name = expr.name
          next_expr = parse_expr

          # THEN chain: expr AS name THEN expr
          steps = []
          next_binding = next_expr.name
          steps << [binding_name, next_binding]
          steps
        end
      end
    RB

    parse_body = out.find { |finding| finding[:method] == "parse_body" }

    refute_nil parse_body
    assert_equal :review, parse_body[:confidence]
    assert_empty parse_body[:confidence_reasons]
  end

  private

  def scan(
    code,
    min_dead: Decomplex::OperationalDiscontinuity::DEFAULT_MIN_DEAD,
    min_new: Decomplex::OperationalDiscontinuity::DEFAULT_MIN_NEW,
    max_continuing: Decomplex::OperationalDiscontinuity::DEFAULT_MAX_CONTINUING,
    min_score: Decomplex::OperationalDiscontinuity::DEFAULT_MIN_SCORE
  )
    file = Tempfile.new(["operational_discontinuity", ".rb"])
    file.write(code)
    file.close
    Decomplex::OperationalDiscontinuity.scan(
      [file.path],
      min_dead: min_dead,
      min_new: min_new,
      max_continuing: max_continuing,
      min_score: min_score
    )
  ensure
    file&.unlink
  end
end
