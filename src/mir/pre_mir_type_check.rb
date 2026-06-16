# typed: false
# pre_mir_type_check.rb -- AST→MIR boundary invariant.
#
# Every evaluatable AST node (anything that includes the typed-node
# mixin, i.e. responds to :full_type) MUST have a resolved type by the
# time annotation is done -- Void for statements / void expressions,
# a concrete Type for everything else. A nil full_type reaching MIR is
# the type system failing to stamp the node: a COMPILER bug, never a
# user syntax error.
#
# Structural / declaration nodes (StructDef, EnumDef, UnionDef,
# RequireNode, Extern*) do not evaluate to a value and do not include
# the typed-node mixin, so they are excluded automatically: the mixin
# presence IS the "this node should have a type" classifier.
#
# Runs once, right before MIRPass. With PREMIR_SURVEY=1 it collects and
# prints the distinct offending node classes instead of raising (used
# to inventory annotator holes); default behavior raises the ICE.
require "sorbet-runtime"

require_relative "../semantic/pass_state"

module PreMirTypeCheck
  extend T::Sig

  class InternalTypeResolutionError < StandardError; end

  LEAVES = [Symbol, String, Numeric, TrueClass, FalseClass, NilClass].freeze
  WalkNode = T.type_alias { T.nilable(T.any(AST::Node, AST::RawBody, T::Hash[BasicObject, BasicObject], Symbol, String, Numeric, TrueClass, FalseClass, Type)) }
  Violation = T.type_alias { T::Hash[Symbol, String] }


  sig { params(program: AST::Program).returns(NilClass) }
  def self.verify!(program)
    MIRPassState.require!(program, :hoisted, consumer: "PreMirTypeCheck")
    violations = []
    walk(program, violations, {})
    if violations.empty?
      MIRPassState.for!(program).mark!(:premir_type_checked)
      return
    end

    if ENV["PREMIR_SURVEY"] == "1"
      by_class = violations.group_by { |v| v[:cls] }
                           .transform_values(&:size)
                           .sort_by { |_, n| -n }
      warn "[pre-mir-survey] #{violations.size} untyped node(s):"
      by_class.each { |c, n| warn format("  %5d  %s", n, c) }
      return
    end

    sample = violations.first(30)
                       .map { |v| "  - #{v[:cls]} @ #{v[:loc]}" }
                       .join("\n")
    more = violations.size > 30 ? "\n  ... (+#{violations.size - 30} more)" : ""
    raise InternalTypeResolutionError, <<~MSG
      Internal Compiler Error: #{violations.size} AST node(s) reached MIR
      lowering without a resolved type (full_type is the :Untyped
      sentinel). Every evaluatable node must be typed (Void for
      statements / void expressions) by the end of annotation.

      This is a bug in the CLEAR compiler, not an error in your
      program. Sorry for the inconvenience -- please report it.

      #{sample}#{more}
    MSG
  end

  # Generic structural recursion: AST nodes are Structs (each_pair),
  # bodies are Arrays, some carry Hashes. Type / Token and scalars are
  # leaves. object_id memo guards shared-reference cycles.
  sig { params(node: WalkNode, violations: T::Array[Violation], seen: T::Hash[Integer, T::Boolean]).void }
  def self.walk(node, violations, seen)
    return if node.nil? || LEAVES.any? { |k| node.is_a?(k) }
    return if defined?(Type) && node.is_a?(Type)
    oid = node.object_id
    return if seen[oid]
    seen[oid] = true

    if node.is_a?(AST::Locatable) && node.full_type.untyped?
      tok = node.respond_to?(:token) ? node.token : nil
      loc = tok && tok.respond_to?(:line) ? "#{tok.line}:#{tok.column}" : "?"
      violations << { cls: node.class.name.to_s.split("::").last, loc: loc }
    end

    if node.is_a?(Array)
      node.each { |c| walk(c, violations, seen) }
    elsif node.is_a?(Hash)
      node.each_value { |v| walk(v, violations, seen) }
    elsif node.respond_to?(:each_pair) # Struct AST node
      T.unsafe(node).each_pair do |member, value|
        next if node.is_a?(AST::FunctionDef) && member == :return_lifetime
        walk(value, violations, seen)
      end
    end
  end
  private_class_method :walk

end
