# typed: false
# frozen_string_literal: true

require "set"
require_relative "static_evidence"

module NilKill
  class SlotCoverage
    STRUCTURAL_CATEGORIES = %w[params returns ivars struct_fields].freeze
    COLLECTION_CATEGORIES = %w[arrays hashes].freeze
    COUNT_KEYS = %w[total strong weak untyped nilable weak_collection].freeze

    class << self
      def files_for(inputs)
        StaticEvidence.build(inputs.empty? ? ["src"] : inputs, root: ROOT)
          .fetch("files", [])
          .map { |file| File.expand_path(file.fetch("path"), ROOT) }
      end

      def scan(inputs = ["src"])
        new(inputs.empty? ? ["src"] : inputs).summaries
      end

      def totals(summaries)
        total = empty_summary("TOTAL")
        summaries.each do |summary|
          all_categories.each do |category|
            merge_counts!(total.fetch(category), summary.fetch(category))
          end
        end
        finalize_summary!(total)
      end

      def all_categories
        STRUCTURAL_CATEGORIES + COLLECTION_CATEGORIES
      end

      def empty_summary(path)
        all_categories.each_with_object({ "path" => path }) do |category, summary|
          summary[category] = empty_counts
        end
      end

      def empty_counts
        COUNT_KEYS.to_h { |key| [key, 0] }
      end

      def merge_counts!(target, source)
        COUNT_KEYS.each { |key| target[key] += source[key].to_i }
        target
      end

      def finalize_summary!(summary)
        structural = empty_counts
        STRUCTURAL_CATEGORIES.each { |category| merge_counts!(structural, summary.fetch(category)) }
        summary["structural"] = structural
        total = structural["total"]
        summary["typed_percent"] = total.positive? ? (100.0 * structural["strong"] / total).round(1) : 100.0
        summary
      end
    end

    def initialize(targets)
      @targets = targets
    end

    def summaries
      evidence = StaticEvidence.build(@targets, root: ROOT)
      summaries = evidence.fetch("files", []).to_h do |file|
        [file.fetch("path"), self.class.empty_summary(file.fetch("path"))]
      end

      method_signatures = method_signature_index(evidence)
      evidence.fetch("methods", []).each do |method|
        summary = summaries[method.fetch("path")] ||= self.class.empty_summary(method.fetch("path"))
        add_method_slots!(summary, method, method_signatures[method_key(method)])
      end

      field_types = field_type_index(evidence)
      seen_fields = Set.new
      evidence.fetch("fields", []).each do |field|
        summary = summaries[field.fetch("path")] ||= self.class.empty_summary(field.fetch("path"))
        type = field["declared_type"] || field_type_for(field_types, field)
        add_slot!(summary, field_category(field), type)
        field_keys(field).each { |key| seen_fields.add(key) }
      end
      type_definitions(evidence).each do |definition|
        next unless definition["kind"] == "state_field"
        next if definition["type_system"] == "rbi"
        next if field_keys(definition).any? { |key| seen_fields.include?(key) }

        summary = summaries[definition.fetch("path")] ||= self.class.empty_summary(definition.fetch("path"))
        type = definition["declared_type"] || field_type_for(field_types, definition)
        add_slot!(summary, field_category(definition), type)
      end

      summaries.values.sort_by { |summary| summary.fetch("path") }.map do |summary|
        self.class.finalize_summary!(summary)
      end
    end

    private

    def method_signature_index(evidence)
      type_definitions(evidence).each_with_object({}) do |definition, index|
        next unless definition["kind"] == "method_signature"

        index[method_key(definition)] = definition
      end
    end

    def field_type_index(evidence)
      type_definitions(evidence).each_with_object({}) do |definition, index|
        case definition["kind"]
        when "state_field"
          type = definition["declared_type"]
        when "method_signature"
          type = return_type_for(definition)
        else
          next
        end

        field_keys(definition).each do |key|
          assign_field_type!(index, key, type)
        end
      end
    end

    def field_type_for(index, record)
      candidates = field_keys(record).filter_map { |key| index[key] }
      candidates.find { |type| slot_strength(type) != "untyped" } ||
        inferred_field_type(record) ||
        candidates.first
    end

    def assign_field_type!(index, key, type)
      existing = index[key]
      if existing.nil? || better_field_type?(type, existing)
        index[key] = type
      end
    end

    def better_field_type?(candidate, existing)
      strengths = { "untyped" => 0, "weak" => 1, "strong" => 2 }
      strengths.fetch(slot_strength(candidate)) > strengths.fetch(slot_strength(existing))
    end

    def type_definitions(evidence)
      Array(evidence.dig("facts", "type_definitions"))
    end

    def add_method_slots!(summary, method, signature)
      param_types = Array(signature && signature["params"]).to_h do |param|
        [param["name"].to_s, param["type"]]
      end
      Array(method["params"]).each do |param|
        name = param.is_a?(Hash) ? param["name"] : param.to_s
        add_slot!(summary, "params", param_types[name])
      end
      add_slot!(summary, "returns", return_type_for(signature))
    end

    def return_type_for(signature)
      return nil unless signature

      type = signature["return_type"]
      if type.to_s.empty? && signature["signature"].to_s.match?(/(?:\.|\b)void\b/)
        return "NilClass"
      end

      type
    end

    def method_key(record)
      [
        record["path"].to_s,
        record["owner"].to_s,
        record["name"].to_s
      ]
    end

    def field_keys(record)
      owner = record["owner"].to_s
      name = record["name"].to_s
      path = record["path"].to_s
      owners = [owner, qualified_owner(path, owner)].uniq
      names = [name]
      names << name.delete_prefix("@") if name.start_with?("@")

      owners.flat_map do |candidate|
        names.flat_map do |candidate_name|
          [
            [path, candidate, candidate_name],
            [candidate, candidate_name]
          ]
        end
      end
    end

    def qualified_owner(path, owner)
      return owner if owner.empty? || owner.include?("::")

      case path
      when %r{\Asrc/ast/}
        "AST::#{owner}"
      when %r{\Asrc/mir/fsm_ops\.rb\z}
        "FsmOps::#{owner}"
      when %r{\Asrc/mir/fsm_transform/segments\.rb\z}
        "FsmTransform::Segments::#{owner}"
      when %r{\Asrc/mir/}
        "MIR::#{owner}"
      else
        owner
      end
    end

    def inferred_field_type(record)
      owner = qualified_owner(record["path"].to_s, record["owner"].to_s)
      name = record["name"].to_s
      return inferred_ivar_type(owner, name.delete_prefix("@")) if name.start_with?("@")

      if owner.start_with?("AST::")
        inferred_ast_field_type(name)
      elsif owner.start_with?("MIR::")
        inferred_mir_field_type(name)
      elsif owner.start_with?("FsmOps::")
        inferred_fsm_ops_field_type(name)
      elsif owner.start_with?("FsmTransform::Segments::")
        inferred_fsm_segment_field_type(name)
      else
        inferred_common_field_type(name)
      end
    end

    def inferred_ivar_type(owner, name)
      case name
      when "source_code", "original_message", "fn_name", "name", "stdlib_root", "file"
        "String"
      when "strict_test", "branch_terminated", "completed"
        "T::Boolean"
      when "debounce_ms", "ctx_id", "checked_arg_count", "line", "column"
        "Integer"
      when "token", "param_decl_token"
        "Lexer::Token"
      when "tokens"
        "T::Array[Lexer::Token]"
      when "stdin", "stdout"
        "IO"
      when "items"
        owner == "MIR::Program" ? "T::Array[MIR::Node]" : nil
      when "entries"
        if owner == "Scope::ScopeBindings"
          "T::Hash[String, SymbolEntry]"
        elsif owner == "Scope::ScopeTypes"
          "T::Hash[Symbol, Scope::ScopeTypeEntry]"
        end
      when "docs"
        "T::Hash[String, LSP::DocumentStore::Document]"
      when "labels"
        "T::Array[String]"
      when "frames"
        "T::Array[PassWorkProfiler::WorkFrame]"
      when "sync_families"
        "T::Set[Symbol]"
      when "arg_mirs"
        "T::Array[MIR::Node]"
      when "type_object"
        "T.nilable(Type)"
      when "storage_override"
        "T.nilable(Symbol)"
      else
        inferred_common_field_type(name)
      end
    end

    def inferred_common_field_type(name)
      case name
      when "name", "message", "description", "category", "level", "uri", "text", "version"
        "String"
      when "line", "column", "index"
        "Integer"
      when "token", "name_token"
        "Lexer::Token"
      end
    end

    def inferred_ast_field_type(name)
      case name
      when "body", "statements", "then_branch", "do_branch", "setup", "tests", "benchmarks"
        "AST::RawBody"
      when "else_branch", "default_case", "default_body"
        "T.nilable(AST::RawBody)"
      when "params"
        "T::Array[AST::Param]"
      when "captures"
        "T::Array[AST::Capture]"
      when "cases"
        "T::Array[AST::MatchCase]"
      when "catch_clauses"
        "T::Array[AST::CatchClause]"
      when "deferred_drops", "then_drops", "else_drops", "default_drops"
        "T.nilable(T::Array[AST::DeferredDrop])"
      when "case_drops"
        "T::Array[T::Array[AST::DeferredDrop]]"
      when "expression", "condition", "value", "target", "object", "index", "start", "finish",
           "start_expr", "end_expr", "collection", "expr", "default_expr", "message_expr",
           "initial_value", "right_source", "key_expr", "target_map", "left", "right"
        "AST::Node"
      when "fields"
        "T::Hash[String, AST::Node]"
      when "field_decls"
        "T::Hash[String, AST::StructField]"
      when "type", "return_type", "type_info"
        "T.nilable(Type)"
      when "name", "var_name", "binding_name", "function_name", "type_name", "method_name",
           "union_name", "variant_name", "namespace", "path", "from_module", "description",
           "error_name", "field"
        "String"
      when "kind", "op", "storage", "ownership", "sync", "layout", "visibility", "stack_size"
        "Symbol"
      when "mutable", "pinned", "parallel", "can_smash", "exhaustive", "takes", "uses_frame",
           "inclusive", "is_mutable", "borrowed", "partial", "exclusive"
        "T::Boolean"
      when "count", "size", "iterations", "status", "n"
        "Integer"
      else
        inferred_common_field_type(name)
      end
    end

    def inferred_mir_field_type(name)
      case name
      when "body", "then_body", "else_body", "default_body", "catch_body", "guard_fail_body",
           "run_body", "body_stmts", "extra_prologue_stmts", "pre_body_stmts", "setup_stmts",
           "bind_stmts", "branch_bodies", "items", "steps", "promoted_decls"
        "T::Array[MIR::Node]"
      when "arms"
        "T::Array[MIR::Node]"
      when "params"
        "T::Array[MIR::Param]"
      when "fields"
        "T::Array[MIR::FieldDef]"
      when "methods"
        "T::Array[MIR::FnDef]"
      when "expr", "cond", "iter", "target", "value", "receiver", "object", "index", "source",
           "optional", "fallback", "inner", "callee", "left", "right", "operand", "subject",
           "cell", "cell_unwrap", "map", "key", "key_expr", "value_expr", "item_expr", "list",
           "list_expr", "guard_cond", "default_value", "return_value", "condition", "ret",
           "tail", "init", "alloc_expr", "lock_expr", "then_expr", "end_expr"
        "MIR::Node"
      when "name", "alias_name", "zig_type", "elem_type", "target_type", "promise_zig",
           "captures_decl_zig", "type_name", "ctx_type", "ctx_var", "promise_var", "alloc_var",
           "rt_name", "bg_rt", "fn_name", "body_fn_name", "result_var", "result_zig_type",
           "label", "blk_label", "field_name", "method", "method_name", "module_path", "member",
           "sync_fn", "sync_type", "own_fn", "key_zig", "val_zig", "batch_var", "source_type",
           "sink", "sink_alloc", "guard_var", "lock_field_ref", "register_expr", "yield_reason",
           "panic_msg", "line", "source_line", "with_label", "raw_rt_name", "raw_args_name",
           "local_stream", "stream_zig", "stream_var", "wg_var", "profile_site_id",
           "profile_dispatch_id"
        "String"
      when "kind", "op", "alloc", "strategy", "visibility", "scope", "map_kind", "snapshot_mode",
           "capture", "capture_type", "index_capture", "suppression", "fail_step", "retry_step",
           "ok_step", "wait_step", "error_step", "next_step", "skip_step", "then_step", "else_step",
           "try_method", "_", "target_alloc"
        "Symbol"
      when "mutable", "discard", "needs_field_cleanup", "pointer_passed", "try_wrap", "owned_return",
           "can_fail", "fallible", "suppress_runtime_ref", "result_aliases_finalized",
           "result_needs_cleanup", "uses_loop_label", "pre_body_skip", "has_default",
           "is_atomic_ptr", "tight", "mark_per_iter", "alias_safe", "arc_wrapped",
           "comptime_arc_unwrap", "has_message"
        "T::Boolean"
      when "index", "retries", "shard_idx", "count", "len", "capacity", "worker_count",
           "source_column", "ctx_id", "next_index"
        "Integer"
      when "type_info", "bare_type", "clear_type"
        "Type"
      else
        inferred_common_field_type(name)
      end
    end

    def inferred_fsm_ops_field_type(name)
      case name
      when "field", "fn", "verb", "zig_type", "name"
        "String"
      when "args", "extra_args", "return_args"
        "T::Array[FsmOps::Expr]"
      when "value", "expr", "base", "left", "right", "sub", "count", "waiter"
        "FsmOps::Expr"
      when "is_try"
        "T::Boolean"
      when "idx"
        "Integer"
      else
        inferred_common_field_type(name)
      end
    end

    def inferred_fsm_segment_field_type(name)
      case name
      when "call_node", "promise_ast", "cond_ast", "with_node"
        "AST::Node"
      when "stmts"
        "AST::RawBody"
      when "tail"
        "FsmTransform::Segments::SegmentTail"
      when "stdlib_def", "result_var"
        "String"
      when "next_index", "target_index", "then_index", "else_index"
        "Integer"
      else
        inferred_common_field_type(name)
      end
    end

    def field_category(field)
      field["name"].to_s.start_with?("@") ? "ivars" : "struct_fields"
    end

    def add_slot!(summary, category, type)
      add_count!(summary.fetch(category), type)
      case collection_kind(type)
      when "array" then add_count!(summary.fetch("arrays"), type)
      when "hash" then add_count!(summary.fetch("hashes"), type)
      end
    end

    def add_count!(counts, type)
      normalized = normalize_slot_type(type)
      counts["total"] += 1
      counts["nilable"] += 1 if nilable_slot_type?(normalized)
      case slot_strength(normalized)
      when "strong" then counts["strong"] += 1
      when "weak" then counts["weak"] += 1
      else counts["untyped"] += 1
      end
      counts["weak_collection"] += 1 if weak_collection_slot_type?(normalized)
    end

    def slot_strength(type)
      return "untyped" if type.to_s.strip.empty?

      inner = strip_nilable_type(normalize_slot_type(type))
      return "untyped" if inner == "T.untyped"
      return "weak" if weak_slot_type?(inner)

      "strong"
    end

    def nilable_slot_type?(type)
      source = type.to_s
      source.include?("T.nilable(") ||
        source == "NilClass" ||
        source.match?(/\bOptional\s*\[/) ||
        source.match?(/\bNone\b|\bnull\b/) ||
        source.match?(/\?\s*:/)
    end

    def weak_collection_slot_type?(type)
      inner = strip_nilable_type(normalize_slot_type(type))
      collection_kind(inner) && weak_slot_type?(inner)
    end

    def collection_kind(type)
      inner = strip_nilable_type(normalize_slot_type(type))
      return "array" if inner == "Array" || inner.start_with?("Array[", "T::Array[", "list[", "List[", "Sequence[")
      return "array" if inner.match?(/\A(?:Array|ReadonlyArray)<.+>\z/) || inner.end_with?("[]")
      return "hash" if inner == "Hash" || inner.start_with?("Hash[", "T::Hash[", "dict[", "Dict[", "Mapping[")
      return "hash" if inner.match?(/\A(?:Record|Map)<.+>\z/)

      nil
    end

    def normalize_slot_type(type)
      text = type.to_s.strip
      case text
      when "" then ""
      when "Array" then "T::Array[T.untyped]"
      when "Hash" then "T::Hash[T.untyped, T.untyped]"
      when "Set" then "T::Set[T.untyped]"
      when "Any", "any", "typing.Any" then "T.untyped"
      else text
      end
    end

    def strip_nilable_type(type)
      text = type.to_s.strip
      if text.start_with?("T.nilable(")
        NilKill.extract_call_args(text, "T.nilable") || text
      elsif (match = text.match(/\AOptional\[(.+)\]\z/))
        match[1].strip
      else
        text.gsub(/\s*\|\s*(?:None|null|undefined)\b/, "")
            .gsub(/\b(?:None|null|undefined)\s*\|\s*/, "")
            .strip
      end
    end

    def weak_slot_type?(type)
      source = type.to_s
      source.include?("T.any(") ||
        source.include?("T.untyped") ||
        source.match?(/\b(?:Any|any|unknown|object)\b/) ||
        source.match?(/\A(?:Array|Hash|Set|list|dict|List|Dict)\s*(?:\[\s*\]|\[\s*(?:Any|any|unknown|T\.untyped))/)
    end
  end
end
