# frozen_string_literal: true

module FactMine
  module Syntax
    # Extracts detector source facts from the shared normalized AST vocabulary
    # (DEFN/DEFS/FCALL/VCALL/etc.). Language-specific code should normalize
    # concrete syntax into this tree; fact extraction should stay here.
    class NormalizedExtractor
      def self.fact_document(file, language:, include_normalized_root: true)
        new(file, language: language, include_normalized_root: include_normalized_root).fact_document
      end

      def initialize(file, language:, include_normalized_root: true)
        @file = file.to_s
        @language = language.to_sym
        @extraction_behavior = Syntax::NormalizedExtractionBehavior.for(@language)
        @include_normalized_root = include_normalized_root
        @root, @lines = Ast.parse(file, language: @language)
        @source = File.read(file)
        @file_owner = File.basename(@file, File.extname(@file))
        @owners = []
        @functions = []
        @controls = []
        @decision_spans = []
        @receiver_aliases = []
        @owner_fields = Hash.new { |hash, key| hash[key] = [] }
        @seen_calls = {}
        @seen_reads = {}
        @seen_writes = {}
        @seen_effects = {}
        @facts = {
          function_defs: [],
          owner_defs: [],
          call_sites: [],
          state_declarations: [],
          state_reads: [],
          state_writes: [],
          decision_sites: [],
          branch_decisions: [],
          branch_arms: [],
          dispatch_sites: [],
          semantic_effect_sites: [],
          predicate_aliases: [],
          comparison_sites: [],
          path_condition_sites: []
        }
      end

      def fact_document
        scan(@root)
        apply_visibility!
        append_effects_from_calls!
        dedupe_semantic_effects!

        FactDocument.new(row, file: @file, language: @language, source: @source, lines: @lines)
      end

      private

      def row
        profile = Syntax.language_profile(@language)
        doc = OpenStruct.new(file: @file, language: @language, source: @source, lines: @lines)

        {
          "file" => @file,
          "language" => @language.to_s,
          "source" => "",
          "lines" => @lines,
          "root" => raw_from_normalized(@root),
          "normalized_root" => @include_normalized_root ? normalized_row(@root) : empty_normalized_root,
          "functions" => @facts.fetch(:function_defs),
          "owners" => @facts.fetch(:owner_defs),
          "calls" => @facts.fetch(:call_sites),
          "state_declarations" => @facts.fetch(:state_declarations),
          "state_reads" => @facts.fetch(:state_reads),
          "state_writes" => @facts.fetch(:state_writes),
          "decisions" => dedupe_decision_sites(@facts.fetch(:decision_sites)),
          "branch_decisions" => @facts.fetch(:branch_decisions),
          "branch_arms" => @facts.fetch(:branch_arms),
          "dispatch_sites" => @facts.fetch(:dispatch_sites),
          "semantic_effects" => @facts.fetch(:semantic_effect_sites),
          "predicate_aliases" => @facts.fetch(:predicate_aliases),
          "predicate_bodies" => @facts.fetch(:predicate_aliases),
          "comparisons" => [],
          "path_conditions" => @facts.fetch(:path_condition_sites),
          "protocol_method_effects" => [],
          "protocol_call_paths" => [],
          "clone_candidates" => [],
          "redundant_nil_guards" => [],
          "local_methods" => [],
          "local_complexity_scores" => {},
          "immutable_struct_readers" => profile.immutable_struct_readers(doc),
          "immutable_struct_reader_types" => profile.immutable_struct_reader_types(doc),
          "type_aliases" => profile.type_aliases(doc),
          "method_param_types" => profile.__send__(:method_param_types, doc)
        }
      end

      def scan(node)
        return unless ast_node?(node)

        case node.type.to_s
        when "CLASS", "MODULE" then scan_owner(node)
        when "STRUCT_ITEM", "TYPE_DECLARATION", "TYPE_DEFINITION", "VARIABLE_DECLARATION" then scan_declarative_owner(node)
        when "DEFN", "DEFS" then scan_function(node)
        when "HASH" then scan_children(node)
        when "IF", "UNLESS" then scan_if(node)
        when "CASE", "CASE2" then scan_case(node)
        when "AND", "OR" then scan_boolean(node)
        when "CALL", "QCALL", "FCALL", "VCALL" then record_call_node(node, block: false)
        when "ITER" then scan_iter(node)
        when "FOR", "WHILE", "UNTIL" then scan_loop(node)
        when "YIELD" then scan_yield(node)
        when "XSTR" then scan_command_string(node)
        when "SCLASS" then scan_singleton_class(node)
        when "LASGN" then scan_local_assignment(node)
        when "FIELD_EXPRESSION", "RAW_ARGUMENT" then scan_literal_expression(node)
        when "IASGN", "GASGN" then record_state_write(node)
        when "IVAR", "GVAR" then record_state_read_node(node)
        when "LVAR" then record_bare_state_read_node(node)
        when "ATTRASGN" then scan_attr_assignment(node)
        when "OPCALL" then scan_operator_call(node)
        when "OP_ASGN1", "OP_ASGN2" then scan_operator_assignment(node)
        else scan_children(node)
        end
      end

      def scan_children(node)
        child_nodes(node).each { |child| scan(child) }
      end

      def scan_owner(node)
        name = owner_name(node) || owner_name_from_text(node) || "(anonymous)"
        qualified = @owners.empty? ? name : "#{current_owner}::#{name}"
        @facts.fetch(:owner_defs) << {
          "file" => @file,
          "name" => qualified,
          "kind" => owner_kind(node),
          "line" => node.first_lineno,
          "span" => span(node)
        }

        @owners << qualified
        collect_owner_fields(qualified, node)
        scan(scope_child(node)) if scope_child(node)
        @owners.pop
      end

      def scan_declarative_owner(node)
        owner = declarative_owner(node)
        @facts.fetch(:owner_defs) << owner if owner
        if owner
          @owners << owner.fetch("name")
          scan_children(node)
          @owners.pop
        else
          scan_children(node)
        end
      end

      def scan_function(node)
        name = function_name(node) || "(anonymous)"
        owner = owner_for_function(name, node)
        record_semantic_effect(node, "metaprogramming", "def #{name}") if %w[method_missing respond_to_missing?].include?(name)

        @facts.fetch(:function_defs) << {
          "file" => @file,
          "name" => name,
          "owner" => owner,
          "line" => node.first_lineno,
          "span" => span(node),
          "body" => raw_from_normalized(node),
          "visibility" => function_visibility(name, node),
          "params" => function_params(node)
        }

        if (predicate = predicate_alias(node, owner))
          @facts.fetch(:predicate_aliases) << predicate
        end
        record_initializer_field_reads(node, owner)

        owner_pushed = owner && owner != current_owner
        @owners << owner if owner_pushed
        @functions << name
        @receiver_aliases << receiver_aliases_for_function(node)
        scope = function_scope(node)
        body = scope && scope_body(scope)
        scan(body) if body
        @receiver_aliases.pop
        @functions.pop
        @owners.pop if owner_pushed
      end

      def scan_iter(node)
        record_call_node(child_node(node, 0), block: true) if child_node(node, 0)
        scope = child_node(node, 1)
        body = scope && scope_body(scope)
        with_control("iterates") { scan(body) } if body
      end

      def scan_loop(node)
        child_nodes(node).each do |child|
          with_control("iterates") { scan(child) }
        end
      end

      def scan_yield(node)
        return scan_children(node) unless @extraction_behavior.yield_semantic_effect?(node)

        record_semantic_effect(node, "dynamic_dispatch", "yield")
        scan_children(node)
      end

      def scan_command_string(node)
        record_semantic_effect(node, "hidden_io", "backtick")
        scan_children(node)
      end

      def scan_singleton_class(node)
        receiver = child_node(node, 0)&.then { |child| normalized_text(child) }
        record_semantic_effect(node, "metaprogramming", "class << #{receiver}") if receiver && receiver != "self"
        scan_children(node)
      end

      def scan_if(node)
        condition = child_node(node, 0)
        return scan_children(node) unless condition
        return scan_children(node) if normalized_ternary_if?(node)

        @decision_spans << span(node)
        with_control("conditional") { scan(condition) }
        @decision_spans.pop
        record_branch_decision(node, condition)
        record_if_arms(node, condition)

        [child_node(node, 1), child_node(node, 2)].compact.each do |child|
          with_control("conditional") { scan(child) }
        end
      end

      def scan_case(node)
        value_index = node.type.to_s == "CASE" ? 0 : nil
        chain_index = node.type.to_s == "CASE" ? 1 : 0
        value = value_index && child_node(node, value_index)
        if value
          with_control("conditional") { scan(value) }
          record_branch_decision(node, value)
        end

        whens = when_chain(child_node(node, chain_index))
        patterns = whens.flat_map { |when_node| when_patterns(when_node) }.sort
        if value && patterns.length >= 2
          @facts.fetch(:decision_sites) << {
            "kind" => "case_dispatch",
            "members" => patterns,
            "file" => @file,
            "function" => current_function,
            "line" => node.first_lineno,
            "span" => span(node),
            "predicate" => case_predicate_text(value),
            "enclosing_span" => span(node)
          }
        end

        whens.each do |when_node|
          record_case_arm(node, when_node, value)
          body = child_node(when_node, 1)
          with_control("conditional") { scan(body) } if body
        end
        fallback = case_fallback(node)
        with_control("conditional") { scan(fallback) } if fallback
        record_dispatch_site(node, value, whens) if value
      end

      def scan_boolean(node)
        if node.type.to_s == "AND"
          members = flatten_and(node).map { |child| normalized_text(child) }
          members = @extraction_behavior.boolean_decision_members(members, node)
          if members.length >= 2
            @facts.fetch(:decision_sites) << {
              "kind" => "conjunction",
              "members" => members,
              "file" => @file,
              "function" => current_function,
              "line" => node.first_lineno,
              "span" => span(node),
              "predicate" => normalized_text(node),
              "enclosing_span" => boolean_enclosing_span(node)
            }
          end
        end
        scan_children(node)
      end

      def scan_attr_assignment(node)
        effect_detail = "[]="
        receiver = child_node(node, 0)
        field = child_symbol(node, 1)
        if receiver && field
          field = field.delete_suffix("=")
          if field != "[]"
            effect_detail = "#{field}="
            receiver_name = receiver_text(receiver)
            indexed_field = node.text.to_s.include?("[") && state_receiver_field(receiver_name)
            if indexed_field
              record_state_write_target("self", indexed_field, node)
            else
              write_span = @extraction_behavior.state_write_span(
                receiver_name,
                field,
                node,
                default_span: span(node)
              )
              record_state_write_target(receiver_name, field, node, write_span)
              record_index_assignment_read(receiver, field, node)
            end
          end
        elsif receiver
          field = state_receiver_field(receiver_text(receiver))
          record_state_write_target("self", field, node) if field
        end
        scan(receiver) if receiver
        scan(child_node(node, 2)) if child_node(node, 2)
      end

      def scan_operator_call(node)
        operator = child_symbol(node, 1)
        if %w[== != === !== < <= > >=].include?(operator)
          raw = normalized_text(node)
          @facts.fetch(:comparison_sites) << {
            "canon_source" => normalize_comparison_source(raw),
            "raw" => raw,
            "source" => raw,
            "operator" => operator,
            "file" => @file,
            "function" => current_function,
            "line" => node.first_lineno,
            "span" => span(node),
            "enclosing_span" => span(node)
          }
        end
        record_semantic_effect(node, "hidden_mutation", "<<") if operator == "<<" && !stream_insertion_operator?(node)
        scan_children(node)
      end

      def scan_operator_assignment(node)
        scan_children(node)
      end

      def record_call_node(node, block:)
        parts = call_parts(node)
        return scan_children(node) unless parts

        scan(parts[:receiver_node]) if parts[:receiver_node]
        scan(parts[:args_node]) if parts[:args_node]
        record_embedded_member_reads(node)

        call = call_hash(node, parts, block)
        call = @extraction_behavior.project_call(node, call)
        return if call.fetch("message") == "[]"

        if property_read_call?(node, parts)
          record_state_read_for_call(call)
          return
        end
        return if suppress_call_site?(node, call)

        key = call.values_at("receiver", "message", "function", "line", "span")
        return if @seen_calls[key]

        @seen_calls[key] = true
        record_state_read_for_call(call)
        record_state_write_for_mutating_call(call)
        if call["receiver"] == "self" && node.text.to_s.include?(".(")
          record_semantic_effect(node, "dynamic_dispatch", "#{call.fetch("message")}.call")
        end
        @facts.fetch(:call_sites) << call
      end

      def call_hash(node, parts, block)
        {
          "receiver" => @extraction_behavior.call_receiver(parts),
          "message" => parts.fetch(:message),
          "file" => @file,
          "function" => current_function,
          "owner" => current_owner,
          "line" => node.first_lineno,
          "span" => call_site_span(node),
          "access_span" => call_access_span(node),
          "conditional" => conditional_context?,
          "arguments" => parts.fetch(:arguments),
          "control" => current_control,
          "safe_navigation" => node.type.to_s == "QCALL",
          "block" => block
        }
      end

      def call_access_span(node)
        text = node.text.to_s
        open_index = text.rindex("(")
        computed =
          if open_index && node.first_lineno == node.last_lineno
            if text.start_with?("(") && text.end_with?(")") && open_index.zero?
              [node.first_lineno, node.first_column + 1, node.first_lineno, node.last_column - 1]
            else
              [node.first_lineno, node.first_column, node.first_lineno, node.first_column + open_index]
            end
          end
        @extraction_behavior.call_access_span(node, computed_span: computed, full_span: span(node))
      end

      def call_site_span(node)
        @extraction_behavior.call_site_span(
          node,
          call_parts(node),
          full_span: span(node),
          access_span: call_access_span(node),
          current_function: current_function
        )
      end

      def suppress_call_site?(node, call)
        message = call.fetch("message").to_s
        receiver = call.fetch("receiver").to_s
        return true if receiver == "self" && message.match?(/\A[A-Z]/) && call.fetch("arguments").empty?
        return true if constant_receiver?(receiver) && call.fetch("arguments").empty? && !call.fetch("block")
        return true if @extraction_behavior.suppress_call_site?(node, call)

        false
      end

      def record_state_write(node)
        field = first_string_or_symbol(node) || normalized_text(node)
        record_semantic_effect(node, "context_dependency", field) if node.type.to_s == "GASGN"
        record_state_write_target("self", field, node)
        scan(child_node(node, 1)) if child_node(node, 1)
      end

      def scan_local_assignment(node)
        field = first_string_or_symbol(node)
        writes = @extraction_behavior.local_assignment_writes(field, node, default_span: span(node))
        unless writes.empty?
          writes.each { |write| record_state_write_target(write.fetch(:receiver), write.fetch(:field), node, write.fetch(:span)) }
          scan(child_node(node, 1)) if child_node(node, 1)
          return
        end

        if @extraction_behavior.implicit_owner_fields? && field && owner_field?(field) && current_function != "(top-level)"
          record_state_write_target("self", field, node, target_name_span(field, node))
        end
        scan(child_node(node, 1)) if child_node(node, 1)
      end

      def scan_literal_expression(node)
        record_literal_state_reads(node)
        scan_children(node)
      end

      def record_state_write_target(receiver, field, node, write_span = span(node))
        write = {
          "field" => field,
          "receiver" => receiver,
          "file" => @file,
          "function" => current_function,
          "line" => node.first_lineno,
          "span" => write_span,
          "owner" => current_owner
        }
        key = write.values_at("field", "receiver", "function", "owner", "line", "span")
        return if @seen_writes[key]

        @seen_writes[key] = true
        @facts.fetch(:state_writes) << write
      end

      def record_index_assignment_read(receiver, field, node)
        return unless node.text.to_s.include?("[")

        receiver_name = receiver_text(receiver)
        access_span = indexed_receiver_span(node)
        push_state_read(
          "field" => field,
          "receiver" => receiver_name,
          "file" => @file,
          "function" => current_function,
          "line" => node.first_lineno,
          "span" => access_span,
          "owner" => current_owner
        )
      end

      def indexed_receiver_span(node)
        index = node.text.to_s.index("[")
        return span(node) unless index && node.first_lineno == node.last_lineno

        [node.first_lineno, node.first_column, node.first_lineno, node.first_column + index]
      end

      def receiver_field_span(receiver, field, node)
        text = node.text.to_s
        target = [receiver, field].reject(&:empty?).join(".")
        index = text.index(target)
        return span(node) unless index && node.first_lineno == node.last_lineno

        [node.first_lineno, node.first_column + index, node.first_lineno, node.first_column + index + target.length]
      end

      def record_state_read_node(node)
        field = first_string_or_symbol(node) || normalized_text(node)
        record_semantic_effect(node, "context_dependency", field) if node.type.to_s == "GVAR"
        push_state_read(
          "field" => field,
          "receiver" => "self",
          "file" => @file,
          "function" => current_function,
          "line" => node.first_lineno,
          "span" => span(node),
          "owner" => current_owner
        )
      end

      def record_bare_state_read_node(node)
        field = first_string_or_symbol(node) || normalized_text(node)
        return unless implicit_owner_field_language?
        return unless owner_field?(field)
        return if current_function == "(top-level)"

        push_state_read(
          "field" => field,
          "receiver" => "self",
          "file" => @file,
          "function" => current_function,
          "line" => node.first_lineno,
          "span" => span(node),
          "owner" => current_owner
        )
      end

      def record_embedded_member_reads(node)
        @extraction_behavior.embedded_member_reads(node).each do |read|
          push_state_read(
            "field" => read.fetch(:field),
            "receiver" => read.fetch(:receiver),
            "file" => @file,
            "function" => current_function,
            "line" => read.fetch(:line, node.first_lineno),
            "span" => read.fetch(:span),
            "owner" => current_owner
          )
        end
      end

      def record_literal_state_reads(node)
        node_span = span(node)
        @extraction_behavior.literal_state_reads(
          node,
          normalized_text: normalized_text(node),
          span: node_span,
          source_text: span_source(node_span)
        ).each do |read|
          push_state_read(
            "field" => read.fetch(:field),
            "receiver" => read.fetch(:receiver),
            "file" => @file,
            "function" => current_function,
            "line" => read.fetch(:line, node.first_lineno),
            "span" => read.fetch(:span),
            "owner" => current_owner
          )
        end
      end

      def record_initializer_field_reads(node, owner)
        return unless owner

        @extraction_behavior.initializer_field_reads(
          node,
          owner: owner,
          owner_fields: @owner_fields[owner],
          function_name: function_name(node)
        ).each do |read|
          push_state_read(
            "field" => read.fetch(:field),
            "receiver" => read.fetch(:receiver),
            "file" => @file,
            "function" => read.fetch(:function),
            "line" => read.fetch(:line),
            "span" => read.fetch(:span),
            "owner" => owner
          )
        end
      end

      def record_state_read_for_call(call)
        receiver = call.fetch("receiver")
        message = call.fetch("message")
        return if @extraction_behavior.suppress_state_read_for_call?(call, span_source: span_source(call.fetch("span")))
        return if %w[callback print println puts].include?(message)
        return if @extraction_behavior.suppress_self_call_state_read?(call)
        return if receiver == "self" && message.match?(/\A[A-Z]/)
        return if receiver.empty? || constant_receiver?(receiver) ||
                  literal_receiver?(receiver) || receiver.start_with?("@", "$")
        return if message.match?(/\A\d+\z/)
        return if %w[== != === < <= > >= [] []= call].include?(message)

        span_key = @extraction_behavior.state_read_span_key(call)
        push_state_read(
          "field" => message,
          "receiver" => receiver,
          "file" => call.fetch("file"),
          "function" => call.fetch("function"),
          "line" => call.fetch("line"),
          "span" => call.fetch(span_key),
          "owner" => call.fetch("owner")
        )
      end

      def record_state_write_for_mutating_call(call)
        return unless mutating_receiver_message?(call.fetch("message"))

        field = state_receiver_field(call.fetch("receiver"))
        return unless field

        write = {
          "field" => field,
          "receiver" => "self",
          "file" => call.fetch("file"),
          "function" => call.fetch("function"),
          "line" => call.fetch("line"),
          "span" => call.fetch("span"),
          "owner" => call.fetch("owner")
        }
        key = write.values_at("field", "receiver", "function", "owner", "line", "span")
        return if @seen_writes[key]

        @seen_writes[key] = true
        @facts.fetch(:state_writes) << write
      end

      def push_state_read(read)
        key = read.values_at("field", "receiver", "function", "owner", "line", "span")
        return if @seen_reads[key]

        @seen_reads[key] = true
        @facts.fetch(:state_reads) << read
      end

      def record_semantic_effect(node, kind, detail)
        record_semantic_effect_at(node.first_lineno, span(node), kind, detail)
      end

      def record_semantic_effect_at(line, node_span, kind, detail)
        key = [kind, detail, current_function, line, node_span]
        return if @seen_effects[key]

        @seen_effects[key] = true
        @facts.fetch(:semantic_effect_sites) << {
          "kind" => kind,
          "detail" => detail,
          "file" => @file,
          "function" => current_function,
          "line" => line,
          "span" => node_span
        }
      end

      def record_branch_decision(node, condition)
        return if @extraction_behavior.suppress_branch_decision?(node)

        refs = []
        collect_state_refs(condition, refs)
        refs = refs.uniq.sort
        return if refs.empty?

        @facts.fetch(:branch_decisions) << {
          "file" => @file,
          "function" => current_function,
          "line" => node.first_lineno,
          "span" => span(node),
          "predicate" => branch_predicate_text(node, condition),
          "state_refs" => refs
        }
      end

      def record_if_arms(node, condition)
        return if normalized_ternary_if?(node)

        predicate = normalized_text(condition)
        [[1, "then"], [2, "else"]].each do |index, member|
          arm = child_node(node, index)
          next unless arm

          @facts.fetch(:branch_arms) << {
            "file" => @file,
            "function" => current_function,
            "kind" => "if",
            "line" => arm.first_lineno,
            "span" => span(arm),
            "decision_line" => node.first_lineno,
            "decision_span" => span(node),
            "predicate" => predicate,
            "member" => member,
            "body" => normalized_text(arm)
          }
        end
      end

      def record_case_arm(node, when_node, value)
        return unless value

        body = child_node(when_node, 1)
        return unless body

        when_patterns(when_node).each do |member|
          @facts.fetch(:branch_arms) << {
            "file" => @file,
            "function" => current_function,
            "kind" => "case",
            "line" => when_node.first_lineno,
            "span" => span(when_node),
            "decision_line" => node.first_lineno,
            "decision_span" => span(node),
            "predicate" => normalized_text(value),
            "member" => member,
            "body" => normalized_text(body)
          }
        end
      end

      def record_dispatch_site(node, value, whens)
        predicate = normalized_text(value)
        return if predicate.empty?

        function = current_function
        arm_members = {}
        whens.each do |when_node|
          members = dispatch_members_inside(predicate, function, span(when_node))
          when_patterns(when_node).each do |pattern|
            dispatch_constant_patterns(pattern).each do |variant|
              arm_members[variant] ||= []
              arm_members[variant].concat(members)
            end
          end
        end
        return if arm_members.length < 2

        arm_members.transform_values! { |values| values.uniq.sort }
        site = {
          "variant_set" => arm_members.keys.sort,
          "arm_members" => arm_members,
          "outside" => dispatch_members_outside(predicate, function, span(node)),
          "file" => @file,
          "function" => function,
          "line" => node.first_lineno,
          "span" => span(node)
        }
        @facts.fetch(:dispatch_sites) << site unless @facts.fetch(:dispatch_sites).include?(site)
      end

      def current_owner
        @owners.last || @file_owner
      end

      def current_function
        @functions.last || "(top-level)"
      end

      def current_control
        @controls.last || "always"
      end

      def conditional_context?
        @controls.any? { |control| %w[conditional iterates].include?(control) }
      end

      def with_control(control)
        @controls << control
        yield
      ensure
        @controls.pop
      end

      def apply_visibility!
        owners = @facts.fetch(:function_defs).map { |function| function.fetch("owner") }.uniq
        owners.each { |owner| apply_visibility_for_owner!(owner) }
      end

      def apply_visibility_for_owner!(owner)
        functions = @facts.fetch(:function_defs)
        calls = @facts.fetch(:call_sites)
        function_indices = functions.each_index.select { |index| functions[index].fetch("owner") == owner }
        events = function_indices.map { |index| [functions[index].fetch("line"), 1, index] }
        calls.each_with_index do |call, index|
          next unless call.fetch("owner") == owner &&
                      call.fetch("receiver") == "self" &&
                      %w[public protected private].include?(call.fetch("message"))

          events << [call.fetch("line"), 0, index]
        end

        current = "public"
        events.sort.each do |(_line, kind, index)|
          if kind == 1
            function = functions[index]
            function["visibility"] = function.fetch("name").include?(".") ? "public" : current if function["visibility"] == "public"
            next
          end

          call = calls[index]
          if call.fetch("arguments").empty?
            current = call.fetch("message")
          else
            call.fetch("arguments").each do |argument|
              target = normalized_visibility_argument_name(argument)
              function_indices.reverse_each do |function_index|
                next unless functions[function_index].fetch("name") == target

                functions[function_index]["visibility"] = call.fetch("message")
                break
              end
            end
          end
        end
      end

      def append_effects_from_calls!
        profile = Syntax.language_profile(@language)
        document = OpenStruct.new(
          language: @language,
          call_sites: @facts.fetch(:call_sites).map { |call| OpenStruct.new(call.transform_keys(&:to_sym)) }
        )
        profile.semantic_effect_sites(document).each do |effect|
          @facts.fetch(:semantic_effect_sites) << effect.to_h.transform_keys(&:to_s)
        end
      end

      def dedupe_semantic_effects!
        seen = {}
        @facts[:semantic_effect_sites] = @facts.fetch(:semantic_effect_sites).select do |effect|
          key = effect.values_at("kind", "detail", "function", "line", "span")
          next false if seen[key]

          seen[key] = true
        end.sort_by { |effect| effect.values_at("kind", "detail", "function", "line", "span").map(&:to_s) }
      end

      def call_parts(node)
        case node.type.to_s
        when "VCALL"
          { receiver: "self", message: child_symbol(node, 0), arguments: [], receiver_node: nil, args_node: nil }
        when "FCALL"
          args_node = child_node(node, 1)
          { receiver: "self", message: child_symbol(node, 0), arguments: arguments(args_node),
            receiver_node: nil, args_node: args_node }
        when "CALL", "QCALL"
          receiver_node = child_node(node, 0)
          args_node = child_node(node, 2)
          { receiver: receiver_node ? receiver_text(receiver_node) : "self",
            message: child_symbol(node, 1), arguments: arguments(args_node),
            receiver_node: receiver_node, args_node: args_node }
        end&.then { |parts| parts[:message] ? parts : nil }
      end

      def child_node(node, index)
        child = node.children[index]
        ast_node?(child) ? child : nil
      end

      def child_nodes(node)
        node.children.select { |child| ast_node?(child) }
      end

      def child_symbol(node, index)
        child = node.children[index]
        return child.to_s if child.is_a?(String) || child.is_a?(Symbol)

        nil
      end

      def first_string_or_symbol(node)
        node.children.find { |child| child.is_a?(String) || child.is_a?(Symbol) }&.to_s
      end

      def span(node)
        [node.first_lineno, node.first_column, node.last_lineno, node.last_column]
      end

      def normalized_text(node)
        return quoted_literal_text(node) if quoted_literal_node?(node)
        return splat_prefixed_identifier_text(node) if splat_prefixed_identifier?(node)
        return dot_prefixed_identifier_text(node) if dot_prefixed_identifier?(node)

        normalize_source_text(normalize_text(node.text))
      end

      def normalize_text(text)
        text.to_s.tr("\u00A0", " ").strip.gsub(/\s+/, " ")
      end

      def normalize_source_text(text)
        @extraction_behavior.normalize_source_text(text)
      end

      def receiver_text(node)
        case node.type.to_s
        when "SELF" then "self"
        when "IVAR", "GVAR", "LVAR", "DVAR", "CONST"
          value = first_string_or_symbol(node) || normalized_text(node)
          current_receiver_aliases.fetch(value, value)
        when "CALL", "QCALL"
          parts = call_parts(node)
          parts ? call_source_text(parts, node) : normalized_text(node)
        else
          value = normalized_text(node)
          current_receiver_aliases.fetch(value, value)
        end
      end

      def call_source_text(parts, node = nil)
        receiver = parts.fetch(:receiver).to_s
        message = source_message_text(parts.fetch(:message).to_s, node)
        operator = source_member_operator(node)
        if receiver == "self"
          self_member_receiver(message)
        elsif receiver.empty?
          message
        else
          "#{receiver}#{operator}#{message}"
        end
      end

      def safe_navigation_source?(node)
        node && (node.type.to_s == "QCALL" || node.text.to_s.include?("?.") ||
          node.text.to_s.include?("?->") || node.text.to_s.include?("&."))
      end

      def safe_navigation_operator(node)
        node.text.to_s.include?("&.") ? "&." : "?."
      end

      def source_member_operator(node)
        return safe_navigation_operator(node) if safe_navigation_source?(node)
        return "->" if node&.text.to_s.include?("->")

        "."
      end

      def source_message_text(message, node)
        @extraction_behavior.source_message_text(message, node)
      end

      def self_member_receiver(message)
        @extraction_behavior.self_member_receiver(message)
      end

      def current_receiver_aliases
        @receiver_aliases.each.with_object({}) { |aliases, out| out.merge!(aliases) }
      end

      def arguments(args_node)
        return [] unless args_node
        return [] if args_node.type.to_s == "ZLIST"

        child_nodes(args_node).flat_map { |child| argument_values(child) }
      end

      def argument_values(node)
        if %w[DEFN DEFS].include?(node.type.to_s)
          out = []
          name = function_name(node)
          out << name if name
          body = function_scope(node)&.then { |scope| scope_body(scope) }
          out << normalized_text(body) if body
          return out
        end
        if %w[CALL QCALL].include?(node.type.to_s)
          parts = call_parts(node)
          return [call_source_text(parts, node)] if parts && parts.fetch(:arguments).empty?
        end
        if quoted_literal_node?(node)
          return [quoted_literal_text(node)]
        end
        if %w[LVAR DVAR CONST IVAR GVAR].include?(node.type.to_s)
          value = dot_prefixed_identifier_text(node) || first_string_or_symbol(node)
          return [value] if value
        end
        [normalized_text(node)]
      end

      def owner_name(node)
        child_node(node, 0)&.then { |child| normalized_text(child) }
      end

      def function_name(node)
        if node.type.to_s == "DEFS"
          receiver = child_node(node, 0)&.then { |child| receiver_text(child) }
          name = child_symbol(node, 1)
          return "#{receiver}.#{name}" if receiver && name
        end
        name = child_symbol(node, 0)
        return name.to_s.split(":", 2).last if name.to_s.include?(":")
        return name unless name.to_s.empty?

        function_name_from_text(node.text)
      end

      def function_scope(node)
        child_node(node, node.type.to_s == "DEFS" ? 2 : 1)
      end

      def scope_child(node)
        child_nodes(node).find { |child| child.type.to_s == "SCOPE" }
      end

      def scope_body(scope)
        child_node(scope, 2)
      end

      def scope_args(scope)
        child_node(scope, 1)
      end

      def function_params(node)
        args = function_scope(node)&.then { |scope| scope_args(scope) }
        return function_params_from_signature(node.text) unless args

        params = child_nodes(args).select { |child| child.type.to_s == "LASGN" }
                                .filter_map { |child| first_string_or_symbol(child) }
        params.empty? ? function_params_from_signature(node.text) : params
      end

      def owner_kind(node)
        text = node.text.to_s.strip
        return "impl" if text.start_with?("impl ")
        return "module" if node.type.to_s == "MODULE"

        "class"
      end

      def declarative_owner(node)
        text = node.text.to_s
        case node.type.to_s
        when "STRUCT_ITEM"
          name = text[/\bstruct\s+([A-Za-z_]\w*)/, 1] || owner_name(node)
          owner_row(name, "struct", node) if name
        when "TYPE_DECLARATION"
          name = text[/\Atype\s+([A-Za-z_]\w*)\b/, 1]
          owner_row(name, "owner", node) if name
        when "TYPE_DEFINITION"
          name = text[/}\s*([A-Za-z_]\w*)\s*;/m, 1]
          owner_row(name, "struct", node) if name && text.include?("struct")
        when "VARIABLE_DECLARATION"
          name = text[/\bconst\s+([A-Za-z_]\w*)\s*=\s*struct\b/, 1]
          owner_row(name, "struct", node) if name
        end
      end

      def owner_row(name, kind, node)
        owner_span = owner_name_span(name, node)
        {
          "file" => @file,
          "name" => name,
          "kind" => kind,
          "line" => owner_span.first,
          "span" => owner_span
        }
      end

      def owner_name_span(name, node)
        behavior_span = @extraction_behavior.owner_name_span(name, node, default_span: span(node))
        return behavior_span if behavior_span
        return span(node) if name.to_s.empty?

        lines = node.text.to_s.lines
        offset = lines.index { |line| line.include?(name.to_s) }
        return span(node) unless offset

        line = node.first_lineno + offset
        column = (offset.zero? ? node.first_column : 0) + lines[offset].index(name.to_s).to_i
        [line, column, node.last_lineno, node.last_column]
      end

      def struct_keyword_span(node)
        text = node.text.to_s
        lines = text.lines
        start_offset = lines.index { |line| line.include?("struct") }
        return nil unless start_offset

        end_offset = lines.rindex { |line| line.include?("}") } || lines.length - 1
        start_line = node.first_lineno + start_offset
        end_line = node.first_lineno + end_offset
        start_column = (start_offset.zero? ? node.first_column : 0) + lines[start_offset].index("struct").to_i
        end_column = (end_offset.zero? ? node.first_column : 0) + lines[end_offset].index("}").to_i + 1
        [start_line, start_column, end_line, end_column]
      end

      def owner_name_from_text(node)
        text = node.text.to_s
        text[/\b(?:class|enum|impl|struct)\s+([A-Za-z_]\w*)/, 1]
      end

      def owner_for_function(name, node)
        @extraction_behavior.owner_for_function(name, node, current_owner: current_owner, file_owner: @file_owner)
      end

      def receiver_aliases_for_function(node)
        @extraction_behavior.receiver_aliases_for_function(node)
      end

      def collect_owner_fields(owner, node)
        child_nodes(node).each { |child| collect_owner_fields_from_node(owner, child) }
      end

      def collect_owner_fields_from_node(owner, node)
        return unless ast_node?(node)
        return if %w[DEFN DEFS CLASS MODULE].include?(node.type.to_s)

        if %w[FIELD_DECLARATION PROPERTY_DECLARATION FIELD_DECLARATION_LIST].include?(node.type.to_s)
          if (name = field_name_from_declaration(node))
            @owner_fields[owner] << name
            @owner_fields[owner].uniq!
          end
          child_nodes(node).each do |child|
            collect_owner_fields_from_node(owner, child)
            next unless child.type.to_s == "LVAR"

            name = first_string_or_symbol(child)
            @owner_fields[owner] << name if name && simple_identifier?(name)
          end
          @owner_fields[owner].uniq!
          return
        end

        child_nodes(node).each { |child| collect_owner_fields_from_node(owner, child) }
      end

      def field_name_from_declaration(node)
        return nil unless %w[FIELD_DECLARATION PROPERTY_DECLARATION VARIABLE_DECLARATOR PROPERTY_ELEMENT].include?(node.type.to_s)
        return nil if node.text.to_s.include?("(")

        text = node.text.to_s.strip.sub(/=.*/, "").delete_suffix(";").strip
        name = text.scan(/[A-Za-z_]\w*/).last
        name if name && simple_identifier?(name) && !%w[private protected public readonly static int string].include?(name)
      end

      def owner_field?(field)
        @owner_fields[current_owner].include?(field.to_s)
      end

      def implicit_owner_field_language?
        @extraction_behavior.implicit_owner_fields?
      end

      def target_name_span(name, node)
        text = node.text.to_s
        index = text.index(name.to_s)
        return span(node) unless index && node.first_lineno == node.last_lineno

        [node.first_lineno, node.first_column + index, node.first_lineno, node.first_column + index + name.to_s.length]
      end

      def function_visibility(name, node)
        @extraction_behavior.function_visibility(name, node, lines: @lines)
      end

      def function_name_from_text(text)
        @extraction_behavior.function_name_from_text(text)
      end

      def function_params_from_signature(text)
        source = text.to_s
        params_source = parameter_list_source(source)
        return [] if params_source.empty?

        split_parameters(params_source).filter_map { |param| parameter_name_from_signature(param) }
      end

      def parameter_list_source(source)
        @extraction_behavior.parameter_list_source(source)
      end

      def matching_paren_index(source, open_index)
        depth = 0
        source.chars.each_with_index do |char, index|
          next if index < open_index

          depth += 1 if char == "("
          if char == ")"
            depth -= 1
            return index if depth.zero?
          end
        end
        nil
      end

      def split_parameters(source)
        out = []
        current = +""
        depth = 0
        source.each_char do |char|
          depth += 1 if "([{<".include?(char)
          depth -= 1 if ")]}>".include?(char) && depth.positive?
          if char == "," && depth.zero?
            out << current.strip
            current = +""
          else
            current << char
          end
        end
        out << current.strip unless current.strip.empty?
        out
      end

      def parameter_name_from_signature(param)
        @extraction_behavior.parameter_name_from_signature(param)
      end

      def property_read_call?(node, parts)
        @extraction_behavior.property_read_call?(node, parts)
      end

      def predicate_alias(node, owner)
        name = function_name(node)
        body = function_scope(node)&.then { |scope| scope_body(scope) }
        body = predicate_expression(body)
        text = body && predicate_body_text(normalized_text(body))
        return nil unless name && text

        {
          "name" => name,
          "body" => text,
          "file" => @file,
          "defn" => name,
          "owner" => owner,
          "line" => node.first_lineno,
          "span" => span(node)
        }
      end

      def single_expression(node)
        return nil unless node
        return node unless node.type.to_s == "BLOCK"

        children = child_nodes(node)
        children.length == 1 ? children.first : nil
      end

      def predicate_expression(node)
        single = single_expression(node) if node&.type.to_s == "BLOCK"
        return single if single
        return node if node && !predicate_container_node?(node) && predicate_body_text(normalized_text(node))
        return node if node && child_nodes(node).empty?

        tail_return(node)
      end

      def tail_return(node)
        return nil unless node
        return node if node.type.to_s == "RETURN"

        child_nodes(node).reverse_each do |child|
          found = tail_return(child)
          return found if found
        end
        nil
      end

      def predicate_body_text(source)
        text = source.to_s.delete_prefix("return ").delete_suffix(";").strip
        return nil if text.include?("undefined")
        return nil if text.empty? || text == "nil" || text.length > 200 || assignment_like_predicate_body?(text)

        predicate_like_body?(text) ? text : nil
      end

      def assignment_like_predicate_body?(text)
        return true if text.match?(/\|\|=|&&=|\+=|-=|\*=|\/=|%=/)

        chars = text.chars
        chars.each_cons(3).any? do |left, equals, right|
          equals == "=" && !%w[= ! < >].include?(left) && right != "="
        end
      end

      def predicate_like_body?(text)
        lower = text.downcase
        %w[true false].include?(lower) ||
          lower.match?(/true|false|null|nil/) ||
          text.match?(/==|!=|&&|\|\|/) ||
          text.include?("??") ||
          lower.include?(" and ") ||
          lower.include?(" or ")
      end

      def flatten_and(node)
        return [node] unless node.type.to_s == "AND"

        child_nodes(node).flat_map { |child| flatten_and(child) }
      end

      def when_chain(node)
        out = []
        current = node
        while current&.type.to_s == "WHEN"
          out << current
          child = child_node(current, 2)
          current = child&.type.to_s == "WHEN" ? child : nil
        end
        out
      end

      def when_patterns(when_node)
        patterns = child_node(when_node, 0)
        return [] unless patterns
        raw = normalized_text(patterns)
        case_source = raw.lines.first.to_s[/\Acase\s+(.+):/, 1]
        if case_source
          return [] if case_source == "default"
          return split_case_source(case_source) if case_source.include?(",")
          return [@extraction_behavior.case_pattern_display(case_source)] if case_source.start_with?("\"", "'")
        end

        pattern_values = child_nodes(patterns).map do |child|
          record_literal_state_reads(child)
          normalized_text(child)
        end.reject(&:empty?).reject { |pattern| pattern == "default" }
        @extraction_behavior.case_pattern_values(pattern_values)
      end

      def split_case_source(source)
        @extraction_behavior.split_case_source(source)
      end

      def case_predicate_text(value)
        text = normalized_text(value)
        @extraction_behavior.case_predicate_text(text)
      end

      def boolean_enclosing_span(node)
        @extraction_behavior.boolean_enclosing_span(node, node_span: span(node), decision_span: @decision_spans.last)
      end

      def predicate_container_node?(node)
        %w[BLOCK SCOPE ROOT RETURN COMPOUND_STATEMENT DECLARATION_LIST].include?(node.type.to_s)
      end

      def quoted_literal_node?(node)
        %w[STR STRING STRING_LITERAL STRING_LITERAL_CONTENT STRING_CONTENT LINE_STR_TEXT].include?(node.type.to_s)
      end

      def quoted_literal_text(node)
        text = normalize_source_text(normalize_text(node.text))
        return text if text.start_with?("\"", "'")

        "\"#{text}\""
      end

      def dot_prefixed_identifier?(node)
        dot_prefixed_identifier_text(node)
      end

      def splat_prefixed_identifier?(node)
        splat_prefixed_identifier_text(node)
      end

      def splat_prefixed_identifier_text(node)
        return nil unless %w[LVAR DVAR CONST].include?(node.type.to_s)
        return nil unless node.first_lineno == node.last_lineno

        line = @lines[node.first_lineno - 1].to_s
        return nil unless node.first_column.positive? && line[node.first_column - 1] == "*"

        "*#{first_string_or_symbol(node) || normalize_text(node.text)}"
      end

      def dot_prefixed_identifier_text(node)
        return nil unless %w[LVAR DVAR CONST].include?(node.type.to_s)
        return nil unless node.first_lineno == node.last_lineno

        line = @lines[node.first_lineno - 1].to_s
        return nil unless node.first_column.positive? && line[node.first_column - 1] == "."

        ".#{first_string_or_symbol(node) || normalize_text(node.text)}"
      end

      def case_fallback(node)
        chain = child_node(node, node.type.to_s == "CASE" ? 1 : 0)
        whens = when_chain(chain)
        whens.last&.then { |when_node| child_node(when_node, 2) }&.then do |child|
          child.type.to_s == "WHEN" ? nil : child
        end
      end

      def collect_state_refs(node, refs)
        return unless node

        case node.type.to_s
        when "IVAR", "GVAR"
          name = first_string_or_symbol(node)
          refs << name if name
        when "CALL", "QCALL"
          parts = call_parts(node)
          if parts
            unless parts[:message].to_s == "[]" ||
                   constant_receiver?(parts[:receiver]) ||
                   @extraction_behavior.method_state_ref?(node, parts)
              refs << state_ref_text(node, parts)
            end
          end
          child_nodes(node).each { |child| collect_state_refs(child, refs) }
        when "FIELD_EXPRESSION", "RAW_ARGUMENT"
          text = normalized_text(node)
          refs.concat(@extraction_behavior.literal_state_refs(node, normalized_text: text))
          child_nodes(node).each { |child| collect_state_refs(child, refs) }
        else
          child_nodes(node).each { |child| collect_state_refs(child, refs) }
        end
      end

      def constant_receiver?(receiver)
        receiver.to_s.match?(/\A[:A-Z]/)
      end

      def branch_predicate_text(branch, condition)
        predicate = normalized_text(condition)
        return predicate if predicate.start_with?("(")
        return "(#{predicate})" if wrap_branch_predicate?(branch)

        predicate
      end

      def wrap_branch_predicate?(branch)
        @extraction_behavior.wrap_branch_predicate?(branch)
      end

      def state_ref_text(node, parts)
        receiver = parts.fetch(:receiver)
        message = parts.fetch(:message).to_s
        return explicit_self_state_ref(node, message) if receiver == "self"

        "#{receiver}.#{message}"
      end

      def explicit_self_state_ref(node, message)
        @extraction_behavior.explicit_self_state_ref(node, message)
      end

      def literal_receiver?(receiver)
        receiver.to_s.start_with?("%", "\"", "'", "[", "{")
      end

      def state_receiver_field(receiver)
        text = receiver.to_s.strip
        field = text.delete_prefix("@") if text.start_with?("@")
        field = text.delete_prefix("$") if text.start_with?("$")
        field = text.delete_prefix("self.") if text.start_with?("self.")
        field if field && simple_identifier?(field)
      end

      def mutating_receiver_message?(message)
        %w[
          << []= add append clear collect! compact! concat delete delete_if fill filter!
          keep_if merge! move push reject! replace shift store unshift update write
        ].include?(message) || (message.to_s.end_with?("!") && !%w[!= !~].include?(message))
      end

      def stream_insertion_operator?(node)
        @extraction_behavior.stream_insertion_operator?(node)
      end

      def block_like_hash?(node)
        text = node.text.to_s.strip
        text.start_with?("{") && !text.include?("=>") && !text.include?(":")
      end

      def normalized_ternary_if?(node)
        return false unless node.type.to_s == "IF"

        (node.text.to_s.include?(" ? ") && node.text.to_s.include?(" : ")) ||
          (node.text.to_s.include?(" if ") && node.text.to_s.include?(" else "))
      end

      def normalize_comparison_source(source)
        text = source.to_s.strip
        if text.start_with?("!")
          text = text.delete_prefix("!")
                     .sub(/\A\(+/, "")
                     .sub(/\)+\z/, "")
                     .strip
        end
        text = text.delete_prefix("self.")
        text = text.delete_prefix("@")
        if (dot_index = text.index("."))
          receiver = text[0...dot_index]
          rest = text[(dot_index + 1)..]
          text = rest if simple_identifier?(receiver) && (rest.include?(" == ") || rest.include?(" != ") || rest.include?("."))
        end
        normalize_text(text)
      end

      def raw_from_normalized(node)
        {
          "kind" => raw_kind(node),
          "text" => node.text.to_s,
          "span" => span(node),
          "named" => true,
          "field_name" => nil,
          "children" => node.children.filter_map { |child| raw_child(child) }
        }
      end

      def raw_child(child)
        if ast_node?(child)
          raw_from_normalized(child)
        elsif child.is_a?(String) || child.is_a?(Symbol)
          {
            "kind" => "identifier",
            "text" => child.to_s,
            "span" => [1, 0, 1, 0],
            "named" => true,
            "field_name" => nil,
            "children" => []
          }
        end
      end

      def raw_kind(node)
        {
          "ROOT" => "program",
          "SCOPE" => "body",
          "ARGS" => "parameters",
          "CLASS" => "class",
          "MODULE" => "module",
          "DEFN" => "method",
          "DEFS" => "method",
          "IF" => "if",
          "UNLESS" => "unless",
          "CASE" => "case",
          "CASE2" => "case",
          "WHEN" => "when",
          "AND" => "binary",
          "OR" => "binary",
          "OPCALL" => "binary",
          "LASGN" => "assignment",
          "IASGN" => "assignment",
          "GASGN" => "assignment",
          "ATTRASGN" => "assignment",
          "OP_ASGN1" => "assignment",
          "OP_ASGN2" => "assignment",
          "LVAR" => "identifier",
          "DVAR" => "identifier",
          "CONST" => "identifier",
          "IVAR" => "instance_variable",
          "GVAR" => "global_variable",
          "LIST" => "argument_list",
          "ZLIST" => "argument_list",
          "ITER" => "block",
          "BLOCK" => "body_statement",
          "CALL" => "call",
          "QCALL" => "call",
          "FCALL" => "call",
          "VCALL" => "call",
          "TRUE" => "true",
          "FALSE" => "false",
          "NIL" => "nil",
          "STR" => "string",
          "DSTR" => "string"
        }.fetch(node.type.to_s, node.type.to_s)
      end

      def normalized_row(node)
        {
          "type" => node.type.to_s,
          "children" => node.children.map { |child| normalized_child_row(child) },
          "first_lineno" => node.first_lineno,
          "first_column" => node.first_column,
          "last_lineno" => node.last_lineno,
          "last_column" => node.last_column,
          "text" => node.text.to_s
        }
      end

      def normalized_child_row(child)
        ast_node?(child) ? normalized_row(child) : child
      end

      def empty_normalized_root
        {
          "type" => "ROOT",
          "children" => [],
          "first_lineno" => 1,
          "first_column" => 0,
          "last_lineno" => 1,
          "last_column" => 0,
          "text" => ""
        }
      end

      def dispatch_members_inside(predicate, function, outer)
        dispatch_member_calls(predicate, function).select { |call| span_contains?(outer, call.fetch("span")) }
                                                .map { |call| dispatch_member_name(call) }
                                                .uniq.sort
      end

      def dispatch_members_outside(predicate, function, decision_span)
        dispatch_member_calls(predicate, function).reject { |call| span_contains?(decision_span, call.fetch("span")) }
                                                .map { |call| dispatch_member_name(call) }
                                                .uniq.sort
      end

      def dispatch_member_calls(predicate, function)
        @facts.fetch(:call_sites).select do |call|
          call.fetch("function") == function &&
            call.fetch("receiver") == predicate &&
            !call.fetch("message").empty?
        end
      end

      def dispatch_member_name(call)
        call.fetch("message").delete_suffix("=")
      end

      def dispatch_constant_patterns(member)
        member.to_s.split(",").map(&:strip).select { |pattern| dispatch_constant_pattern?(pattern) }
      end

      def dispatch_constant_pattern?(pattern)
        return false if pattern.empty?

        pattern.tr("::", ".").split(/[._]/).reject(&:empty?).all? do |part|
          part.match?(/\A[A-Z][A-Za-z0-9_]*\z/)
        end
      end

      def span_contains?(outer, inner)
        (outer[0] < inner[0] || (outer[0] == inner[0] && outer[1] <= inner[1])) &&
          (outer[2] > inner[2] || (outer[2] == inner[2] && outer[3] >= inner[3]))
      end

      def simple_identifier?(value)
        value.to_s.match?(/\A[_A-Za-z][_A-Za-z0-9!?]*\z/)
      end

      def span_source(source_span)
        return "" unless source_span && source_span.length == 4

        first_line, first_column, last_line, last_column = source_span
        if first_line == last_line
          return @lines[first_line - 1].to_s.byteslice(first_column...last_column).to_s
        end

        parts = [@lines[first_line - 1].to_s.byteslice(first_column..).to_s]
        parts.concat(@lines[first_line...(last_line - 1)] || [])
        parts << @lines[last_line - 1].to_s.byteslice(0...last_column).to_s
        parts.join
      end

      def normalized_visibility_argument_name(argument)
        argument.to_s.strip
                .delete_prefix(":")
                .delete_prefix("\"")
                .delete_suffix("\"")
                .delete_prefix("'")
                .delete_suffix("'")
                .split(/\s+/)
                .first.to_s
      end

      def dedupe_decision_sites(sites)
        seen = {}
        sites.select do |site|
          key = site.values_at("kind", "members", "file", "function", "line", "span", "predicate", "enclosing_span")
          next false if seen[key]

          seen[key] = true
        end
      end

      def ast_node?(node)
        Ast.node?(node)
      end
    end
  end
end
