# typed: strict
require "sorbet-runtime"

require_relative "migration_suggester_helpers"

# Static eligibility detector for `@shared:locked` / `@locked` to
# `@shared:atomic` migration.
#
# This is a TOOL, not an annotator pass. It runs from `clear doctor`
# (combined with lock-profile contention data), surfacing migration
# candidates only when both signals line up: hot lock + atomic-
# eligible use shape. Running it standalone in the annotator would
# fire on every cold counter, not just the ones where the migration
# matters.
#
# Eligibility is intentionally narrow (false-positive intolerant):
#
#   - The binding's type is a STRUCT with exactly ONE field whose
#     declared type is Int64, Float64, or Bool.
#   - The binding's sync is :locked (NOT :write_locked — RWLocks
#     have read+write semantics that don't map to a single Atomic).
#   - Every use of the binding is the var_node of a WITH EXCLUSIVE
#     capture, and every statement in each WITH body is one of:
#        - `alias.field`            (read)
#        - `alias.field = expr`     where `expr` references `alias`
#                                    only as `alias.field` and only as
#                                    the bare LHS-on-RHS of `+ N` /
#                                    `- N` (the `+=` / `-=` desugar)
#   - The wrapper struct doesn't escape: not passed to a function,
#     returned, stored in a heap container, or referenced outside
#     the WITH alias-binding contract.
#
# Returns an Array of Candidate hashes; the doctor decides whether
# to surface based on the lock profile. Empty Array when nothing
# eligible.
#
# Shape boilerplate (analyze / analyze_fn / walk_recursive /
# classify_uses! / control_flow_stmt? / references_alias? /
# rhs_uses_alias_only_for_field_get?) lives in
# `MigrationSuggesterHelpers` and is shared with the atomic-ptr suggester.
# This module owns single-primitive-field struct eligibility and
# compound-arith-rewriteable WITH bodies.
module AtomicMigrationSuggester
  extend T::Sig

  module_function
  extend MigrationSuggesterHelpers

  ATOMIC_ELIGIBLE_FIELD_TYPES = %i[Int64 Float64 Bool].to_set.freeze

  # Public entry point. `source` is the CLEAR source string (typically
  # read from `<binary>.profile/source.cht`). Returns
  # `[{ name:, line:, struct_name:, field_name:, field_type:, shared:,
  #     n_uses: }, ...]` for every eligible binding, sorted by line.
  # Returns [] on parse / annotate errors (the doctor falls back to its
  # existing lock-only diagnosis).
  def analyze(source)
    run_analyze(source)
  end

  # Eligibility: STRUCT with exactly one Int64/Float64/Bool field
  # under :locked sync (NOT :write_locked -- RWLocks don't map cleanly
  # to a single Atomic primitive).
  def candidate_decl_info(node, annotator)
    return nil unless node.is_a?(AST::VarDecl) || node.is_a?(AST::BindExpr)
    return nil unless node.name.is_a?(String)
    val = node.value
    # The parser wraps `Counter{...} @shared:locked` as a CapabilityWrap
    # around the StructLit; the StructLit lives on `.value`. Bare
    # `Counter{...}` (no sigil) wouldn't match the locked-sync check
    # below anyway, so the fallthrough is silent.
    val = val.value if val.is_a?(AST::CapabilityWrap)
    return nil unless val.is_a?(AST::StructLit)

    ti = node.full_type
    ti = Type.new(ti) unless ti.is_a?(Type)
    return nil unless ti.locked?

    schema = annotator.respond_to?(:lookup_type_schema) ?
             annotator.lookup_type_schema(ti.resolved) : nil
    return nil unless Schemas.field_bearing?(schema) && schema.methods.empty?
    fields = schema.fields
    return nil unless fields.size == 1

    field_name, field_def = fields.first
    field_type = field_def.is_a?(AST::StructField) ? field_def.type : field_def
    field_resolved = field_type.is_a?(Type) ? field_type.resolved : field_type
    return nil unless ATOMIC_ELIGIBLE_FIELD_TYPES.include?(field_resolved)

    line = node.token&.line
    {
      name: node.name.to_s,
      decl_node: node,
      line: line,
      struct_name: ti.resolved,
      field_name: field_name.to_s,
      field_type: field_resolved,
      shared: ti.respond_to?(:shared?) ? ti.shared? : false,
      n_uses: 0,
      disqualified: false,
    }
  end

  # WITH-block dispatch: only WITH EXCLUSIVE captures are valid for
  # the atomic-primitive migration; other capabilities (RESTRICT,
  # SNAPSHOT, etc.) DISQUALIFY.
  def classify_with_block!(with_node, candidates)
    (with_node.capabilities || []).each do |cap|
      vn = cap[:var_node]
      next unless vn.is_a?(AST::Identifier)
      info = candidates[vn.name]
      next unless info
      unless cap[:capability] == :EXCLUSIVE
        info[:disqualified] = true
        next
      end
      alias_name = (cap[:alias] || vn.name).to_s
      if with_body_eligible?(with_node, alias_name, info[:field_name])
        info[:n_uses] += 1
      else
        info[:disqualified] = true
      end
    end
  end

  def with_body_eligible?(with_node, alias_name, field_name)
    body = with_node.body
    return false unless body.is_a?(Array) && !body.empty?
    body.all? { |stmt| stmt_eligible?(stmt, alias_name, field_name) }
  end

  def stmt_eligible?(stmt, alias_name, field_name)
    case stmt
    when AST::Assignment, AST::BindExpr
      # `alias.field = expr` — Assignment's target / BindExpr's name
      # is the GetField path; the RHS lives on `.value`.
      target = stmt.name
      return false unless target.is_a?(AST::GetField)
      return false unless target.target.is_a?(AST::Identifier) && target.target.name == alias_name
      return false unless target.field.to_s == field_name
      rhs = stmt.value
      if references_alias?(rhs, alias_name)
        # RHS reads the alias somewhere — only the `+= N` / `-= N`
        # desugar shape is atomic-rewriteable. `*=` / arbitrary
        # expressions referencing `alias.field` aren't.
        eligible_compound_rhs?(rhs, alias_name, field_name)
      else
        # Plain store of an expression that doesn't read the binding
        # itself — atomic.store is fine.
        true
      end
    else
      # Read-only statements (e.g., `print(inner.value);`) are eligible
      # iff every alias reference is the field read; atomic.load covers
      # the read. Bare control-flow statements (IF / WHILE / FOR / WITH
      # nested) reach here too — they're disqualified because the body
      # has shape we can't 1:1 rewrite into atomic ops.
      return false if control_flow_stmt?(stmt)
      rhs_uses_alias_only_for_field_get?(stmt, alias_name, field_name)
    end
  end

  # `+= N` / `-= N` desugars to `alias.field = alias.field + N`. To
  # be atomic-rewriteable as fetchAdd/fetchSub: exactly one side is
  # the field read, the other side doesn't reference the alias.
  def eligible_compound_rhs?(expr, alias_name, field_name)
    return false unless expr.is_a?(AST::BinaryOp)
    op = expr.respond_to?(:op) ? expr.op : nil
    return false unless op == :ADD || op == :SUB
    sides = [expr.respond_to?(:left) ? expr.left : nil,
             expr.respond_to?(:right) ? expr.right : nil].compact
    return false unless sides.size == 2
    return false unless sides.count { |s| field_get_of?(s, alias_name, field_name) } == 1
    other = sides.find { |s| !field_get_of?(s, alias_name, field_name) }
    !references_alias?(other, alias_name)
  end

  sig { params(node: T.any(AST::GetField, AST::Literal), alias_name: String, field_name: String).returns(T::Boolean) }
  def field_get_of?(node, alias_name, field_name)
    node.is_a?(AST::GetField) &&
      node.target.is_a?(AST::Identifier) &&
      node.target.name == alias_name &&
      node.field.to_s == field_name
  end
end
