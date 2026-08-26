#!/usr/bin/env ruby
# frozen_string_literal: true

# Per-function byte-compatibility harness.
#
# A clean transpile says nothing about behaviour: every silent-wrongness bug
# found so far (a mutation landing on a discarded COPY, a Ruby block `return`
# becoming a lambda RETURN, stamps written through a copying visitor) compiles
# fine. This harness measures the thing that matters instead -- for a target
# function, RECORD every (arguments, result) the Ruby compiler produces over a
# corpus, then REPLAY the same arguments through the self-hosted CLEAR function
# and compare the encoded results byte for byte.
#
#   ruby tools/fn_compat.rb --record --out tmp/fn-compat
#   ruby tools/fn_compat.rb --replay --out tmp/fn-compat
#
# Targets live in TARGETS: a Ruby entry point, the CLEAR function that must
# match it, and the scalar shape of its arguments. Scalar-shaped leaves are
# the beachhead; graph-shaped inputs (Type, SymbolEntry, Locatable) reuse
# parser_compat.rb's canonical encoders once the leaves hold.
require 'json'
require 'fileutils'
require 'optparse'
require 'set'
require 'open3'

saved_program_name = $PROGRAM_NAME
$PROGRAM_NAME = 'fn_compat_support'
require_relative 'parser_compat'
$PROGRAM_NAME = saved_program_name

