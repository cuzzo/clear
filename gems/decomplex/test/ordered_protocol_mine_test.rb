# frozen_string_literal: true

require "minitest/autorun"
require "tempfile"
require_relative "../lib/decomplex"

class OrderedProtocolMineTest < Minitest::Test
  def setup
    @files = []
  end

  def teardown
    @files.each(&:unlink)
  end

  def scan(src)
    file = Tempfile.new(["ordered_protocol", ".rb"])
    file.write(src)
    file.close
    @files << file
    Decomplex::OrderedProtocolMine.scan([file.path])
  end

  def test_flags_reversed_state_dependent_internal_call_order
    report = scan(<<~RB)
      class CompilerPhase
        def prepare; @phase = :prepared; end
        def validate; @valid = @phase == :prepared; end
        def commit; @committed = @valid; end

        def ok1; prepare(node); validate(node); commit(node); end
        def ok2; prepare(node); validate(node); commit(node); end
        def ok3; prepare(node); validate(node); commit(node); end
        def ok4; prepare(node); validate(node); commit(node); end
        def drift; validate(node); prepare(node); commit(node); end
      end
    RB

    findings = report.drift(min_support: 4)
    hit = findings.find { |row| row[:at].include?("drift") }
    refute_nil hit
    assert_equal :order_drift, hit[:kind]
    assert_equal %w[prepare validate], hit[:protocol]
    assert_equal %w[validate prepare], hit[:observed]
    assert_equal %w[write_read], hit[:dependency]
    assert_equal %w[phase], hit[:states]
  end

  def test_scan_does_not_use_legacy_ast_parse
    file = Tempfile.new(["ordered_protocol", ".rb"])
    file.write(<<~RB)
      class CompilerPhase
        def prepare; @phase = :prepared; end
        def validate; @valid = @phase; end
        def run; prepare; validate; end
      end
    RB
    file.close
    @files << file

    Decomplex::Ast.stub(:parse, ->(*) { raise "legacy Ast.parse called" }) do
      report = Decomplex::OrderedProtocolMine.scan([file.path])
      refute_empty report.ordered_protocols
    end
  end

  def test_reports_single_state_dependent_protocol_pressure
    report = scan(<<~RB)
      class BillingService
        def validate_user; @user_valid = @user != nil; end
        def apply_discount; @discount = @user_valid ? 10 : 0; end
        def checkout; validate_user; apply_discount; end
      end
    RB

    hit = report.ordered_protocols.find do |row|
      row[:protocol] == %w[validate_user apply_discount]
    end
    refute_nil hit
    assert_equal :protocol_pressure, hit[:kind]
    assert_equal 1, hit[:support]
    assert_equal %w[write_read], hit[:dependency]
    assert_equal %w[user_valid], hit[:states]
  end

  def test_pure_call_order_does_not_define_implicit_control_flow
    report = scan(<<~RB)
      class CompilerPhase
        def ok1; prepare(node); validate(node); commit(node); end
        def ok2; prepare(node); validate(node); commit(node); end
        def ok3; prepare(node); validate(node); commit(node); end
        def ok4; prepare(node); validate(node); commit(node); end
        def missing; prepare(node); validate(node); end
      end
    RB

    assert_empty report.ordered_protocols
    assert_empty report.drift(min_support: 4)
  end

  def test_independent_state_writes_do_not_define_order_protocol
    report = scan(<<~RB)
      class CompilerPhase
        def prepare; @phase = :prepared; end
        def record; @log = :recorded; end

        def ok1; prepare; record; end
        def ok2; prepare; record; end
        def ok3; prepare; record; end
        def ok4; prepare; record; end
        def drift; record; prepare; end
      end
    RB

    assert_empty report.ordered_protocols
    assert_empty report.drift(min_support: 4)
  end

  def test_case_dispatch_branches_do_not_define_order_protocol
    report = scan(<<~RB)
      class LoweringPhase
        def lower_if(node); @out = node; end
        def lower_if_bind(node); @out = node; end

        def lower(node)
          out = case node
          when :if then lower_if(node)
          when :if_bind then lower_if_bind(node)
          end
          out
        end
      end
    RB

    assert_empty report.ordered_protocols
  end

  def test_case_without_condition_keeps_when_and_else_paths_separate
    report = scan(<<~RB)
      class LoweringPhase
        def ready?; @ready; end
        def prepare; @phase = :prepared; end
        def validate; @valid = @phase; end

        def lower
          case
          when ready? then prepare
          else validate
          end
        end
      end
    RB

    assert_empty report.ordered_protocols
  end

  def test_nested_if_branches_do_not_define_order_protocol
    report = scan(<<~RB)
      class LoweringPhase
        def prepare(node); @out = node; end
        def validate(node); @out = node; end

        def lower(node)
          result = if node
            prepare(node)
          else
            validate(node)
          end
          result
        end
      end
    RB

    assert_empty report.ordered_protocols
  end

  def test_explicit_self_calls_are_internal_protocol_calls
    report = scan(<<~RB)
      class CompilerPhase
        def prepare; @phase = :prepared; end
        def validate; @valid = @phase; end
        def run; self.prepare; self.validate; end
      end
    RB

    hit = report.ordered_protocols.find { |row| row[:protocol] == %w[prepare validate] }
    refute_nil hit
    assert_equal %w[write_read], hit[:dependency]
  end

  def test_self_attribute_writes_match_self_reader_state
    report = scan(<<~RB)
      class CompilerPhase
        def prepare; self.status = :ready; end
        def validate; @valid = status == :ready; end
        def run; prepare; validate; end
      end
    RB

    hit = report.ordered_protocols.find { |row| row[:protocol] == %w[prepare validate] }
    refute_nil hit
    assert_equal %w[status], hit[:states]
  end

  def test_singleton_methods_keep_state_effects
    report = scan(<<~RB)
      class CompilerPhase
        def self.prepare; @phase = :prepared; end
        def self.validate; @valid = @phase; end
        def self.run; prepare; validate; end
      end
    RB

    hit = report.ordered_protocols.find { |row| row[:protocol] == %w[prepare validate] }
    refute_nil hit
    assert_equal %w[phase], hit[:states]
  end

  def test_unique_stateful_method_name_is_used_as_conservative_fallback
    report = scan(<<~RB)
      class LibraryPhase
        def prepare; @phase = :prepared; end
        def validate; @valid = @phase; end
      end

      class RunnerPhase
        def run; prepare; validate; end
      end
    RB

    hit = report.ordered_protocols.find { |row| row[:protocol] == %w[prepare validate] }
    refute_nil hit
    assert_equal %w[phase], hit[:states]
  end

  def test_receiver_and_index_mutations_are_state_effects
    report = scan(<<~RB)
      class BufferPhase
        def push_item; @items.push(1); end
        def clear_items; @items.clear; end
        def set_item; @items[:last] = 1; end
        def run; push_item; clear_items; set_item; end
      end
    RB

    assert report.ordered_protocols.any? { |row| row[:protocol] == %w[push_item clear_items] }
    assert report.ordered_protocols.any? { |row| row[:protocol] == %w[clear_items set_item] }
  end

  def test_receiver_attribute_writes_are_state_effects
    report = scan(<<~RB)
      class ConfigPhase
        def first; config.enabled = true; end
        def second; config.enabled = false; end
        def run; first; second; end
      end
    RB

    hit = report.ordered_protocols.find { |row| row[:protocol] == %w[first second] }
    refute_nil hit
    assert_equal %w[config.enabled], hit[:states]
  end

  def test_diagnostic_calls_do_not_define_protocol_pressure
    report = scan(<<~RB)
      class CompilerPhase
        def prepare; @phase = :prepared; end
        def error!; @phase = :errored; end
        def run; prepare; error!; end
      end
    RB

    assert_empty report.ordered_protocols
  end

  def test_declarative_calls_inside_methods_are_ignored
    report = scan(<<~RB)
      class CompilerPhase
        def prepare; @phase = :prepared; end
        def validate; @valid = @phase; end
        def run; private; prepare; validate; end
      end
    RB

    refute report.ordered_protocols.any? { |row| row[:protocol].include?("private") }
    assert report.ordered_protocols.any? { |row| row[:protocol] == %w[prepare validate] }
  end

  def test_min_support_filters_single_site_protocol_pressure
    report = scan(<<~RB)
      class CompilerPhase
        def prepare; @phase = :prepared; end
        def validate; @valid = @phase; end
        def run; prepare; validate; end
      end
    RB

    assert_empty report.ordered_protocols(min_support: 2)
  end

  def test_negated_predicate_calls_do_not_write_fake_state
    report = scan(<<~RB)
      class PredicatePhase
        def first(value); !value.empty?; end
        def second(value); !value.empty?; end
        def run(value); first(value); second(value); end
      end
    RB

    assert_empty report.ordered_protocols
  end

  def test_external_receiver_calls_are_not_mined_as_internal_protocols
    report = scan(<<~RB)
      class CompilerPhase
        def ok1; backend.prepare(node); backend.validate(node); backend.commit(node); end
        def ok2; backend.prepare(node); backend.validate(node); backend.commit(node); end
        def ok3; backend.prepare(node); backend.validate(node); backend.commit(node); end
        def ok4; backend.prepare(node); backend.validate(node); backend.commit(node); end
        def drift; backend.validate(node); backend.prepare(node); backend.commit(node); end
      end
    RB

    assert_empty report.drift(min_support: 4)
    assert_empty report.ordered_protocols
  end

  def test_terminal_guard_branch_does_not_pollute_normal_path_order
    report = scan(<<~RB)
      class PipelinePhase
        def ok1; with_soa_tracking(node) { visit(node) }; stamp_type!(node); end
        def ok2; with_soa_tracking(node) { visit(node) }; stamp_type!(node); end
        def ok3; with_soa_tracking(node) { visit(node) }; stamp_type!(node); end
        def ok4; with_soa_tracking(node) { visit(node) }; stamp_type!(node); end

        def guarded(node)
          unless node.valid?
            error!(node)
            stamp_type!(node)
            return
          end

          with_soa_tracking(node) do
            visit(node)
          end
          stamp_type!(node)
        end
      end
    RB

    finding = report.drift(min_support: 4).find do |row|
      row[:at].include?("guarded") &&
        row[:protocol] == %w[with_soa_tracking visit stamp_type!]
    end
    assert_nil finding
  end

  def test_optional_diagnostic_calls_do_not_define_required_protocols
    report = scan(<<~RB)
      class LoopPhase
        def ok1; visit(cond); error!(cond); analyze_loop_control_flow_branches(body); end
        def ok2; visit(cond); error!(cond); analyze_loop_control_flow_branches(body); end
        def ok3; visit(cond); error!(cond); analyze_loop_control_flow_branches(body); end
        def ok4; visit(cond); error!(cond); analyze_loop_control_flow_branches(body); end
        def normal; visit(cond); analyze_loop_control_flow_branches(body); end
      end
    RB

    assert_empty report.drift(min_support: 4)
  end

  def test_lambda_callback_bodies_do_not_define_builder_method_protocols
    report = scan(<<~RB)
      class HostBuilder
        def ok1; Host.new(a: -> { prepare(node) }, b: -> { validate(node) }, c: -> { commit(node) }); end
        def ok2; Host.new(a: -> { prepare(node) }, b: -> { validate(node) }, c: -> { commit(node) }); end
        def ok3; Host.new(a: -> { prepare(node) }, b: -> { validate(node) }, c: -> { commit(node) }); end
        def ok4; Host.new(a: -> { prepare(node) }, b: -> { validate(node) }, c: -> { commit(node) }); end
        def missing; Host.new(a: -> { prepare(node) }, b: -> { validate(node) }); end
      end
    RB

    assert_empty report.drift(min_support: 4)
  end

  def test_earlier_generic_call_does_not_hide_later_ordered_protocol
    report = scan(<<~RB)
      class LoweringPhase
        def ok1; with_decl_alloc(:heap) { lower(value); place_value_for_destination(value) }; end
        def ok2; with_decl_alloc(:heap) { lower(value); place_value_for_destination(value) }; end
        def ok3; with_decl_alloc(:heap) { lower(value); place_value_for_destination(value) }; end
        def ok4; with_decl_alloc(:heap) { lower(value); place_value_for_destination(value) }; end
        def mixed; lower(target); with_decl_alloc(:heap) { lower(value); place_value_for_destination(value) }; end
      end
    RB

    finding = report.drift(min_support: 4).find { |row| row[:at].include?("mixed") }
    assert_nil finding
  end
end
