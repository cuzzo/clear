# typed: strict
require "sorbet-runtime"

require_relative "semantic_ids"
require_relative "../annotator/phases/body_analysis"

# Keep-analysis (retained identity v4, docs/agents/retained-identity-design.md).
#
# Direct keeps are stamped during the typed body walk: a plain param stored
# into an @multiowned identity field sets SymbolEntry#kept_identity (see
# Lifetimes#keep_param_identity!). This pass adds the transitive closure:
# a param passed in a kept position of a callee is itself kept. Runs to
# fixed point over annotated call-site facts, the same shape as
# EscapeAnalysis.propagate_caller_sync!. Downstream consumers (signature
# ABI, edge derivation, born-as-Rc promotion) READ the stamp; they never
# re-derive keep-ness.
module KeepAnalysis
  extend T::Sig

  FnNodes = T.type_alias { T::Hash[String, AST::FunctionDef] }
  BodySummaries = T.type_alias { T::Hash[String, Annotator::Phases::FunctionBodySummary] }

  sig { params(fn_nodes: FnNodes, body_summaries: BodySummaries).void }
  def self.propagate_kept_identity!(fn_nodes, body_summaries)
    caller_params = T.let({}, T::Hash[String, T::Hash[String, SymbolEntry]])
    fn_nodes.each do |name, fn|
      params = T.let({}, T::Hash[String, SymbolEntry])
      fn.params.each do |param|
        entry = param.symbol
        params[param.name.to_s] = entry if entry
      end
      caller_params[name] = params
    end

    kept_param_indexes = T.let({}, T::Hash[String, T::Array[Integer]])
    refresh_kept = T.let(lambda do
      kept_param_indexes.clear
      fn_nodes.each do |name, fn|
        indexes = T.let([], T::Array[Integer])
        fn.params.each_with_index do |param, idx|
          entry = param.symbol
          indexes << idx if entry&.kept_identity
        end
        kept_param_indexes[name] = indexes unless indexes.empty?
      end
    end, T.proc.void)
    refresh_kept.call

    fn_nodes.length.times do
      changed = T.let(false, T::Boolean)
      body_summaries.each do |caller_name, summary|
        params = caller_params[caller_name]
        next if params.nil? || params.empty?

        summary.call_site_facts.each do |site|
          next if site.fn_var_call
          kept = kept_param_indexes[site.callee_name]
          next unless kept

          kept.each do |idx|
            arg = site.args[idx]
            next unless arg.is_a?(AST::Identifier)
            entry = params[arg.name]
            next if entry.nil? || entry.kept_identity
            callee_param = fn_nodes[site.callee_name]&.params&.fetch(idx, nil)
            inherited = callee_param&.symbol&.kept_identity
            entry.kept_identity = inherited ||
              KeptIdentityContract.new(family: :multiowned, sink: "#{site.callee_name} kept position #{idx}")
            changed = true
          end
        end
      end
      break unless changed
      refresh_kept.call
    end
  end
end
