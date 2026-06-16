# frozen_string_literal: true

require "minitest/autorun"
require "tempfile"
require "json"
require_relative "../lib/decomplex"
require_relative "../lib/decomplex/report"

class ReportTest < Minitest::Test
  def report
    f = Tempfile.new(["rep", ".rb"])
    f.write("def a(n)\n  case n\n  when A then 1\n  when B then 2\n  end\nend\n" \
            "def b(n)\n  case n\n  when A then 3\n  when B then 4\n  end\nend\n")
    f.close
    Decomplex::Report.new([f.path])
  ensure
    @f = f
  end

  def test_nav_turns_file_method_line_into_navigable_link
    r = report
    assert_equal "`src/x.rb:15` (foo)", r.nav("src/x.rb:foo:15")
  end

  def test_nav_handles_top_level_and_colonless_paths
    r = report
    assert_equal "`a/b.rb:9` ((top-level))", r.nav("a/b.rb:(top-level):9")
  end

  def test_nav_passes_through_when_not_a_triple
    r = report
    assert_equal "already plain", r.nav("already plain")
  end

  def test_sarif_report_contains_rules_results_and_delta_snapshot
    sarif = JSON.parse(report.to_sarif)
    assert_equal "2.1.0", sarif.fetch("version")
    run = sarif.fetch("runs").first

    assert_equal "Decomplex", run.dig("tool", "driver", "name")
    assert_equal "decomplex.report.sarif.v1", run.dig("properties", "format")
    assert run.dig("properties", "decomplex.snapshot", "total").to_i.positive?
    assert run.dig("tool", "driver", "rules").any? { |rule| rule.fetch("id") == "decomplex.missing-abstractions" }
    assert run.fetch("results").all? { |result| result.fetch("ruleId").start_with?("decomplex.") }
  end

  def test_json_report_is_sarif_alias
    r = report
    assert_equal JSON.parse(r.to_sarif), JSON.parse(r.to_json)
  end

  def test_compact_sarif_omits_heavy_payloads_for_ci_uploads
    sarif = JSON.parse(report.to_sarif(include_snapshot: false, include_finding_payload: false, max_results: 2))
    run = sarif.fetch("runs").first

    refute run.fetch("properties").key?("decomplex.snapshot")
    assert_equal 2, run.fetch("results").size
    result = run.fetch("results").first
    assert result.fetch("properties").key?("tier")
    refute result.fetch("properties").key?("decomplex_finding")
  end

  def test_sarif_result_locations_use_report_finding_locations
    sarif = JSON.parse(report.to_sarif)
    result = sarif.fetch("runs").first.fetch("results").find do |entry|
      entry.fetch("ruleId") == "decomplex.missing-abstractions"
    end

    refute_nil result
    location = result.fetch("locations").first.fetch("physicalLocation")
    assert_match(/rep/, location.dig("artifactLocation", "uri"))
    assert_operator location.dig("region", "startLine"), :>=, 1
    assert result.fetch("partialFingerprints").fetch("decomplexFinding")
  end

  def test_sarif_message_includes_detector_specific_derived_state_context
    r = Decomplex::Report.allocate
    message = r.send(:sarif_message, "Derived-State Staleness", {
      derived: "style",
      source: "options",
      derived_at: 12,
      source_reassigned_at: 30
    }, {})

    assert_includes message, "`style` derived from `options` at line 12"
    assert_includes message, "`options` reassigned at line 30"
    assert_includes message, "`style` is not recomputed"
  end

  def test_sarif_message_includes_detector_specific_protocol_context
    r = Decomplex::Report.allocate
    message = r.send(:sarif_message, "Broken Protocols", {
      has: "lock",
      missing: "unlock",
      support: 8,
      confidence: 0.89
    }, {})

    assert_includes message, "does `lock` without co-called `unlock`"
    assert_includes message, "support=8"
    assert_includes message, "confidence=0.89"
  end

  def test_sarif_includes_actionable_state_heatmap_context
    f = Tempfile.new(["rep_state_sarif", ".rb"])
    f.write(<<~RB)
      class BillingService
        def set_user(user); @user = user; end
        def set_cart(cart); @cart = cart; end
        def process
          charge(@user) if @cart
          audit(@user)
        end
      end
    RB
    f.close

    sarif = JSON.parse(Decomplex::Report.new([f.path]).to_sarif)
    result = sarif.fetch("runs").first.fetch("results").find do |entry|
      entry.fetch("ruleId") == "decomplex.state-heatmap"
    end

    refute_nil result
    message = result.fetch("message").fetch("text")
    assert_includes message, "state `"
    assert_includes message, "writes="
    assert_includes message, "reads="
    assert_includes message, "writers"
  ensure
    f&.unlink
  end

  def test_markdown_orders_sections_by_signal_tier_not_volume
    md = report.to_markdown
    prio = md[/## Project Prioritization.*?\n\n(.*?)\n\n/m, 1].to_s
    # Missing Abstractions is tier 1; it must precede any tier-2/3
    # section even though others may have more candidates.
    mi = prio.index("Missing Abstractions")
    refute_nil mi
    %w[Neglected Broken].each do |noisy|
      idx = prio.index(noisy)
      assert(idx.nil? || mi < idx, "tier-1 must precede #{noisy}")
    end
  end

  def test_findings_are_marked_possible_not_likely_bug
    md = report.to_markdown
    refute_includes md, "likely bug"
    assert_includes md, "*POSSIBLE*"
  end

  def test_report_renders_state_heatmap_branch_density_and_temporal_ordering
    f = Tempfile.new(["rep_state", ".rb"])
    f.write(<<~RB)
      class BillingService
        def set_user(user); @user = user; end
        def set_cart(cart); @cart = cart; end
        def validate_user; fail unless @user; @validated = true; end
        def apply_discount; @discount = true if @cart; end
        def process_payment
          pay(@user, @cart, @discount) if @validated
        end
      end
    RB
    f.close

    md = Decomplex::Report.new([f.path]).to_markdown

    assert_includes md, "## State Heatmap"
    assert_includes md, "`user`"
    assert_includes md, "## State-Based Branch Density"
    assert_includes md, "state-based branch decision"
    assert_includes md, "## Temporal Ordering Pressure"
    assert_includes md, "BillingService"
    assert_includes md, "implicit lifecycle score"
  ensure
    f&.unlink
  end

  def test_report_renders_implicit_control_flow
    f = Tempfile.new(["rep_implicit_control_flow", ".rb"])
    f.write(<<~RB)
      class CompilerPhase
        def prepare; @phase = :prepared; end
        def validate; @valid = @phase == :prepared; end
        def commit; @committed = @valid; end

        def ok1; prepare; validate; commit; end
        def ok2; prepare; validate; commit; end
      end
    RB
    f.close

    md = Decomplex::Report.new([f.path]).to_markdown

    assert_includes md, "## Implicit Control Flow"
    assert_includes md, "prepare -> validate"
    assert_includes md, "protocol_pressure"
    assert_includes md, "write_read"
  ensure
    f&.unlink
  end

  def test_report_renders_weighted_inlined_cognitive_complexity
    f = Tempfile.new(["rep_weighted_inlined_complexity", ".rb"])
    f.write(<<~RB)
      class BillingService
        def checkout(user, cart)
          validate_user(user)
          reserve_inventory(cart)
          apply_discount(cart)
          process_payment(user, cart)
        end

        def validate_user(user)
          return false unless user
          if user.active? && !user.suspended?
            true
          end
        end

        def reserve_inventory(cart)
          if cart.available?
            if cart.quantity > 0
              reserve(cart)
            end
          end
        end

        def apply_discount(cart)
          if cart.total > 100 && eligible?
            if holiday?
              20
            else
              10
            end
          end
        end

        def process_payment(user, cart)
          if gateway.ready?
            if cart.total > 0 && user.active?
              charge(user, cart)
            end
          elsif gateway.retryable?
            retry_later(user)
          end
        end
      end
    RB
    f.close

    md = Decomplex::Report.new([f.path]).to_markdown

    assert_includes md, "## Weighted Inlined Cognitive Complexity"
    assert_includes md, "checkout ->"
    assert_includes md, "single-caller helpers"
  ensure
    f&.unlink
  end

  def test_report_renders_function_lcom_and_operational_discontinuity
    f = Tempfile.new(["rep_soc", ".rb"])
    f.write(<<~RB)
      class Billing
        def mixed(price, tax, logger)
          subtotal = price + tax
          total = subtotal * 2
          rounded = total.round

          timestamp = Time.now
          buffer = []
          buffer << timestamp
          logger.info(buffer)

          [rounded, buffer]
        end
      end

      class Importer
        def run(input)
          raw = input.fetch(:raw)
          normalized = raw.strip
          valid = normalized != ""

          # Phase 2: load side table
          path = "/tmp/table"
          bytes = File.read(path)
          checksum = bytes.hash
          checksum
        end
      end
    RB
    f.close

    md = Decomplex::Report.new([f.path]).to_markdown

    assert_includes md, "## Function LCOM"
    assert_includes md, "[late_join]"
    assert_includes md, "component 1"
    assert_includes md, "## Operational Discontinuity (High Confidence)"
    assert_includes md, "## Operational Discontinuity"
    assert_includes md, "reset_boundaries=1"
    assert_includes md, "confidence=high"
    assert_includes md, "load side table"
  ensure
    f&.unlink
  end

  def test_report_renders_locality_drag
    f = Tempfile.new(["rep_locality_drag", ".rb"])
    f.write(<<~RB)
      class Importer
        def run(user, cart, logger)
          receipt_id = user.id

          total = cart.total
          if total > 100
            if cart.discountable?
              discount = 10
            end
          end
          if cart.taxable?
            if cart.region
              tax = total * 0.2
            end
          end
          if logger.enabled?
            if logger.debug?
              logger.info(total)
            end
          end
          if cart.valid?
            if cart.ready?
              status = :ready
            end
          end

          emit(receipt_id)
        end
      end
    RB
    f.close

    md = Decomplex::Report.new([f.path]).to_markdown

    assert_includes md, "## Locality Drag"
    assert_includes md, "`receipt_id` dormant until line"
    assert_includes md, "unrelated line"
  ensure
    f&.unlink
  end
end