module FnCompat
  extend self

  SCHEMA = 'clear.fn.compat.v1'

  Target = Struct.new(:name, :ruby_require, :ruby_call, :clear_unit, :clear_call, :arg_types, :result_type, :prelude, keyword_init: true)

  TARGETS = [
    Target.new(
      name: 'zig_type.reserved_identifier?',
      ruby_require: 'compiler/ruby/backends/zig_type',
      ruby_call: ->(args) { ZigType.reserved_identifier?(*args) },
      clear_unit: 'backends/zig_type.clear',
      clear_call: 'zigType__reserved_identifier?',
      arg_types: %i[zig_name],
      result_type: :bool
    ),
    Target.new(
      name: 'zig_type.primitive_numeric_identifier?',
      ruby_require: 'compiler/ruby/backends/zig_type',
      ruby_call: ->(args) { ZigType.primitive_numeric_identifier?(*args) },
      clear_unit: 'backends/zig_type.clear',
      clear_call: 'zigType__primitive_numeric_identifier?',
      arg_types: %i[zig_name],
      result_type: :bool
    ),
    Target.new(
      name: 'zig_type.float_identifier?',
      ruby_require: 'compiler/ruby/backends/zig_type',
      ruby_call: ->(args) { ZigType.float_identifier?(*args) },
      clear_unit: 'backends/zig_type.clear',
      clear_call: 'zigType__float_identifier?',
      arg_types: %i[zig_name],
      result_type: :bool
    ),
    Target.new(
      name: 'zig_type.integer_identifier?',
      ruby_require: 'compiler/ruby/backends/zig_type',
      ruby_call: ->(args) { ZigType.integer_identifier?(*args) },
      clear_unit: 'backends/zig_type.clear',
      clear_call: 'zigType__integer_identifier?',
      arg_types: %i[zig_name],
      result_type: :bool
    ),
    Target.new(
      name: 'effect_set.to_s',
      ruby_require: 'compiler/ruby/semantic/effect_set',
      ruby_call: ->(args) { EffectSet.new(Set.new(args.first)).to_s },
      clear_unit: 'semantic/effect_set.clear',
      clear_call: 'TRY (effectSet__to_s(fnCompatEffects))',
      prelude: '  fnCompatEffects = TRY (effectSet__new(%s));',
      arg_types: %i[effect_set],
      result_type: :string
    ),
    Target.new(
      name: 'effect_set.empty?',
      ruby_require: 'compiler/ruby/semantic/effect_set',
      ruby_call: ->(args) { EffectSet.new(Set.new(args.first)).empty? },
      clear_unit: 'semantic/effect_set.clear',
      clear_call: 'effectSet__empty?(fnCompatEffects)',
      prelude: '  fnCompatEffects = TRY (effectSet__new(%s));',
      arg_types: %i[effect_set],
      result_type: :bool
    ),
    Target.new(
      name: 'ownership_edge_planner.move_op',
      ruby_require: 'compiler/ruby/semantic/ownership_edge_planner',
      ruby_call: ->(args) { OwnershipEdgePlanner.move_op(*args) },
      clear_unit: 'semantic/ownership_edge_planner.clear',
      clear_call: 'ownershipEdgePlanner__move_op',
      arg_types: %i[carrier],
      result_type: :symbol
    ),
    Target.new(
      name: 'ownership_edge_planner.keep_op',
      ruby_require: 'compiler/ruby/semantic/ownership_edge_planner',
      ruby_call: ->(args) { OwnershipEdgePlanner.keep_op(*args) },
      clear_unit: 'semantic/ownership_edge_planner.clear',
      clear_call: 'ownershipEdgePlanner__keep_op',
      arg_types: %i[carrier],
      result_type: :symbol
    ),
    Target.new(
      name: 'type.signed_integer_symbol?',
      ruby_require: 'compiler/ruby/ast/type',
      ruby_call: ->(args) { Type.signed_integer_symbol?(*args) },
      clear_unit: 'ast/type.clear',
      clear_call: 'type__signed_integer_symbol?',
      arg_types: %i[type_symbol],
      result_type: :bool
    ),
    Target.new(
      name: 'type.unsigned_integer_symbol?',
      ruby_require: 'compiler/ruby/ast/type',
      ruby_call: ->(args) { Type.unsigned_integer_symbol?(*args) },
      clear_unit: 'ast/type.clear',
      clear_call: 'type__unsigned_integer_symbol?',
      arg_types: %i[type_symbol],
      result_type: :bool
    ),
    Target.new(
      name: 'type.integer_symbol?',
      ruby_require: 'compiler/ruby/ast/type',
      ruby_call: ->(args) { Type.integer_symbol?(*args) },
      clear_unit: 'ast/type.clear',
      clear_call: 'type__integer_symbol?',
      arg_types: %i[type_symbol],
      result_type: :bool
    ),
    Target.new(
      name: 'type.float_symbol?',
      ruby_require: 'compiler/ruby/ast/type',
      ruby_call: ->(args) { Type.float_symbol?(*args) },
      clear_unit: 'ast/type.clear',
      clear_call: 'type__float_symbol?',
      arg_types: %i[type_symbol],
      result_type: :bool
    ),
    Target.new(
      name: 'type.numeric_symbol?',
      ruby_require: 'compiler/ruby/ast/type',
      ruby_call: ->(args) { Type.numeric_symbol?(*args) },
      clear_unit: 'ast/type.clear',
      clear_call: 'type__numeric_symbol?',
      arg_types: %i[type_symbol],
      result_type: :bool
    ),
    Target.new(
      name: 'type.primitive_symbol?',
      ruby_require: 'compiler/ruby/ast/type',
      ruby_call: ->(args) { Type.primitive_symbol?(*args) },
      clear_unit: 'ast/type.clear',
      clear_call: 'type__primitive_symbol?',
      arg_types: %i[type_symbol],
      result_type: :bool
    ),
    Target.new(
      name: 'type.resource_type_symbol?',
      ruby_require: 'compiler/ruby/ast/type',
      ruby_call: ->(args) { Type.resource_type_symbol?(*args) },
      clear_unit: 'ast/type.clear',
      clear_call: 'type__resource_type_symbol?',
      arg_types: %i[type_symbol],
      result_type: :bool
    ),
    Target.new(
      name: 'type.sync_family_name_for',
      ruby_require: 'compiler/ruby/ast/type',
      ruby_call: ->(args) { Type.sync_family_name_for(*args) },
      clear_unit: 'ast/type.clear',
      clear_call: 'type__sync_family_name_for',
      arg_types: %i[sync_symbol],
      result_type: :opt_string
    ),
    Target.new(
      name: 'type.zig_type_name_for',
      ruby_require: 'compiler/ruby/ast/type',
      ruby_call: ->(args) { Type.zig_type_name_for(*args) },
      clear_unit: 'ast/type.clear',
      clear_call: 'type__zig_type_name_for',
      arg_types: %i[type_symbol],
      result_type: :string
    ),
    Target.new(
      name: 'type.logical_op?',
      ruby_require: 'compiler/ruby/ast/type',
      ruby_call: ->(args) { Type.logical_op?(*args) },
      clear_unit: 'ast/type.clear',
      clear_call: 'type__logical_op?',
      arg_types: %i[op_symbol],
      result_type: :bool
    ),
    Target.new(
      name: 'type.equality_op?',
      ruby_require: 'compiler/ruby/ast/type',
      ruby_call: ->(args) { Type.equality_op?(*args) },
      clear_unit: 'ast/type.clear',
      clear_call: 'type__equality_op?',
      arg_types: %i[op_symbol],
      result_type: :bool
    ),
    Target.new(
      name: 'type.ordering_op?',
      ruby_require: 'compiler/ruby/ast/type',
      ruby_call: ->(args) { Type.ordering_op?(*args) },
      clear_unit: 'ast/type.clear',
      clear_call: 'type__ordering_op?',
      arg_types: %i[op_symbol],
      result_type: :bool
    ),
    Target.new(
      name: 'type.bool_result_op?',
      ruby_require: 'compiler/ruby/ast/type',
      ruby_call: ->(args) { Type.bool_result_op?(*args) },
      clear_unit: 'ast/type.clear',
      clear_call: 'type__bool_result_op?',
      arg_types: %i[op_symbol],
      result_type: :bool
    ),
    Target.new(
      name: 'type.number_result_op?',
      ruby_require: 'compiler/ruby/ast/type',
      ruby_call: ->(args) { Type.number_result_op?(*args) },
      clear_unit: 'ast/type.clear',
      clear_call: 'type__number_result_op?',
      arg_types: %i[op_symbol],
      result_type: :bool
    ),
    Target.new(
      name: 'type.bitwise_op?',
      ruby_require: 'compiler/ruby/ast/type',
      ruby_call: ->(args) { Type.bitwise_op?(*args) },
      clear_unit: 'ast/type.clear',
      clear_call: 'type__bitwise_op?',
      arg_types: %i[op_symbol],
      result_type: :bool
    ),
    Target.new(
      name: 'type.shift_op?',
      ruby_require: 'compiler/ruby/ast/type',
      ruby_call: ->(args) { Type.shift_op?(*args) },
      clear_unit: 'ast/type.clear',
      clear_call: 'type__shift_op?',
      arg_types: %i[op_symbol],
      result_type: :bool
    ),
    Target.new(
      name: 'type.integer_type_max',
      ruby_require: 'compiler/ruby/ast/type',
      ruby_call: ->(args) { Type.integer_type_max(*args) },
      clear_unit: 'ast/type.clear',
      clear_call: 'type__integer_type_max',
      arg_types: %i[type_symbol],
      result_type: :opt_int
    ),
    Target.new(
      name: 'type.integer_type_min',
      ruby_require: 'compiler/ruby/ast/type',
      ruby_call: ->(args) { Type.integer_type_min(*args) },
      clear_unit: 'ast/type.clear',
      clear_call: 'type__integer_type_min',
      arg_types: %i[type_symbol],
      result_type: :opt_int
    ),
    Target.new(
      name: 'type.integer_string',
      ruby_require: 'compiler/ruby/ast/type',
      ruby_call: ->(args) { Type.integer_string(*args) },
      clear_unit: 'ast/type.clear',
      clear_call: 'type__integer_string',
      arg_types: %i[int64],
      result_type: :string
    ),
    Target.new(
      name: 'type.symbol_or_any',
      ruby_require: 'compiler/ruby/ast/type',
      ruby_call: ->(args) { Type.symbol_or_any(*args) },
      clear_unit: 'ast/type.clear',
      clear_call: 'type__symbol_or_any',
      arg_types: %i[opt_type_symbol],
      result_type: :symbol
    ),
    Target.new(
      name: 'symbol_entry.atomic_sync?',
      ruby_require: 'compiler/ruby/ast/symbol_entry',
      ruby_call: ->(args) { SymbolEntry.atomic_sync?(*args) },
      clear_unit: 'ast/symbol_entry.clear',
      clear_call: 'symbolEntry__atomic_sync?',
      arg_types: %i[opt_sync_symbol],
      result_type: :bool
    ),
    Target.new(
      name: 'symbol_entry.locked_sync?',
      ruby_require: 'compiler/ruby/ast/symbol_entry',
      ruby_call: ->(args) { SymbolEntry.locked_sync?(*args) },
      clear_unit: 'ast/symbol_entry.clear',
      clear_call: 'symbolEntry__locked_sync?',
      arg_types: %i[opt_sync_symbol],
      result_type: :bool
    ),
    Target.new(
      name: 'symbol_entry.write_locked_sync?',
      ruby_require: 'compiler/ruby/ast/symbol_entry',
      ruby_call: ->(args) { SymbolEntry.write_locked_sync?(*args) },
      clear_unit: 'ast/symbol_entry.clear',
      clear_call: 'symbolEntry__write_locked_sync?',
      arg_types: %i[opt_sync_symbol],
      result_type: :bool
    ),
    Target.new(
      name: 'symbol_entry.versioned_sync?',
      ruby_require: 'compiler/ruby/ast/symbol_entry',
      ruby_call: ->(args) { SymbolEntry.versioned_sync?(*args) },
      clear_unit: 'ast/symbol_entry.clear',
      clear_call: 'symbolEntry__versioned_sync?',
      arg_types: %i[opt_sync_symbol],
      result_type: :bool
    ),
    Target.new(
      name: 'symbol_entry.local_sync?',
      ruby_require: 'compiler/ruby/ast/symbol_entry',
      ruby_call: ->(args) { SymbolEntry.local_sync?(*args) },
      clear_unit: 'ast/symbol_entry.clear',
      clear_call: 'symbolEntry__local_sync?',
      arg_types: %i[opt_sync_symbol],
      result_type: :bool
    ),
    Target.new(
      name: 'symbol_entry.always_mutable_sync?',
      ruby_require: 'compiler/ruby/ast/symbol_entry',
      ruby_call: ->(args) { SymbolEntry.always_mutable_sync?(*args) },
      clear_unit: 'ast/symbol_entry.clear',
      clear_call: 'symbolEntry__always_mutable_sync?',
      arg_types: %i[opt_sync_symbol],
      result_type: :bool
    ),
    Target.new(
      name: 'symbol_entry.locked_family_sync?',
      ruby_require: 'compiler/ruby/ast/symbol_entry',
      ruby_call: ->(args) { SymbolEntry.locked_family_sync?(*args) },
      clear_unit: 'ast/symbol_entry.clear',
      clear_call: 'symbolEntry__locked_family_sync?',
      arg_types: %i[opt_sync_symbol],
      result_type: :bool
    ),
    Target.new(
      name: 'symbol_entry.cleanup_sync?',
      ruby_require: 'compiler/ruby/ast/symbol_entry',
      ruby_call: ->(args) { SymbolEntry.cleanup_sync?(*args) },
      clear_unit: 'ast/symbol_entry.clear',
      clear_call: 'symbolEntry__cleanup_sync?',
      arg_types: %i[opt_sync_symbol],
      result_type: :bool
    ),
    Target.new(
      name: 'symbol_entry.sync_matches?',
      ruby_require: 'compiler/ruby/ast/symbol_entry',
      ruby_call: ->(args) { SymbolEntry.sync_matches?(*args) },
      clear_unit: 'ast/symbol_entry.clear',
      clear_call: 'symbolEntry__sync_matches?',
      arg_types: %i[opt_sync_symbol sync_symbol],
      result_type: :bool
    ),
    Target.new(
      name: 'symbol_entry.rc_storage?',
      ruby_require: 'compiler/ruby/ast/symbol_entry',
      ruby_call: ->(args) { SymbolEntry.rc_storage?(*args) },
      clear_unit: 'ast/symbol_entry.clear',
      clear_call: 'symbolEntry__rc_storage?',
      arg_types: %i[opt_storage_symbol],
      result_type: :bool
    ),
    Target.new(
      name: 'symbol_entry.heap_storage_value?',
      ruby_require: 'compiler/ruby/ast/symbol_entry',
      ruby_call: ->(args) { SymbolEntry.heap_storage_value?(*args) },
      clear_unit: 'ast/symbol_entry.clear',
      clear_call: 'symbolEntry__heap_storage_value?',
      arg_types: %i[opt_storage_symbol],
      result_type: :bool
    ),
    Target.new(
      name: 'symbol_entry.frame_storage_value?',
      ruby_require: 'compiler/ruby/ast/symbol_entry',
      ruby_call: ->(args) { SymbolEntry.frame_storage_value?(*args) },
      clear_unit: 'ast/symbol_entry.clear',
      clear_call: 'symbolEntry__frame_storage_value?',
      arg_types: %i[opt_storage_symbol],
      result_type: :bool
    ),
    Target.new(
      name: 'symbol_entry.local_storage_value?',
      ruby_require: 'compiler/ruby/ast/symbol_entry',
      ruby_call: ->(args) { SymbolEntry.local_storage_value?(*args) },
      clear_unit: 'ast/symbol_entry.clear',
      clear_call: 'symbolEntry__local_storage_value?',
      arg_types: %i[opt_storage_symbol],
      result_type: :bool
    ),
    Target.new(
      name: 'error_registry.kind_of_type',
      ruby_require: 'compiler/ruby/ast/error_registry',
      ruby_call: ->(args) { AST.kind_of_type(*args) },
      clear_unit: 'ast/error_registry.clear',
      clear_call: 'TRY (aST__kind_of_type(%s))',
      arg_types: %i[error_type_symbol],
      result_type: :opt_symbol
    ),
    Target.new(
      name: 'function_return.variant',
      ruby_require: 'compiler/ruby/annotator/helpers/function_return',
      ruby_call: ->(args) { FunctionReturn.variant(*args).kind.serialize },
      clear_unit: 'annotator/helpers/function_return.clear',
      clear_call: '(TRY (functionReturn__variant(%s))).kind',
      arg_types: %i[function_return_variant],
      result_type: :function_return_kind
    ),
    Target.new(
      name: 'effects.display',
      ruby_require: 'compiler/ruby/annotator/helpers/effects',
      ruby_call: ->(args) { EffectTracker.display(*args) },
      clear_unit: 'annotator/helpers/effects.clear',
      clear_call: 'effectTracker__display(%s)',
      arg_types: %i[effect_symbol],
      result_type: :string
    ),
    Target.new(
      name: 'error_registry.zig_name_of_type',
      ruby_require: 'compiler/ruby/ast/error_registry',
      ruby_call: ->(args) { AST.zig_name_of_type(*args) },
      clear_unit: 'ast/error_registry.clear',
      clear_call: 'TRY (aST__zig_name_of_type(%s))',
      arg_types: %i[error_type_symbol],
      result_type: :opt_string
    ),
    Target.new(
      name: 'error_registry.id_of_type',
      ruby_require: 'compiler/ruby/ast/error_registry',
      ruby_call: ->(args) { AST.id_of_type(*args) },
      clear_unit: 'ast/error_registry.clear',
      clear_call: 'TRY (aST__id_of_type(%s))',
      arg_types: %i[error_type_symbol],
      result_type: :opt_int
    ),
    Target.new(
      name: 'type_capabilities.ownership_surface_name_for',
      ruby_require: 'compiler/ruby/ast/type_capabilities',
      ruby_call: ->(args) { TypeCapabilities.ownership_surface_name_for(*args) },
      clear_unit: 'ast/type_capabilities.clear',
      clear_call: 'typeCapabilities__ownership_surface_name_for',
      arg_types: %i[ownership_symbol],
      result_type: :opt_string
    ),
    Target.new(
      name: 'type_capabilities.sync_surface_name_for',
      ruby_require: 'compiler/ruby/ast/type_capabilities',
      ruby_call: ->(args) { TypeCapabilities.sync_surface_name_for(*args) },
      clear_unit: 'ast/type_capabilities.clear',
      clear_call: 'typeCapabilities__sync_surface_name_for',
      arg_types: %i[cap_sync_symbol],
      result_type: :opt_string
    ),
    Target.new(
      name: 'diagnostic_registry.known?',
      ruby_require: 'compiler/ruby/ast/diagnostic_registry',
      ruby_call: ->(args) { DiagnosticRegistry.known?(*args) },
      clear_unit: 'ast/diagnostic_registry.clear',
      clear_call: 'diagnosticRegistry__known?',
      arg_types: %i[diagnostic_code],
      result_type: :bool
    ),
    Target.new(
      name: 'diagnostic_registry.pending?',
      ruby_require: 'compiler/ruby/ast/diagnostic_registry',
      ruby_call: ->(args) { DiagnosticRegistry.pending?(*args) },
      clear_unit: 'ast/diagnostic_registry.clear',
      clear_call: 'diagnosticRegistry__pending?',
      arg_types: %i[diagnostic_code],
      result_type: :bool
    ),
    Target.new(
      name: 'diagnostic_registry.positional_placeholder_count',
      ruby_require: 'compiler/ruby/ast/diagnostic_registry',
      ruby_call: ->(args) { DiagnosticRegistry.positional_placeholder_count(*args) },
      clear_unit: 'ast/diagnostic_registry.clear',
      clear_call: 'diagnosticRegistry__positional_placeholder_count',
      arg_types: %i[template_string],
      result_type: :int
    ),
    Target.new(
      name: 'placement.alloc',
      ruby_require: 'compiler/ruby/mir/placement',
      ruby_call: ->(args) { MIR::Placement.alloc(*args) },
      clear_unit: 'mir/placement.clear',
      clear_call: 'placement__alloc',
      arg_types: %i[opt_symbol symbol],
      result_type: :symbol
    ),
    Target.new(
      name: 'placement.heap?',
      ruby_require: 'compiler/ruby/mir/placement',
      ruby_call: ->(args) { MIR::Placement.heap?(*args) },
      clear_unit: 'mir/placement.clear',
      clear_call: 'placement__heap?',
      arg_types: %i[opt_symbol],
      result_type: :bool
    ),
    Target.new(
      name: 'placement.frame?',
      ruby_require: 'compiler/ruby/mir/placement',
      ruby_call: ->(args) { MIR::Placement.frame?(*args) },
      clear_unit: 'mir/placement.clear',
      clear_call: 'placement__frame?',
      arg_types: %i[opt_symbol],
      result_type: :bool
    ),
    Target.new(
      name: 'placement.explicit_heap?',
      ruby_require: 'compiler/ruby/mir/placement',
      ruby_call: ->(args) { MIR::Placement.explicit_heap?(*args) },
      clear_unit: 'mir/placement.clear',
      clear_call: 'placement__explicit_heap?',
      arg_types: %i[opt_symbol],
      result_type: :bool
    )
  ].freeze

  # The inputs a target is exercised with. Recording from a live compile is the
  # end state; an explicit domain is what makes the first leaves runnable today
  # and keeps the comparison total rather than sampled.
  DOMAINS = {
    opt_symbol: [nil, :heap, :frame, :stack, :rodata, :borrow, :none],
    symbol: %i[heap frame],
    carrier: %i[plain multiowned shared],
    effect_set: [[], [:yield], [:io, :yield], [:alloc_heap, :fail, :io, :yield], [:fail]],
    zig_name: ['u8', 'i64', 'f32', 'f0', 'u', 'i', 'f', 'usize', 'fn', 'var', 'const', 'anytype',
               'x64', 'u8x', 'i128', 'f64', 'bool', 'struct', 'Type', ''],
    bool: [true, false],
    type_symbol: %i[Int8 Int16 Int32 Int64 UInt8 Byte UInt16 UInt32 UInt64 TargetInt TargetLong
                    TargetLongLong TargetUInt TargetULong TargetULongLong Float32 Float64 String
                    Bool Void Any File Socket Widget],
    opt_type_symbol: [nil, :Int64, :String, :Any],
    op_symbol: %i[AND OR NOT EQ NEQ LT GT LTE GTE ADD SUB MUL DIV MOD POW SHL SHR BAND BOR BXOR
                  CONCAT IN RANGE],
    sync_symbol: %i[locked writeLocked write_locked atomic versioned local always_mutable raw symbol],
    opt_sync_symbol: [nil, :locked, :writeLocked, :write_locked, :atomic, :versioned, :local,
                      :always_mutable, :shared, :multiowned, :sharded],
    opt_storage_symbol: [nil, :heap, :frame, :stack, :local, :multiowned, :shared, :rodata, :borrow],
    ownership_symbol: %i[affine multiowned shared node shared_node split link frozen copy],
    cap_sync_symbol: %i[locked write_locked versioned atomic always_mutable local raw symbol c size none],
    error_type_symbol: %i[LockTimeout LockCycle Deadlock UnexpectedRecursion MaxDepthExceeded
                          MvccConflict AtomicConflict GuardFail PreconditionFail OutOfMemory Nope],
    diagnostic_code: %i[UNWRAP_NON_OPTIONAL ILLEGAL_FIELD_LOOKUP FALLIBLE_METHOD_RECEIVER
                        IS_OK_REQUIRES_FALLIBLE OPTIONAL_FIELD_REQUIRES_SAFE_NAV NOT_A_REAL_CODE],
    template_string: ['plain text', 'one %{a}', '%{a} and %{b}', 'positional {0}', '{0} then {1}',
                      '{0}{1}{2}', 'mixed %{a} {0}', ''],
    function_return_variant: %i[Fixed ElementOf OptionalOfElement IdOfElement OptionalOfValue
                                ValueList KeyList Infer],
    effect_symbol: %i[SUSPENDS SUSPENDS_CONDITIONAL SUSPENDS_LOOP HEAP BLOCKING REENTRANT
                      LOOP_UNBOUND EXTERN YIELD IO CONTENTION CONTENTION_MAYBE BLOCKING_MAYBE
                      NOT_AN_EFFECT],
    int64: [0, 1, -1, 7, 42, 255, -128, 1024, -99999]
  }.freeze

  def main(argv)
    options = { out_dir: File.expand_path('tmp/fn-compat'), mode: nil, only: nil, keep: false }
    OptionParser.new do |parser|
      parser.banner = 'Usage: ruby tools/fn_compat.rb [--record|--replay] [options]'
      parser.on('--record', 'Record Ruby results for every target') { options[:mode] = :record }
      parser.on('--replay', 'Replay recorded inputs through CLEAR and compare') { options[:mode] = :replay }
      parser.on('--out DIR') { |v| options[:out_dir] = File.expand_path(v) }
      parser.on('--only NAME') { |v| options[:only] = v }
      parser.on('--units GLOB', 'Only targets whose clear_unit matches this substring list (comma-separated)') { |v| options[:units] = v.split(',') }
      parser.on('--skip-units GLOB', 'Drop targets whose clear_unit matches any of these substrings') { |v| options[:skip_units] = v.split(',') }
      parser.on('--keep', 'Keep the generated CLEAR harness and binary') { options[:keep] = true }
      parser.on('-h', '--help') { puts parser; exit 0 }
    end.parse!(argv)

    targets = TARGETS.reject { |t| t.clear_unit == 'mir/placement.clear' }
    targets = targets.select { |t| options[:units].any? { |u| t.clear_unit.include?(u) } } if options[:units]
    targets = targets.reject { |t| options[:skip_units].any? { |u| t.clear_unit.include?(u) } } if options[:skip_units]
    targets = TARGETS.select { |t| t.name == options[:only] } if options[:only]
    abort 'fn_compat: no targets selected' if targets.empty?
    FileUtils.mkdir_p(options[:out_dir])

    case options[:mode]
    when :record then record(targets, options)
    when :replay then replay(targets, options)
    else
      record(targets, options)
      replay(targets, options)
    end
  end

  def record(targets, options)
    payload = { 'schema' => SCHEMA, 'implementation' => 'ruby', 'targets' => [] }
    targets.each do |target|
      require File.expand_path(target.ruby_require, __dir__ + '/..')
      calls = argument_tuples(target).map do |args|
        { 'args' => args.map { |a| encode_scalar(a) }, 'result' => encode_scalar(target.ruby_call.call(args)) }
      end
      payload['targets'] << { 'name' => target.name, 'calls' => calls }
    end
    path = File.join(options[:out_dir], 'ruby.json')
    File.write(path, JSON.pretty_generate(payload))
    puts "recorded #{payload['targets'].sum { |t| t['calls'].length }} calls across #{payload['targets'].length} targets -> #{path}"
    0
  end

  def replay(targets, options)
    recorded = JSON.parse(File.read(File.join(options[:out_dir], 'ruby.json')))
    by_name = recorded['targets'].to_h { |t| [t['name'], t['calls']] }

    dir = File.join(options[:out_dir], 'build')
    FileUtils.mkdir_p(dir)
    source = File.join(dir, 'fn_compat.clear')
    binary = File.join(dir, 'fn_compat')
    File.write(source, clear_source(targets, by_name))

    # The harness is one long main plus the target's whole package; the default
    # fiber stack overflows once the corpus is more than a few dozen calls.
    build = %w[./clear build] + [source, '-o', binary, '--no-stack-check',
                                 '--default-stack', 'Huge'] + package_flags
    # zig_type.clear and friends call into compiler_regex.zig; the native dir
    # and its pcre2 link have to travel with the harness build.
    env = {
      'CLEAR_DISABLE_BUILD_ZIG' => '1',
      'CLEAR_EXTRA_LINK_LIBS' => 'pcre2-8',
      'CLEAR_EXTRA_NATIVE_DIRS' => File.expand_path('compiler/src', __dir__ + '/..')
    }
    _out, err, status = Open3.capture3(env, *build)
    unless status.success?
      limit = ENV['FN_COMPAT_ERROR_LIMIT']&.to_i || 12
      warn "fn_compat: CLEAR build failed\n#{err.lines.grep(/Error|error/).first(limit).join}"
      return 1
    end
    stdout, stderr, status = Open3.capture3(env, binary)
    stdout = stderr if stdout.empty?
    warn "fn_compat: CLEAR exited #{status.exitstatus}" unless status.success?

    actual = stdout.lines.map(&:chomp).reject(&:empty?).map { |line| line.split('|', 3) }
    mismatches = 0
    total = 0
    targets.each do |target|
      calls = by_name.fetch(target.name, [])
      calls.each_with_index do |call, index|
        total += 1
        got = actual.find { |t, i, _| t == target.name && i.to_i == index }&.last
        next if got == call['result']

        mismatches += 1
        puts "MISMATCH #{target.name}[#{index}] args=#{call['args'].inspect} ruby=#{call['result'].inspect} clear=#{got.inspect}"
      end
    end
    FileUtils.rm_rf(dir) unless options[:keep]
    puts "fn_compat: #{total - mismatches}/#{total} calls byte-identical across #{targets.length} targets"
    mismatches.zero? ? 0 : 1
  end

  def argument_tuples(target)
    domains = target.arg_types.map { |kind| DOMAINS.fetch(kind) }
    domains[1..].inject(domains.first.map { |v| [v] }) do |acc, domain|
      acc.flat_map { |prefix| domain.map { |v| prefix + [v] } }
    end
  end

  def encode_scalar(value)
    case value
    when Array        then "[#{value.map { |v| encode_scalar(v) }.join(',')}]"
    when nil          then 'nil'
    when true, false  then value.to_s
    when Symbol       then ":#{value}"
    when String       then "\"#{value}\""
    when Integer      then value.to_s
    else raise "fn_compat: unsupported scalar #{value.class}"
    end
  end

  def clear_literal(encoded)
    if encoded.start_with?('[')
      inner = encoded[1..-2].to_s
      members = inner.empty? ? [] : inner.split(',')
      return 'fnCompatEmptySet()' if members.empty?

      return "Set[#{members.map { |m| clear_literal(m) }.join(', ')}]"
    end
    return 'NIL' if encoded == 'nil'
    return encoded.upcase if %w[true false].include?(encoded)
    return "symbol(\"#{encoded[1..]}\")" if encoded.start_with?(':')

    encoded
  end

  # Render the result through a helper FN rather than a reassigned slot: a slot
  # frees its previous value on reassignment, and these results are often
  # .rodata. A helper also keeps each runner's frame small.
  RENDERERS = {
    function_return_kind: 'fnCompatFunctionReturnKindText',
    bool: 'fnCompatBoolText',
    symbol: 'fnCompatSymbolText',
    string: 'fnCompatStringText',
    int: 'fnCompatIntText',
    opt_string: 'fnCompatOptStringText',
    opt_symbol: 'fnCompatOptSymbolText',
    opt_int: 'fnCompatOptIntText',
  }.freeze

  RENDERER_DEFS = <<~CLEAR
    PRIVATE FN fnCompatFunctionReturnKindText(value: Kind) RETURNS String ->
      # Ruby's `Kind#serialize` returns a String, so this renders like one --
      # quoted -- or every call reads as a mismatch against its own text.
      IF (value == Kind.Fixed) THEN RETURN fnCompatStringText("fixed"); END
      IF (value == Kind.ElementOf) THEN RETURN fnCompatStringText("element_of"); END
      IF (value == Kind.OptionalOfElement) THEN RETURN fnCompatStringText("optional_of_element"); END
      IF (value == Kind.IdOfElement) THEN RETURN fnCompatStringText("id_of_element"); END
      IF (value == Kind.OptionalOfValue) THEN RETURN fnCompatStringText("optional_of_value"); END
      IF (value == Kind.ValueList) THEN RETURN fnCompatStringText("value_list"); END
      IF (value == Kind.KeyList) THEN RETURN fnCompatStringText("key_list"); END
      RETURN fnCompatStringText("infer");
    END
    PRIVATE FN fnCompatBoolText(value: Bool) RETURNS String ->
      IF value THEN
        RETURN "true";
      END
      RETURN "false";
    END
    PRIVATE FN fnCompatSymbolText(value: String@symbol) RETURNS String ->
      RETURN ":" $+ CAST(value AS String);
    END
    PRIVATE FN fnCompatStringText(value: String) RETURNS String ->
      RETURN "\\"" $+ value $+ "\\"";
    END
    PRIVATE FN fnCompatIntText(value: Int64) RETURNS String ->
      RETURN value.toString();
    END
    PRIVATE FN fnCompatOptStringText(value: ?String) RETURNS String ->
      IF value EXISTS AS present THEN
        RETURN "\\"" $+ present $+ "\\"";
      END
      RETURN "nil";
    END
    PRIVATE FN fnCompatOptSymbolText(value: ?String@symbol) RETURNS String ->
      IF value EXISTS AS present THEN
        RETURN ":" $+ CAST(present AS String);
      END
      RETURN "nil";
    END
    PRIVATE FN fnCompatOptIntText(value: ?Int64) RETURNS String ->
      IF value EXISTS AS present THEN
        RETURN present.toString();
      END
      RETURN "nil";
    END
  CLEAR

  def clear_source(targets, by_name)
    units = targets.map(&:clear_unit).uniq
    requires = units.map { |unit| "REQUIRE \"pkg:rtoc_#{unit.unpack1('H*')}\";" }.join("\n")
    # One FN per target: a single main holding every call overflows the fiber
    # stack once the corpus is more than a few dozen calls.
    runners = targets.each_with_index.map do |target, target_index|
      calls = by_name.fetch(target.name, []).each_with_index.map do |call, index|
        args = call['args'].map { |a| clear_literal(a) }.join(', ')
        expr = if target.prelude
                 target.clear_call
               elsif target.clear_call.include?('%s')
                 format(target.clear_call, args)
               else
                 "#{target.clear_call}(#{args})"
               end
        renderer = RENDERERS.fetch(target.result_type)
        lines = []
        lines << format(target.prelude, args) if target.prelude
        lines << "  print(\"#{target.name}|#{index}|\" $+ #{renderer}(#{expr}));"
        lines.join("\n")
      end
      slots = []
      slots << '  MUTABLE fnCompatEffects: EffectSet@multiowned = TRY (effectSet__new(fnCompatEmptySet()));' if target.prelude
      name = "fnCompatRun#{target_index}"
      ["PRIVATE FN #{name}() RETURNS !Void ->", *slots, *calls, 'END'].join("\n")
    end
    body = runners.each_index.map { |i| "  TRY (fnCompatRun#{i}());" }.join("\n")
    runner_defs = runners.join("\n")

    <<~CLEAR
      #{requires}

      PRIVATE FN fnCompatEmptySet() RETURNS [Set]String@symbol ->
        MUTABLE empty: [Set]String@symbol = Set[];
        RETURN empty;
      END

      #{RENDERER_DEFS}

      #{runner_defs}

      FN main() RETURNS !Void ->
      #{body}
      END
    CLEAR
  end

  # compiler/src has REQUIRE cycles (type <-> schemas), so the units must be
  # registered as the SCC-merged packages parser_compat.rb already builds.
  def package_flags
    root = File.expand_path('compiler/src', __dir__ + '/..')
    ParserCompat.package_flags(root) +
      ['--pkg', "fs=#{File.expand_path('stdlib/fs/src/lib.clear', __dir__ + '/..')}",
       '--pkg', "path=#{File.expand_path('stdlib/path/src/lib.clear', __dir__ + '/..')}"]
  end
end

exit(FnCompat.main(ARGV)) if $PROGRAM_NAME.end_with?('fn_compat.rb')
