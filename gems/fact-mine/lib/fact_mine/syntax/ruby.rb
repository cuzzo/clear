# frozen_string_literal: true

module FactMine
  module Syntax
    RUBY_LEXICON = LanguageLexicon.new(
      nil_literal_patterns: [/\bnil\b/].freeze,
      guard_mids: %w[is_a? kind_of? instance_of? nil? respond_to?].freeze,
      type_guard_patterns: [
        /(?:\A|[^\w!?])(?:nil\?|is_a\?|kind_of\?|instance_of\?|respond_to\?)(?:\s*\(|\b)/,
        /&\./
      ].freeze,
      diagnostic_patterns: [
        /(?:\A|[^\w!?])(?:raise|fail|abort)[!?]?(?:\s*\(|\b)/
      ].freeze,
      trivial_patterns: [
        /\A(?:nil|true|false|0|1|break|next)\s*;?\z/,
        /\Areturn\s+(?:nil|true|false|0|1)\s*;?\z/
      ].freeze
    ).freeze

    RUBY_EFFECT_LEXICON = EffectLexicon.new(
      dispatch_mids: %w[send __send__ public_send const_get constantize
                        instance_variable_get].freeze,
      meta_mids: %w[define_method define_singleton_method alias_method
                    class_eval module_eval instance_eval class_exec
                    module_exec instance_exec eval const_set
                    instance_variable_set remove_method undef_method
                    prepend singleton_class binding].freeze,
      method_obj_mids: %w[method public_method instance_method].freeze,
      io_consts: %w[File IO Dir FileUtils Open3 Socket TCPSocket UDPSocket
                    TCPServer UNIXSocket Tempfile Pathname Marshal].freeze,
      io_pairs: {
        "Net" => %w[get post post_form start],
        "URI" => %w[open]
      }.freeze,
      io_bare: %w[puts print warn gets readline readlines system
                  exec spawn fork sleep open abort exit exit!].freeze,
      dir_context: %w[pwd getwd home].freeze,
      context_pairs: {
        "Time" => %w[now current], "Date" => %w[today current],
        "DateTime" => %w[now current], "Process" => %w[pid ppid uid gid euid],
        "Thread" => %w[current list main], "Fiber" => %w[current],
        "Random" => %w[rand bytes], "GC" => %w[stat count],
        "ObjectSpace" => %w[each_object count_objects]
      }.freeze,
      context_bare: %w[rand srand].freeze,
      callback_set: %w[transaction synchronize lock with_lock unlock
                       mutex atomic reentrant subscribe callback hook].freeze,
      callback_requires_block: false,
      core_consts: %w[String Symbol Integer Float Numeric Rational Complex
                      Array Hash Set Range Struct Object BasicObject Kernel
                      Module Class Comparable Enumerable Enumerator Proc Method
                      UnboundMethod NilClass TrueClass FalseClass Exception
                      StandardError RuntimeError ArgumentError TypeError
                      NameError NoMethodError IO File Dir Time Date DateTime
                      Regexp MatchData Thread Mutex Fiber Process Math GC
                      ObjectSpace Marshal Random Encoding].freeze
    ).freeze
    Syntax.register_effect_lexicon(:ruby, RUBY_EFFECT_LEXICON)

    RUBY_PROTOCOL_DECLARATIVE_MIDS = %w[
      abstract! alias_method any attr_accessor attr_reader attr_writer bind
      cast checked enum extend final include interface! let must must_because
      nilable override overridable params prepend private private_class_method
      protected public require require_relative requires_ancestor sealed! sig
      type_member type_template untyped unsafe void
    ].freeze
    RUBY_PROTOCOL_TEST_DSL_MIDS = %w[
      a_kind_of after around before be be_a be_an be_empty be_falsey be_nil
      be_truthy change contain_exactly context describe eq eql equal expect
      have_attributes have_key have_received it match not_to raise_error
      receive subject to
    ].freeze
    RUBY_PROTOCOL_IGNORED_MIDS = (RUBY_PROTOCOL_DECLARATIVE_MIDS + RUBY_PROTOCOL_TEST_DSL_MIDS).freeze
    RUBY_PROTOCOL_OPTIONAL_DIAGNOSTIC_MIDS = %w[
      error! fixable! read_interpolated_string warn!
    ].freeze
    RUBY_PROTOCOL_MUTATING_MIDS = %w[
      << []= add append clear collect! compact! concat declare delete delete_if
      each_key= fill filter! keep_if mark merge! move push reject! replace
      resolve shift stamp store unshift update write
    ].freeze
    RUBY_PROTOCOL_NON_MUTATING_OPERATOR_MIDS = %w[! != !~].freeze
    RUBY_PROTOCOL_MUTATING_SUFFIXES = %w[!].freeze
    RUBY_PROTOCOL_LEXICON = ProtocolLexicon.new(
      path_limit: 64,
      declarative_mids: RUBY_PROTOCOL_DECLARATIVE_MIDS,
      test_dsl_mids: RUBY_PROTOCOL_TEST_DSL_MIDS,
      ignored_mids: RUBY_PROTOCOL_IGNORED_MIDS,
      optional_diagnostic_mids: RUBY_PROTOCOL_OPTIONAL_DIAGNOSTIC_MIDS,
      mutating_mids: RUBY_PROTOCOL_MUTATING_MIDS,
      non_mutating_operator_mids: RUBY_PROTOCOL_NON_MUTATING_OPERATOR_MIDS,
      mutating_suffixes: RUBY_PROTOCOL_MUTATING_SUFFIXES
    ).freeze
    Syntax.register_protocol_lexicon(:ruby, RUBY_PROTOCOL_LEXICON)

    class RubySyntaxAdapter < TreeSitterLanguageAdapter
      FUNCTION_NODE_KINDS = %w[method].freeze
      CALL_NODE_KINDS = %w[call].freeze
      CLASS_OWNER_NODE_KINDS = %w[class].freeze
      MODULE_OWNER_NODE_KINDS = %w[module].freeze
      PARAMETER_LIST_NODE_KINDS = %w[method_parameters].freeze
      FUNCTION_BODY_NODE_KINDS = %w[body_statement do_block].freeze
      NESTED_STATEMENT_WRAPPER_NODE_KINDS = %w[body_statement].freeze
      IDENTIFIER_NODE_KINDS = %w[identifier constant].freeze
      FIELD_IDENTIFIER_NODE_KINDS = [].freeze
      PARAMETER_IDENTIFIER_NODE_KINDS = %w[identifier].freeze
      LOCAL_IDENTIFIER_WRAPPER_NODE_KINDS = %w[pattern].freeze
      ASSIGNMENT_NODE_KINDS = %w[assignment operator_assignment].freeze
      ASSIGNMENT_OPERATOR_TOKENS = %w[= += -= *= /= %= &&= ||=].freeze
      PATH_ACTION_NODE_KINDS = %w[call return].freeze
      SIMPLE_ACTION_WRAPPER_NODE_KINDS = %w[body_statement].freeze
      COMPARISON_NODE_KINDS = %w[binary].freeze
      BRANCH_NODE_KINDS = %w[if unless if_modifier unless_modifier case while until for].freeze
      LOOP_NODE_KINDS = %w[while until for do_block].freeze
      BRANCH_LOOP_NODE_KINDS = LOOP_NODE_KINDS
      CASE_NODE_KINDS = %w[case].freeze
      BRANCH_CASE_NODE_KINDS = %w[case body_statement].freeze
      IF_NODE_KINDS = %w[if unless if_modifier unless_modifier].freeze
      HIDDEN_IF_WRAPPER_NODE_KINDS = %w[body_statement].freeze
      HIDDEN_CASE_WRAPPER_NODE_KINDS = %w[body_statement].freeze
      HIDDEN_IF_TOKEN_KINDS = %w[if unless].freeze
      HIDDEN_CASE_TOKEN_KINDS = %w[case when].freeze
      CASE_ARM_NODE_KINDS = %w[when].freeze
      WHEN_CASE_ARM_NODE_KINDS = %w[when].freeze
      CASE_PATTERN_NODE_KINDS = %w[pattern].freeze
      CASE_CONTAINER_STOP_NODE_KINDS = %w[method class module].freeze
      CASE_SUBJECT_SKIP_NODE_KINDS = %w[when else then comment].freeze
      DEFAULT_CASE_PATTERNS = %w[_ default else].freeze
      BOOLEAN_AND_OPERATORS = %w[&& and].freeze
      BOOLEAN_CONTAINER_NODE_KINDS = %w[binary].freeze
      BOOLEAN_WRAPPER_NODE_KINDS = %w[body_statement block_body pattern argument_list].freeze
      PARENTHESIZED_PATTERN_NODE_KINDS = %w[pattern].freeze
      ACCESSOR_CALL_NODE_KINDS = %w[call].freeze
      BLOCK_ARGUMENT_NODE_KINDS = %w[block do_block lambda].freeze
      SELF_RECEIVER_NAMES = %w[self].freeze

      def function_name(node)
        case node.kind
        when "body_statement"
          hidden_ruby_method_name(node)
        when "singleton_method"
          receiver = named_field(node, "receiver") ||
                     node.named_children.find { |child| %w[self constant identifier].include?(child.kind) }
          name = named_field(node, "name")&.text ||
                 node.named_children.reverse.find do |child|
                   %w[identifier field_identifier property_identifier].include?(child.kind)
                 end&.text
          receiver_text = receiver&.text.to_s
          name && "#{receiver_text.empty? || receiver_text == "self" ? "self" : receiver_text}.#{name}"
        when "argument_list"
          inline_def_name(node)
        else
          super
        end
      end

      def visibility(_document, node)
        return ruby_inline_def_visibility(node) if inline_def_argument_list?(node)

        ruby_method_visibility(node)
      end

      def owner_name_from_declaration(document, node)
        return hidden_ruby_owner_name(node) if hidden_ruby_owner_declaration?(node)

        super
      end

      def owner_kind(node)
        return hidden_ruby_owner_kind(node) if hidden_ruby_owner_declaration?(node)

        super
      end

      def call_target(document, node)
        target =
          case node.kind
          when "call"
            ruby_proc_call_target(node) || ruby_call_target(node)
          when "body_statement", "block_body"
            ruby_bare_body_call_target(node)
          when "identifier"
            ruby_bare_call_target(node)
          else
            super
          end
        return nil if target && ruby_chained_element_predicate?(target[:receiver], target[:message])

        target
      end
    end


    class RubySyntaxAdapter
      def function_params(node)
        return hidden_ruby_method_params(node) if hidden_ruby_method_definition?(node)

        params = super
        if inline_def_argument_list?(node)
          params = node.named_children.find { |child| child.kind == "method_parameters" }
                       &.named_children
                       &.filter_map { |param| parameter_name(param) }
                       &.uniq || params
        end
        params
      end

      def function_signature(document, node)
        if hidden_ruby_method_definition?(node)
          return normalize_text(hidden_ruby_method_signature(document, node))
        end

        signature = preceding_ruby_signature(document, node)
        return signature unless signature.empty?

        super
      end

      def state_declaration(node)
        ruby_t_let_state_declaration(node) || super
      end

      def state_read_target(node)
        target = ruby_single_call_wrapper_state_read_target(node)

        if target.nil? && ruby_explicit_receiver_body_read_node?(node) &&
           (call_target = ruby_explicit_receiver_body_call_target(node))
          target = { receiver: call_target[:receiver], field: call_target[:message] }
        end

        target ||= ruby_unparenthesized_member_argument_target(node) || ruby_state_variable_target(node) || super
        return nil unless target
        return nil if ruby_non_state_receiver?(target[:receiver])
        return nil if ruby_chained_element_predicate?(target[:receiver], target[:field])

        target
      end

      def ruby_single_call_wrapper_state_read_target(node)
        return nil unless ts_node?(node) && node.kind == "body_statement"

        named = node.named_children.reject { |child| child.kind == "comment" }
        return nil unless named.size == 1

        child = named.first
        return nil unless child.kind == "call"
        return nil unless normalize_text(child.text) == normalize_text(node.text)

        state_read_target(child)
      end

      def state_target(lhs)
        ruby_state_variable_target(lhs) || super
      end

      def visibility_events(_document, facts)
        ruby_visibility_calls(facts.fetch(:call_sites)).map do |call|
          VisibilityEvent.new(
            owner: call.owner,
            visibility: call.message.to_sym,
            line: call.line,
            span: call.span,
            target_names: call.arguments.to_a.map { |arg| ruby_visibility_arg_name(arg) }.reject(&:empty?)
          )
        end
      end

      def descend_into_children?(node, stack)
        return false if node.kind == "lambda"
        return false if ruby_stabby_lambda_node?(node)
        return false if dynamic_nested_local_scope?(node) && stack.any? { |frame| frame[:function] }

        true
      end

      def predicate_def(_document, function_def)
        nil
      end

      def local_methods(document)
        []
      end

      def path_condition_sites(document)
        []
      end

      def immutable_struct_readers(document)
        ruby_immutable_struct_readers(document.lines)
      end

      def immutable_struct_reader_types(document)
        ruby_immutable_struct_reader_types(document.lines)
      end

      def type_aliases(document)
        ruby_type_aliases(document.lines)
      end

      private

      def comparison_target(node)
        ruby_nil_predicate_comparison(node) || ruby_flat_comparison_statement(node) || super
      end

      def ruby_nil_predicate_comparison(node)
        return nil unless node.kind == "call"

        target = ruby_call_target(node)
        return nil unless target && target[:message].to_s == "nil?"

        { source: normalize_text(node.text), operator: "nil?" }
      end

      def ruby_flat_comparison_statement(node)
        return nil unless node.kind == "body_statement"

        operator = direct_operator(node)
        return nil unless COMPARISON_OPERATORS.include?(operator)

        { source: normalize_text(node.text), operator: operator }
      end

      def inline_def_argument_list?(node)
        ts_node?(node) && node.kind == "argument_list" && node.children.first&.kind.to_s == "def"
      end

      def inline_def_name(node)
        return nil unless inline_def_argument_list?(node)

        receiver_index = node.named_children.index { |child| child.kind == "self" || child.kind == "constant" }
        search = receiver_index ? node.named_children[(receiver_index + 1)..] : node.named_children
        name = search&.find { |child| %w[identifier field_identifier property_identifier].include?(child.kind) }&.text
        receiver_index ? "self.#{name}" : name
      end

      def hidden_ruby_method_definition?(node)
        ts_node?(node) && node.kind == "body_statement" && node.children.first&.kind.to_s == "def"
      end

      def hidden_ruby_method_name(node)
        return nil unless hidden_ruby_method_definition?(node)

        receiver_index = node.named_children.index { |child| child.kind == "self" || child.kind == "constant" }
        search = receiver_index ? node.named_children[(receiver_index + 1)..] : node.named_children
        name = search&.find { |child| %w[identifier field_identifier property_identifier].include?(child.kind) }&.text
        receiver_index ? "self.#{name}" : name
      end

      def hidden_ruby_method_params(node)
        params = node.named_children.find { |child| child.kind == "method_parameters" }
        return [] unless params

        params.named_children.filter_map { |param| parameter_name(param) }.uniq
      end

      def hidden_ruby_method_signature(document, node)
        body = node.named_children.find { |child| child.kind == "body_statement" }
        end_byte = body ? body.start_byte : node.end_byte
        document.source.byteslice(node.start_byte, end_byte - node.start_byte).to_s.strip.sub(/;+\z/, "")
      rescue StandardError
        line_text(document, node).strip
      end

      def ruby_endless_method_expression(node)
        return nil unless ts_node?(node)
        return nil unless %w[method singleton_method].include?(node.kind)
        return nil if node.named_children.any? { |child| child.kind == "body_statement" }

        node.named_children.reverse.find do |child|
          !%w[
            identifier field_identifier property_identifier constant self
            method_parameters superclass
          ].include?(child.kind)
        end
      end

      def ruby_method_body_wrapper(node)
        return nil unless ts_node?(node)

        case node.kind
        when "method", "singleton_method", "argument_list"
          node.named_children.reverse.find { |child| child.kind == "body_statement" }
        when "body_statement"
          if hidden_ruby_method_definition?(node)
            node.named_children.reverse.find { |child| child.kind == "body_statement" }
          else
            node
          end
        end
      end

      def dynamic_method_body_wrapper(node)
        ruby_method_body_wrapper(node)
      end

      def dynamic_endless_function_expression(node)
        ruby_endless_method_expression(node)
      end

      def dynamic_hidden_if?(node)
        hidden_if?(node)
      end

      def dynamic_hidden_modifier_if?(node)
        hidden_modifier_if?(node)
      end

      def dynamic_hidden_case?(node)
        hidden_case?(node)
      end

      def dynamic_modifier_if_node_kind?(kind)
        %w[if_modifier unless_modifier].include?(kind)
      end

      def dynamic_flat_predicate_body_statement?(body, source)
        body.kind == "body_statement" &&
          dynamic_predicate_body?(source) &&
          COMPARISON_OPERATORS.include?(direct_operator(body))
      end

      def dynamic_heredoc_body?(_body, named_children)
        named_children.first&.kind == "call" &&
          named_children[1..].to_a.all? { |child| child.kind == "heredoc_body" }
      end

      def dynamic_nested_local_scope?(node)
        %w[class module method singleton_method lambda].include?(node.kind)
      end

      def ruby_stabby_lambda_node?(node)
        return false unless ts_node?(node)
        return true if node.kind == "body_statement" && node.children.first&.kind == "->"

        node.kind == "block" && prev_sibling(node)&.kind == "->"
      end

      def dynamic_local_read_identifier?(node, local_names)
        return false unless node.kind == "identifier"
        return false unless local_names.include?(node.text.to_s)
        return false if dynamic_local_write_identifier?(node)
        return false if ruby_declaration_name?(node, parent_node(node))
        return false if dynamic_call_message_identifier?(node)
        return false if ruby_unary_assertion_argument?(node)

        true
      end

      def dynamic_local_write_identifier?(node)
        return false unless node.kind == "identifier"

        parent = parent_node(node)
        (parent&.kind == "assignment" && parent.named_children.first == node) ||
          (parent&.kind == "left_assignment_list" && parent_node(parent)&.kind == "assignment") ||
          (dynamic_flat_assignment_statement?(parent) && parent.named_children.first == node)
      end

      def ruby_unparenthesized_member_argument_target(node)
        return nil unless node.kind == "argument_list"
        return nil if node.text.to_s.strip.start_with?("(")
        return nil unless node.children.any? { |child| !child.named? && child.text == "." }

        named = node.named_children
        return nil unless named.size == 2
        return nil unless named.all? { |child| %w[identifier constant].include?(child.kind) }

        { receiver: normalize_text(named.first.text), field: named.last.text }
      end

      def ruby_unary_assertion_argument?(node)
        parent = parent_node(node)
        return false unless parent&.kind == "argument_list"

        call = parent_node(parent)
        return false unless call&.kind == "call"
        return false unless %w[assert_empty refute_empty assert_nil refute_nil].include?(call.named_children.first&.text)

        true
      end

      def dynamic_flat_assignment_statement?(node)
        return false unless ts_node?(node) && node.kind == "body_statement"

        node.children.count { |child| !child.named? && child.text == "=" } == 1 &&
          node.named_children.size >= 2
      end

      def dynamic_call_message_identifier?(node)
        parent = parent_node(node)
        return false unless parent&.kind == "call"

        prev_sibling(node)&.text == "." ||
          (named_field(parent, "receiver").nil? && parent.named_children.first == node)
      end

      def dynamic_local_flow_owner(document, owner)
        owner.to_s == file_owner(document.file) ? "(top-level)" : owner
      end

      def hidden_ruby_owner_declaration?(node)
        return false unless ts_node?(node)
        return false unless node.kind == "body_statement"

        %w[class module].include?(node.children.first&.kind.to_s)
      end

      def hidden_ruby_owner_name(node)
        node.named_children.find { |child| %w[constant identifier type_identifier].include?(child.kind) }&.text
      end

      def hidden_ruby_owner_kind(node)
        node.children.first&.kind.to_s == "module" ? :module : :class
      end

      def ruby_method_visibility(node)
        modifier_visibility(node)
      end

      def ruby_inline_def_visibility(node)
        parent = parent_node(node)
        return nil unless parent&.kind == "call"

        target = ruby_call_target(parent)
        visibility = target && target[:receiver] == "self" && target[:message]&.to_sym
        %i[private protected public].include?(visibility) ? visibility : nil
      end

      def ruby_call_target(node)
        receiver = named_field(node, "receiver")
        method = named_field(node, "method")
        message = method&.text || first_named_text(node, %w[identifier constant])
        message ||= normalize_text(node.text) if receiver.nil? && ruby_simple_call_text?(node.text)
        return nil unless message

        {
          receiver: receiver ? normalize_text(receiver.text) : "self",
          message: message,
          arguments: ruby_argument_texts(node),
          safe_navigation: ruby_safe_navigation_call?(node)
        }
      end

      def ruby_bare_call_target(node)
        return nil unless ruby_bare_call_identifier?(node)

        parent = parent_node(node)
        source_node =
          if parent&.kind == "call" || next_sibling(node)&.kind == "argument_list"
            parent
          else
            node
          end
        {
          receiver: "self",
          message: node.text,
          arguments: ruby_argument_texts(source_node),
          source_node: source_node,
          safe_navigation: source_node && ruby_safe_navigation_call?(source_node)
        }
      end

      def ruby_bare_body_call_target(node)
        return nil if hidden_ruby_method_definition?(node) || hidden_ruby_owner_declaration?(node)

        explicit = ruby_explicit_receiver_body_call_target(node)
        return explicit if explicit

        message = node.text.to_s.strip
        return nil unless ruby_simple_call_text?(message)
        return nil if %w[true false nil self].include?(message)

        {
          receiver: "self",
          message: message,
          arguments: []
        }
      end

      def ruby_explicit_receiver_body_call_target(node)
        return nil unless node.children.any? { |child| !child.named? && child.text == "." }

        receiver, message = node.named_children
        return nil unless receiver && message
        return nil if ruby_implicit_self_call_receiver?(receiver)
        return nil unless %w[self constant identifier scope_resolution call].include?(receiver.kind) ||
                          ruby_constant_constructor_call?(receiver)
        return nil unless %w[identifier constant].include?(message.kind)

        {
          receiver: normalize_text(receiver.text),
          message: message.text,
          arguments: ruby_argument_texts(node)
        }
      end

      def ruby_non_state_receiver?(receiver)
        text = receiver.to_s
        return true if text.empty?
        return true if text.match?(/[\n{}]/)
        return true if text.start_with?("%", "[", "\"", "'")
        return true if ruby_core_effect_receiver?(text)

        false
      end

      def ruby_core_effect_receiver?(receiver)
        base = receiver.to_s.sub(/\A::/, "").split("::").first
        RUBY_EFFECT_LEXICON.io_consts.include?(base) ||
          RUBY_EFFECT_LEXICON.context_pairs.key?(base) ||
          base == "ENV"
      end

      def ruby_implicit_self_call_receiver?(receiver)
        return false unless ts_node?(receiver) && receiver.kind == "call"
        return false if named_field(receiver, "receiver")

        method = named_field(receiver, "method") ||
                 receiver.named_children.find { |child| %w[identifier constant].include?(child.kind) }
        ruby_simple_call_text?(method&.text)
      end

      def ruby_chained_element_predicate?(receiver, message)
        message.to_s.end_with?("?") &&
          receiver.to_s.include?(".") &&
          receiver.to_s.match?(/\[(?::|"|')/)
      end

      def ruby_explicit_receiver_body_read_node?(node)
        return true if node.kind == "block_body"

        return false unless node.kind == "body_statement"
        return true if parent_node(node)&.kind == "do_block"
        return false if hidden_ruby_method_definition?(node) || hidden_ruby_owner_declaration?(node)

        node.children.any? { |child| !child.named? && child.text == "." }
      end

      def ruby_constant_constructor_call?(node)
        return false unless ts_node?(node) && node.kind == "call"

        receiver = named_field(node, "receiver") || node.named_children.first
        method = named_field(node, "method") || node.named_children[1]
        receiver&.kind == "constant" && method&.text == "new"
      end

      def ruby_simple_call_text?(text)
        text.to_s.strip.match?(/\A[a-z_]\w*[!?=]?\z/)
      end

      def ruby_bare_call_identifier?(node)
        parent = parent_node(node)
        return false unless parent
        return false if ruby_declaration_name?(node, parent)
        return false if %w[method_parameters block_parameters argument_list assignment].include?(parent.kind)
        if parent.kind == "call"
          return false if named_field(parent, "receiver")

          first = parent.named_children.first
          return first == node && next_sibling(node)&.kind == "argument_list"
        end
        return false if next_sibling(node)&.text == "=" || prev_sibling(node)&.text == "="
        return false if next_sibling(node)&.text == "." || prev_sibling(node)&.text == "."

        %w[body_statement then else elsif ensure rescue if_modifier unless_modifier].include?(parent.kind) ||
          next_sibling(node)&.kind == "argument_list"
      end

      def ruby_declaration_name?(node, parent)
        return true if hidden_ruby_method_definition?(parent)
        return true if hidden_ruby_owner_declaration?(parent)
        return true if %w[method singleton_method class module].include?(parent.kind)

        false
      end

      def ruby_argument_texts(node)
        args = named_field(node, "arguments") || node.named_children.find { |child| child.kind == "argument_list" }
        return [] unless args

        values = args.named_children.map { |child| normalize_text(child.text) }
        return values unless values.empty?

        text = args.text.to_s.strip
        text = text[1...-1] if text.start_with?("(") && text.end_with?(")")
        text.split(/\s*,\s*/).map { |arg| normalize_text(arg) }.reject(&:empty?)
      end

      def ruby_proc_call_target(node)
        return nil unless ts_node?(node) && node.kind == "call"
        return nil unless node.children.any? { |child| !child.named? && child.text == "." }
        return nil unless named_field(node, "method").nil?

        receiver = named_field(node, "receiver") || node.named_children.first
        args = named_field(node, "arguments") ||
               node.named_children.find { |child| child.kind == "argument_list" }
        return nil unless receiver && args

        {
          receiver: normalize_text(receiver.text),
          message: "call",
          arguments: ruby_argument_texts(node),
          safe_navigation: ruby_safe_navigation_call?(node),
          block: call_has_block?(node)
        }
      end

      def ruby_safe_navigation_call?(node)
        ts_node?(node) && node.children.any? { |child| !child.named? && child.text == "&." }
      end

      def ruby_t_let_state_declaration(node)
        lhs = named_field(node, "left") || node.named_children.first
        rhs = named_field(node, "right") || named_field(node, "value") || node.named_children[1]
        target = state_target(lhs)
        return nil unless target && target[:receiver] == "self" && target[:field].to_s.start_with?("@")
        return nil unless rhs&.kind == "call"

        receiver = named_field(rhs, "receiver") || rhs.named_children.first
        method = named_field(rhs, "method") || rhs.named_children.find { |child| child.kind == "identifier" }
        return nil unless receiver&.text == "T" && method&.text == "let"

        args = named_field(rhs, "arguments") || rhs.named_children.find { |child| child.kind == "argument_list" }
        type = args&.named_children&.[](1)&.text
        return nil if type.to_s.empty?

        { field: target[:field], type: normalize_text(type) }
      end

      def skip_state_write_node?(node)
        node.kind == "operator_assignment" ||
          (assignment_lhs?(node) && next_sibling(node)&.text.to_s != "=" && !ruby_instance_variable_node?(node))
      end

      def skip_state_write_target?(target)
        super || target[:field].to_s.start_with?("$")
      end

      def state_write_source_node(node)
        assignment_lhs?(node) ? (parent_node(node) || node) : super
      end

      def direct_state_ref(node)
        node.text if ruby_state_variable_node?(node)
      end

      def hidden_if?(node)
        return false unless ts_node?(node)
        return false unless %w[expression_statement block body_statement].include?(node.kind)

        %w[if unless].include?(first_token_kind(node))
      end

      def hidden_modifier_if?(node)
        return false unless ts_node?(node)
        return false unless node.kind == "body_statement"

        seen_named = false
        node.children.any? do |child|
          seen_named ||= child.named?
          seen_named && !child.named? && %w[if unless].include?(child.kind)
        end
      end

      def modifier_condition(node)
        node.named_children.last
      end

      def hidden_case?(node)
        return false unless ts_node?(node)
        return false unless %w[body_statement block_body argument_list].include?(node.kind)

        first_token_kind(node) == "case"
      end

      def hidden_match?(node)
        node.kind == "expression_statement" &&
          first_token_kind(node) == "match" &&
          node.named_children.any? { |child| child.kind == "match_block" }
      end

      def case_pattern_texts(patterns)
        texts = super
        return texts unless texts.any? { |text| text.start_with?("*") }

        out = []
        pending_plain = []
        texts.each_with_index do |text, index|
          if text.start_with?("*")
            out << pending_plain.join(", ") unless pending_plain.empty?
            pending_plain = []
            out << if texts.size == 1 || index.positive?
                     text.delete_prefix("*")
                   else
                     text
                   end
          else
            pending_plain << text
          end
        end
        out << pending_plain.join(", ") unless pending_plain.empty?
        out
      end

      def ruby_state_variable_target(node)
        return nil unless ruby_state_variable_node?(node)

        { receiver: "self", field: node.text }
      end

      def ruby_state_variable_node?(node)
        return false unless ts_node?(node)
        return false if ruby_embedded_text_node?(node) && !ruby_interpolated_indexed_state_variable?(node)
        return true if %w[instance_variable global_variable].include?(node.kind)

        node.named_children.empty? && node.text.to_s.match?(/\A[@$][A-Za-z_]\w*[!?=]?\z/)
      end

      def ruby_interpolated_indexed_state_variable?(node)
        parent = parent_node(node)
        return false unless parent&.kind == "element_reference"
        return false unless parent.named_children.first == node

        ruby_embedded_text_node?(parent)
      end

      def ruby_embedded_text_node?(node)
        current = node
        while ts_node?(current)
          return true if %w[string string_content heredoc_body simple_symbol symbol delimited_symbol].include?(current.kind)

          current = parent_node(current)
        end
        false
      end

      def ruby_instance_variable_node?(node)
        ts_node?(node) && node.kind == "instance_variable"
      end

      def preceding_ruby_signature(document, node)
        cursor = line(node) - 2
        lines = document.lines
        cursor -= 1 while cursor >= 0 && lines[cursor].to_s.strip.empty?
        return "" if cursor.negative?

        stripped = lines[cursor].to_s.strip
        if stripped == "end"
          start = cursor
          while start >= 0
            text = lines[start].to_s.strip
            return normalize_text(lines[start..cursor].join("\n")) if text == "sig do"
            return "" if start != cursor && text.match?(/\A(?:def|class|module)\b/)

            start -= 1
          end
          return "" if start.negative?
        end

        return normalize_text(stripped) if stripped.start_with?("sig ")
        return "" unless stripped == "}" || stripped.end_with?("}")

        start = cursor
        while start >= 0
          text = lines[start].to_s.strip
          return normalize_text(lines[start..cursor].join("\n")) if text.start_with?("sig ")
          return "" if text.match?(/\A(?:def|class|module)\b/)

          start -= 1
        end
        ""
      end

      def method_param_types(document)
        types_by_method = {}
        pending_sig = +""
        document.lines.each do |line|
          pending_sig << line if pending_sig_active?(line, pending_sig)
          if (match = line.match(/\A\s*def\s+([A-Za-z_]\w*[!?=]?)(?:\s|\(|$)/))
            types_by_method[match[1]] = sig_param_types(pending_sig)
            pending_sig = +""
          end
        end
        types_by_method
      end

      def pending_sig_active?(line, pending_sig)
        !pending_sig.empty? || line.match?(/\A\s*sig\b/)
      end

      def sig_param_types(sig_source)
        match = sig_source.match(/params\s*\((.*?)\)/m)
        return {} unless match

        match[1].scan(/([A-Za-z_]\w*)\s*:\s*([A-Za-z_]\w*(?:::[A-Za-z_]\w*)*)/).to_h
      end

      def ruby_immutable_struct_readers(lines)
        readers = Hash.new { |h, k| h[k] = Set.new }
        class_stack = []
        lines.each do |line|
          if (match = line.match(/\A\s*class\s+([A-Za-z_]\w*(?:::[A-Za-z_]\w*)*)\s*<\s*T::Struct\b/))
            class_stack << match[1]
            next
          end
          if class_stack.any? && (match = line.match(/\A\s*const\s+:([A-Za-z_]\w*)\b/))
            readers[class_stack.last].add(match[1].to_sym)
            next
          end
          class_stack.pop if class_stack.any? && line.match?(/\A\s*end\s*(?:#.*)?\z/)
        end
        readers
      end

      def ruby_immutable_struct_reader_types(lines)
        reader_types = Hash.new { |h, k| h[k] = {} }
        class_stack = []
        lines.each do |line|
          if (match = line.match(/\A\s*class\s+([A-Za-z_]\w*(?:::[A-Za-z_]\w*)*)\s*<\s*T::Struct\b/))
            class_stack << match[1]
            next
          end
          if class_stack.any? && (match = line.match(/\A\s*const\s+:([A-Za-z_]\w*)\s*,\s*([A-Za-z_]\w*(?:::[A-Za-z_]\w*)*)\b/))
            reader_types[class_stack.last][match[1].to_sym] = match[2]
            next
          end
          class_stack.pop if class_stack.any? && line.match?(/\A\s*end\s*(?:#.*)?\z/)
        end
        reader_types
      end

      def ruby_type_aliases(lines)
        aliases = {}
        lines.each do |line|
          if (match = line.match(/\A\s*([A-Z]\w*)\s*=\s*T\.type_alias\s*\{\s*([A-Z]\w*(?:::[A-Z]\w*)*)\s*\}/))
            aliases[match[1]] = match[2]
          elsif (match = line.match(/\A\s*([A-Z]\w*)\s*=\s*([A-Z]\w*(?:::[A-Z]\w*)*)\b/))
            aliases[match[1]] = match[2]
          end
        end
        aliases
      end

      def ruby_visibility_calls(calls)
        calls.select do |call|
          call.function == "(top-level)" &&
            call.receiver == "self" &&
            %w[public protected private].include?(call.message.to_s)
        end
      end

      def ruby_visibility_arg_name(arg)
        arg.to_s.strip
           .delete_prefix(":")
           .delete_prefix("\"")
           .delete_suffix("\"")
           .delete_prefix("'")
           .delete_suffix("'")
      end
    end

  end
end

module FactMine
  module Syntax
    class RubyNormalizedExtractionBehavior < NormalizedExtractionBehavior
      def self_member_receiver(message)
        "self.#{message}"
      end

      def emit_index_call_site?(_node, _call)
        true
      end

      def emit_index_assignment_mutation?(_node, _field)
        true
      end

      def emit_attribute_assignment_mutation?(_node, field)
        field.to_s != "[]"
      end

      def preserve_constant_receiver_call?(call)
        receiver = call.fetch("receiver").to_s
        message = call.fetch("message").to_s
        base = receiver.sub(/\A::/, "").split("::").first
        return true if base == "Dir" && RUBY_EFFECT_LEXICON.dir_context.include?(message)
        return true if RUBY_EFFECT_LEXICON.context_pairs[base]&.include?(message)
        return true if RUBY_EFFECT_LEXICON.io_pairs.to_h[base]&.include?(message)

        false
      end

      def function_visibility(name, _node, lines:)
        return "private" if name.start_with?("#")

        "public"
      end

      def structural_semantic_effects(_node, function_name:)
        return [] unless %w[method_missing respond_to_missing?].include?(function_name)

        [{ kind: "metaprogramming", detail: "def #{function_name}" }]
      end

      def visibility_events_from_calls(calls)
        calls.filter_map do |call|
          visibility = call.fetch("message").to_s
          next unless call.fetch("receiver").to_s == "self"
          next unless %w[public protected private].include?(visibility)

          {
            owner: call.fetch("owner"),
            visibility: visibility,
            line: call.fetch("line"),
            target_names: call.fetch("arguments").to_a.map { |arg| visibility_argument_name(arg) }.reject(&:empty?)
          }
        end
      end

      def nil_guard_fact(message, subject)
        return nil unless message.to_s == "nil?" && subject

        { local: subject, non_nil_when_true: false }
      end

      def terminating_call_message?(message)
        %w[raise fail abort exit exit!].include?(message.to_s)
      end

      def mutating_receiver_message?(message)
        %w[
          << []= add append clear collect! compact! concat delete delete_if fill filter!
          keep_if merge! move push reject! replace shift store unshift update write
        ].include?(message) || (message.to_s.end_with?("!") && !%w[!= !~].include?(message))
      end

      def branch_state_ref(_node, parts, default_ref:)
        default_ref
      end

      def protocol_read_label_from_state(read)
        receiver = read.receiver.to_s
        field = read.field.to_s.delete_prefix("@").delete_prefix("$").delete_suffix("?")
        return field if receiver.empty? || receiver == "self"

        "#{receiver}.#{field}"
      end

      def protocol_read_label_from_call(call)
        return nil unless call.receiver.to_s == "self"

        call.message.to_s
      end

      def protocol_write_label(write)
        field = write.field.to_s.delete_prefix("@").delete_prefix("$")
        receiver = write.receiver.to_s
        return field if receiver.empty? || receiver == "self"

        "#{receiver}.#{field}"
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
        normalize_source_text(text.to_s.strip.gsub(/\s+/, " "))
      end

      def property_read_call?(_node, _parts)
        false
      end

      def state_read_span_key(call)
        call.fetch("receiver").to_s.include?("(") ? "span" : "access_span"
      end

      def boolean_enclosing_span(_node, node_span:, decision_span:)
        node_span
      end

      def suppress_self_call_state_read?(call)
        call.fetch("receiver") == "self"
      end

      def wrap_branch_predicate?(_branch)
        false
      end

      def suppress_clone_candidate?(node, ancestors:)
        return false if %w[DEFN DEFS].include?(normalized_node_type(node))
        return false if ancestors.any? { |ancestor| %w[DEFN DEFS].include?(normalized_node_type(ancestor)) }

        ancestors.any? do |ancestor|
          normalized_node_type(ancestor) == "CLASS" &&
            normalized_node_text(ancestor).match?(/<\s*T::Struct\b/)
        end
      end

      private

      def normalized_node_type(node)
        return node["type"].to_s if node.is_a?(Hash)
        return node.type.to_s if node.respond_to?(:type)

        ""
      end

      def normalized_node_text(node)
        return node["text"].to_s if node.is_a?(Hash)
        return node.text.to_s if node.respond_to?(:text)

        ""
      end

      def visibility_argument_name(argument)
        argument.to_s.strip
                .delete_prefix(":")
                .delete_prefix("\"")
                .delete_suffix("\"")
                .delete_prefix("'")
                .delete_suffix("'")
                .split(/\s+/)
                .first.to_s
      end
    end

    class RubySorbetTypeProfile < TypeProfile
      MAX_UNION_TYPES = 3
      CORE_RUNTIME_GUARD_CLASSES = %w[
        Array Hash Set String Symbol Integer Float NilClass TrueClass FalseClass Numeric Range Regexp Time
      ].freeze
      NUMERIC_GUARD_SUBCLASSES = %w[Integer Float].freeze
      BOOLEAN_GUARD_SUBCLASSES = %w[TrueClass FalseClass].freeze

      def useful_type?(type)
        super && normalize_type(type) != "T.untyped"
      end

      def static_type(types, union_policy: ENV.fetch("NIL_KILL_UNION_POLICY", "untyped"))
        values = Array(types).compact.map(&:to_s).reject(&:empty?)
        return "T.untyped" if values.empty?

        has_nil = false
        others = []
        values.each do |type|
          if type == "NilClass"
            has_nil = true
          elsif type.start_with?("T.nilable(") && type.end_with?(")")
            has_nil = true
            others << type[10..-2]
          else
            others << normalize_static_type(type)
          end
        end

        others = others.uniq.sort
        if others.include?("T.noreturn")
          return has_nil ? "NilClass" : "T.noreturn" if others == ["T.noreturn"]

          others.delete("T.noreturn")
        end
        return "NilClass" if others.empty? && has_nil
        return "T.untyped" if others.empty?

        base =
          if others.all? { |type| %w[TrueClass FalseClass T::Boolean].include?(type) }
            "T::Boolean"
          elsif others.size == 1
            others.first
          elsif union_policy == "any" && others.size <= MAX_UNION_TYPES
            "T.any(#{others.join(", ")})"
          else
            "T.untyped"
          end
        return "T.untyped" if base == "T.untyped"

        has_nil ? "T.nilable(#{base})" : base
      end

      def normalize_static_type(type)
        case type.to_s
        when "Array" then "T::Array[T.untyped]"
        when "Hash" then "T::Hash[T.untyped, T.untyped]"
        when "Set" then "T::Set[T.untyped]"
        else type.to_s
        end
      end

      def extract_param_entries(signature)
        params = extract_call_args(signature, "params")
        return [] unless params

        split_top_level(params).filter_map do |entry|
          name, type = entry.split(/:\s*/, 2)
          next unless name && type

          [name.strip, type.strip]
        end
      end

      def extract_return_type(signature)
        extract_call_args(signature, "returns")
      end

      def strip_nilable_type(type)
        text = type.to_s.strip
        return text unless text.start_with?("T.nilable(")

        extract_call_args(text, "T.nilable") || text
      end

      def nullable_or_untyped?(type)
        raw = type.to_s.strip
        raw.empty? || raw == "T.untyped" || raw == "NilClass" || raw.include?("T.nilable")
      end

      def nil_check_receiver(text)
        text.to_s.strip[/\A([a-z_]\w*)\.nil\?\z/, 1]
      end

      def safe_nav_receiver(text)
        text.to_s.strip[/\A([a-z_]\w*)&\./, 1]
      end

      def always_noreturn_body_text?(text)
        source = text.to_s
        return false if source.match?(/\breturn\b/)

        source.match?(/\braise\b/) ||
          source.match?(/\bfail\b/) ||
          source.match?(/\babort\b/) ||
          source.match?(/\bT\.absurd\s*\(/)
      end

      def return_expression_type(code, param_types)
        source = code.to_s.strip
        return ["NilClass", "nil", nil, false] if source == "nil"
        return ["String", "static", nil, false] if source.match?(/\A["']/)
        return ["Symbol", "static", nil, false] if source.start_with?(":")
        return ["Integer", "static", nil, false] if source.match?(/\A[-+]?\d+\z/)
        return ["T::Boolean", "static", nil, false] if %w[true false].include?(source)
        return [param_types[source], "static", nil, false] if param_types[source]

        if (match = source.match(/\A([a-z_]\w*)\.join\b/))
          receiver_type = param_types[match[1]].to_s
          return ["String", "typed_call", "join", true] if receiver_type.match?(/\A(?:Array|T::Array)\[String\]/)
        end

        return [nil, "call_untyped", source, false] if source.match?(/\A[a-z_]\w*[!?]?\z/)

        [nil, "unknown", nil, false]
      end

      def literal_text_type(text, constant_types = {})
        value = text.to_s.strip
        return "String" if value.match?(/\A["']/)
        return "Symbol" if value.match?(/\A:/)
        return "T::Array[Symbol]" if value.match?(/\A%i[\[\(\{]/)
        return "T::Array[String]" if value.match?(/\A%w[\[\(\{]/)
        return "Integer" if value.match?(/\A[-+]?\d+\z/)
        return "Float" if value.match?(/\A[-+]?\d+\.\d+\z/)
        return "T::Boolean" if %w[true false True False].include?(value)
        return "NilClass" if %w[nil null None].include?(value)
        return constant_types[value] if constant_types.key?(value)

        "T.untyped"
      end

      def class_guard_truth(receiver_type, class_name, exact:)
        raw = receiver_type.to_s
        return nil if raw.empty? || raw == "T.untyped" || raw.include?("T.any(") || raw.start_with?("T.nilable(")

        bare = bare_class_name(raw)
        wanted = bare_class_name(class_name)
        return false if exact && known_disjoint_guard_classes?(bare, wanted)
        return nil if exact
        return true if bare == wanted || known_guard_subclass?(bare, wanted)
        return false if known_disjoint_guard_classes?(bare, wanted)

        nil
      end

      private

      def bare_class_name(type)
        raw = type.to_s.delete_prefix("::")
        case raw
        when /\AT::Array\b/, /\AArray\b/ then "Array"
        when /\AT::Hash\b/, /\AHash\b/ then "Hash"
        when /\AT::Set\b/, /\ASet\b/ then "Set"
        when "T::Boolean" then "T::Boolean"
        else raw.split("::").last
        end
      end

      def known_guard_subclass?(bare, wanted)
        return true if wanted == "Numeric" && NUMERIC_GUARD_SUBCLASSES.include?(bare)
        return true if wanted == "T::Boolean" && BOOLEAN_GUARD_SUBCLASSES.include?(bare)

        false
      end

      def known_disjoint_guard_classes?(bare, wanted)
        return false if bare == wanted
        return false if known_guard_subclass?(bare, wanted) || known_guard_subclass?(wanted, bare)
        return false if bare == "T::Boolean" && BOOLEAN_GUARD_SUBCLASSES.include?(wanted)
        return false if wanted == "T::Boolean" && BOOLEAN_GUARD_SUBCLASSES.include?(bare)
        return true if bare == "T::Boolean" && CORE_RUNTIME_GUARD_CLASSES.include?(wanted)
        return true if wanted == "T::Boolean" && CORE_RUNTIME_GUARD_CLASSES.include?(bare)

        CORE_RUNTIME_GUARD_CLASSES.include?(bare) && CORE_RUNTIME_GUARD_CLASSES.include?(wanted)
      end
    end

    RUBY_TYPE_PROFILE = RubySorbetTypeProfile.new(
      language: :ruby,
      type_system: "sorbet",
      broad_types: %w[T.untyped T.anything Object BasicObject],
      intrinsic_types: %w[
        Array BasicObject Class Complex Encoding Enumerator Exception FalseClass Fiber Float Hash Integer Module NilClass
        Numeric Object Proc Range Rational Regexp String Struct Symbol Thread Time TrueClass
      ],
      nil_types: %w[NilClass],
      boolean_types: %w[TrueClass FalseClass T::Boolean],
      collection_types: %w[Array Hash Set T::Array T::Hash T::Set],
      generic_wrappers: %w[T.nilable T.any],
      alias_wrappers: [{ name: "T.nilable", open: "(", close: ")" }],
      union_wrappers: [{ name: "T.any", open: "(", close: ")" }]
    ).freeze
    Syntax.register_type_profile(:ruby, RUBY_TYPE_PROFILE)

    NormalizedExtractionBehavior.register(:ruby, RubyNormalizedExtractionBehavior)
  end
end
