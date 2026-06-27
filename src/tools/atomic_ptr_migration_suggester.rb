# typed: strict
require "sorbet-runtime"

require_relative "migration_suggester_helpers"

# Static eligibility detector for migrating struct-shaped locked/versioned
# bindings to `@indirect:atomic`.
#
# This is a TOOL, not an annotator pass. It runs from `clear doctor`
# combined with profile data, surfacing migration candidates only when both
# signals line up: hot lock and atomic-ptr-eligible use shape. Running it
# standalone in the annotator would fire on every cold struct.
#
# Eligibility (false-positive intolerant):
#
#   - The binding's type is a STRUCT. Single-field primitive bindings are
#     handled by the atomic-primitive suggester.
#   - The binding's sync is :locked / :write_locked (replace the lock with
#     rcu-publish) or :versioned (upgrade from MVCC, gated by mvcc-profile).
#   - Every use of the binding is the var_node of a WITH EXCLUSIVE (locked) or
#     WITH SNAPSHOT (versioned) capture.
#   - Every WITH-body statement is one of:
#      - Read-only: `_ = alias.field` / `x = alias.field` / etc.
#        (alias appears ONLY as target.field reads, not bare).
#      - Whole-struct replace: `alias = StructName{...}`
#        (the rcu publish shape — Atomic publish swaps a whole-T snapshot).
#      Field-level assignments (`alias.field = expr`) DISQUALIFY -- those
#      are the @shared:locked stay-put pattern, not atomic-ptr-fit.
#
# Returns Array of Candidate hashes; the doctor decides whether to
# surface based on the lock profile. Empty Array when nothing eligible.
#
# Shape boilerplate (analyze / analyze_fn / walk_recursive /
# classify_uses! / control_flow_stmt? / references_alias? /
# rhs_uses_alias_only_for_field_get?) lives in
# `MigrationSuggesterHelpers` and is shared with the atomic-primitive
# suggester. This module owns struct + whole-struct-replace eligibility and
# the per-family capability dispatch.
module AtomicPtrMigrationSuggester
  extend T::Sig

  extend MigrationSuggesterHelpers

  sig { params(source: String).returns(Array) }
  def self.analyze(source)
    run_analyze(source)
  end

  # Eligibility: STRUCT under :locked / :write_locked / :versioned sync. The
  # doctor gates :versioned candidates further with mvcc-profile signals.
  sig { params(node: AST::Node, _annotator: SemanticAnnotator).returns(T.nilable(Hash)) }
  def self.candidate_decl_info(node, _annotator)
    return nil unless node.is_a?(AST::VarDecl) || node.is_a?(AST::BindExpr)
    return nil unless node.name.is_a?(String)

    val = node.value
    val = val.value if val.is_a?(AST::CapabilityWrap)
    return nil unless val.is_a?(AST::StructLit)

    ti = node.full_type
    syn = ti.sync
    # Three sync families are atomic-ptr-fit candidates:
    #   - @locked / @writeLocked (replace-the-lock with rcu-publish)
    #   - @versioned when the cell only does single-cell whole-struct commits,
    #     gated by mvcc-profile multi_commits == 0.
    return nil unless syn == :locked || syn == :write_locked || syn == :versioned
    return nil unless ti.respond_to?(:struct?) && ti.struct?

    line = node.token&.line
    {
      name: node.name.to_s,
      decl_node: node,
      line: line,
      struct_name: ti.resolved,
      sync: syn,
      shared: ti.respond_to?(:shared?) ? ti.shared? : false,
      indirect: ti.respond_to?(:indirect?) ? ti.indirect? : false,
      n_uses: 0,
      disqualified: false,
    }
  end

  # WITH-block dispatch: per-family capability check. @writeLocked /
  # @locked accept EXCLUSIVE (write); @writeLocked also accepts an
  # inferred read-only WITH; @versioned accepts SNAPSHOT (read +
  # MUTABLE). Other capabilities DISQUALIFY.
  sig { params(with_node: AST::WithBlock, candidates: Hash).returns(Array) }
  def self.classify_with_block!(with_node, candidates)
    (with_node.capabilities || []).each do |cap|
      vn = cap[:var_node]
      next unless vn.is_a?(AST::Identifier)
      info = candidates[vn.name]
      next unless info

      cap_kind = cap[:capability]
      acceptable = if info[:sync] == :versioned
                     cap_kind == :SNAPSHOT
                   else
                     cap_kind == :EXCLUSIVE ||
                       (info[:sync] == :write_locked && cap_kind == :infer)
                   end
      unless acceptable
        info[:disqualified] = true
        next
      end

      alias_name = (cap[:alias] || vn.name).to_s
      if with_body_eligible?(with_node, alias_name, info[:struct_name])
        info[:n_uses] += 1
      else
        info[:disqualified] = true
      end
    end
  end

  # Each statement in the WITH body must be:
  #   - Read-only (alias appears only as target.field), OR
  #   - Whole-struct replace: `alias = StructName{...}`
  sig { params(with_node: AST::WithBlock, alias_name: String, struct_name: Symbol).returns(T::Boolean) }
  def self.with_body_eligible?(with_node, alias_name, struct_name)
    body = with_node.body
    return false unless body.is_a?(Array) && !body.empty?
    body.all? { |stmt| stmt_eligible?(stmt, alias_name, struct_name) }
  end

  sig { params(stmt: T.any(AST::Assignment, AST::BindExpr, AST::FuncCall), alias_name: String, struct_name: Symbol).returns(T::Boolean) }
  def self.stmt_eligible?(stmt, alias_name, struct_name)
    case stmt
    when AST::Assignment
      target = stmt.name
      # FIELD-LEVEL assignment: `alias.field = ...` -- DISQUALIFY (this
      # is the @shared:locked stay-put pattern, not atomic-ptr-fit).
      return false if target.is_a?(AST::GetField) &&
                      target.target.is_a?(AST::Identifier) &&
                      target.target.name == alias_name
      # WHOLE-STRUCT replace: `alias = StructName{...}` -- ELIGIBLE.
      return whole_struct_replace?(target, stmt.value, alias_name, struct_name) if alias_root?(target, alias_name)
      # Other targets reachable through the alias (e.g.
      # `arr[alias.field] = ...`) DISQUALIFY conservatively.
      !references_alias?(stmt, alias_name)
    when AST::BindExpr
      # `let-style` bind on the alias root would shadow; on a field,
      # it's a read. Only reads are eligible here; assignment-bind is
      # caught by the general references_alias? check below.
      target = stmt.name
      return false if target.is_a?(AST::GetField) &&
                      target.target.is_a?(AST::Identifier) &&
                      target.target.name == alias_name
      return whole_struct_replace?(target, stmt.value, alias_name, struct_name) if alias_root?(target, alias_name)
      rhs_uses_alias_only_for_field_get?(stmt, alias_name)
    else
      # Read-only statement (print, control flow, etc.). Eligible iff
      # any reference to the alias is a field read.
      return false if control_flow_stmt?(stmt)
      rhs_uses_alias_only_for_field_get?(stmt, alias_name)
    end
  end

  sig { params(target: T.any(AST::GetField, AST::Identifier, String), alias_name: String).returns(T::Boolean) }
  def self.alias_root?(target, alias_name)
    target == alias_name ||
      (target.is_a?(AST::Identifier) && target.name == alias_name)
  end

  sig { params(target: T.any(AST::GetField, AST::Identifier, String), rhs: AST::Node, alias_name: String, struct_name: String).returns(T::Boolean) }
  def self.whole_struct_replace?(target, rhs, alias_name, struct_name)
    alias_root?(target, alias_name) &&
      rhs.is_a?(AST::StructLit) &&
      rhs.name.to_s == struct_name.to_s
  end

  private_class_method :stmt_eligible?
  private_class_method :alias_root?
  private_class_method :whole_struct_replace?
  private_class_method :with_body_eligible?

end
