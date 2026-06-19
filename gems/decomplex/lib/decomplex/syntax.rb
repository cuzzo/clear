# frozen_string_literal: true

require "set"
require "rbconfig"

module Decomplex
  module Syntax
    FunctionDef = Struct.new(:file, :name, :owner, :line, :span, :body, :visibility,
                             :params, :signature, :kind, keyword_init: true)
    OwnerDef = Struct.new(:file, :name, :kind, :line, :span, keyword_init: true)
    CallSite = Struct.new(:receiver, :message, :file, :function, :owner, :line, :span,
                          :conditional, :arguments, :control, :safe_navigation, :block,
                          keyword_init: true)
    StateDeclaration = Struct.new(:field, :owner, :type, :file, :line, :span, keyword_init: true)
    StateParamOrigin = Struct.new(:field, :receiver, :owner, :param, :file, :function,
                                  :line, :span, keyword_init: true)
    DecisionSite = Struct.new(:kind, :members, :file, :function, :line, :span, :predicate,
                              :enclosing_span, keyword_init: true)
    StateRead = Struct.new(:field, :receiver, :file, :function, :line, :span, :owner, keyword_init: true)
    StateWrite = Struct.new(:field, :receiver, :file, :function, :line, :span, :owner, keyword_init: true)
    BranchDecision = Struct.new(:file, :function, :line, :span, :predicate, :state_refs, keyword_init: true)
    BranchArm = Struct.new(:file, :function, :kind, :line, :span,
                           :decision_line, :decision_span, :predicate,
                           :member, :body, keyword_init: true)
    PredicateDef = Struct.new(:file, :name, :owner, :body, :line, :span, keyword_init: true)
    ComparisonSite = Struct.new(:file, :function, :line, :span, :source, :operator, keyword_init: true)
    LocalMethod = Struct.new(:id, :owner, :name, :file, :line, :span, :node,
                             :statements, :boundaries, keyword_init: true)
    LocalStatement = Struct.new(:index, :line, :end_line, :span, :source, :reads,
                                :writes, :dependencies, :co_uses, keyword_init: true)
    LocalBoundary = Struct.new(:before_index, :after_index, :line, :kind, :text, keyword_init: true)
    PathConditionSite = Struct.new(:guards, :action, :file, :function, :line, :span, keyword_init: true)
    LanguageLexicon = Struct.new(
      :type_guard_patterns, :diagnostic_patterns, :trivial_patterns,
      :nil_literal_patterns,
      keyword_init: true
    ) do
      def type_guard?(text, allow_literal_nil: true)
        source = text.to_s
        return true if allow_literal_nil && matches?(nil_literal_patterns, source)

        matches?(type_guard_patterns, source)
      end

      def diagnostic?(text, extra_names: [])
        source = text.to_s
        matches?(diagnostic_patterns, source) ||
          call_name?(source, Array(extra_names).map(&:to_s))
      end

      def trivial?(text)
        source = text.to_s.strip
        source.empty? || matches?(trivial_patterns, source)
      end

      private

      def matches?(patterns, source)
        Array(patterns).any? { |pattern| source.match?(pattern) }
      end

      def call_name?(source, names)
        names.reject(&:empty?).any? do |name|
          source.match?(/(?:\A|[^\w!?])#{Regexp.escape(name)}[!?]?(?:\s*\(|\b)/)
        end
      end
    end

    RUBY_LEXICON = LanguageLexicon.new(
      nil_literal_patterns: [/\bnil\b/].freeze,
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
    PYTHON_LEXICON = LanguageLexicon.new(
      nil_literal_patterns: [/\bNone\b/].freeze,
      type_guard_patterns: [
        /\b(?:isinstance|issubclass|hasattr)\s*\(/,
        /\bis\s+(?:not\s+)?None\b/,
        /\btype\s*\([^)]*\)\s*(?:==|is)\s*/
      ].freeze,
      diagnostic_patterns: [
        /\braise\b/,
        /\bassert\b/,
        /\bsys\.exit\s*\(/
      ].freeze,
      trivial_patterns: [
        /\A(?:None|True|False|0|1|break|continue|pass)\s*;?\z/,
        /\Areturn\s+(?:None|True|False|0|1)\s*;?\z/
      ].freeze
    ).freeze
    JAVASCRIPT_LEXICON = LanguageLexicon.new(
      nil_literal_patterns: [/\b(?:null|undefined)\b/].freeze,
      type_guard_patterns: [
        /\btypeof\b/,
        /\binstanceof\b/,
        /(?:\?\.|\b(?:==|!=|===|!==)\s*(?:null|undefined)\b)/
      ].freeze,
      diagnostic_patterns: [
        /\bthrow\b/,
        /\bprocess\.exit\s*\(/
      ].freeze,
      trivial_patterns: [
        /\A(?:null|undefined|true|false|0|1|break|continue)\s*;?\z/,
        /\Areturn\s+(?:null|undefined|true|false|0|1)\s*;?\z/
      ].freeze
    ).freeze
    GO_LEXICON = LanguageLexicon.new(
      nil_literal_patterns: [/\bnil\b/].freeze,
      type_guard_patterns: [
        /\bnil\b/,
        /\.\(type\)/,
        /\.\([A-Za-z_]\w*(?:\.[A-Za-z_]\w*)*\)/
      ].freeze,
      diagnostic_patterns: [
        /\bpanic\s*\(/,
        /\breturn\s+error[.\w]*/
      ].freeze,
      trivial_patterns: [
        /\A(?:nil|true|false|0|1|break|continue|fallthrough)\s*;?\z/,
        /\Areturn\s+(?:nil|true|false|0|1)\s*;?\z/
      ].freeze
    ).freeze
    RUST_LEXICON = LanguageLexicon.new(
      nil_literal_patterns: [/\bNone\b/].freeze,
      type_guard_patterns: [
        /\b(?:is_some|is_none)\s*\(/,
        /\b(?:Some|None)\b/,
        /\bmatches!\s*\(/
      ].freeze,
      diagnostic_patterns: [
        /\b(?:panic|unreachable|todo|unimplemented)!\s*\(/,
        /\breturn\s+Err\s*\(/
      ].freeze,
      trivial_patterns: [
        /\A(?:None|true|false|0|1|break|continue|unreachable!)\s*;?\z/,
        /\Areturn\s+(?:None|true|false|0|1)\s*;?\z/
      ].freeze
    ).freeze
	    ZIG_LEXICON = LanguageLexicon.new(
	      nil_literal_patterns: [/\bnull\b/].freeze,
	      type_guard_patterns: [
        /\bnull\b/,
        /@typeInfo\b/,
        /\bif\s*\([^)]*\)\s*\|/
      ].freeze,
      diagnostic_patterns: [
        /@panic\s*\(/,
        /\bunreachable\b/,
        /\breturn\s+error[.\w]*/
      ].freeze,
      trivial_patterns: [
        /\A(?:null|true|false|0|1|break|continue|unreachable)\s*;?\z/,
	        /\Areturn\s+(?:null|true|false|0|1)\s*;?\z/
	      ].freeze
	    ).freeze
	    LUA_LEXICON = LanguageLexicon.new(
	      nil_literal_patterns: [/\bnil\b/].freeze,
	      type_guard_patterns: [
	        /\btype\s*\(/,
	        /\bnil\b/,
	        /\b(?:pcall|xpcall)\s*\(/
	      ].freeze,
	      diagnostic_patterns: [
	        /\berror\s*\(/,
	        /\bassert\s*\(/
	      ].freeze,
	      trivial_patterns: [
	        /\A(?:nil|true|false|0|1|break)\s*;?\z/,
	        /\Areturn\s+(?:nil|true|false|0|1)\s*;?\z/
	      ].freeze
	    ).freeze
	    C_LEXICON = LanguageLexicon.new(
	      nil_literal_patterns: [/\bNULL\b/].freeze,
	      type_guard_patterns: [
	        /\bNULL\b/,
	        /\bsizeof\s*\(/,
	        /\b_Generic\s*\(/
	      ].freeze,
	      diagnostic_patterns: [
	        /\b(?:assert|abort|exit)\s*\(/,
	        /\breturn\s+errno\b/
	      ].freeze,
	      trivial_patterns: [
	        /\A(?:NULL|true|false|0|1|break|continue)\s*;?\z/,
	        /\Areturn\s+(?:NULL|true|false|0|1)\s*;?\z/
	      ].freeze
	    ).freeze
	    CPP_LEXICON = LanguageLexicon.new(
	      nil_literal_patterns: [/\b(?:nullptr|NULL)\b/].freeze,
	      type_guard_patterns: [
	        /\b(?:nullptr|NULL)\b/,
	        /\b(?:dynamic_cast|typeid)\s*[<(]/,
	        /\bstd::(?:get_if|holds_alternative)\s*[<(]/
	      ].freeze,
	      diagnostic_patterns: [
	        /\bthrow\b/,
	        /\b(?:assert|abort|exit)\s*\(/,
	        /\bstd::terminate\s*\(/
	      ].freeze,
	      trivial_patterns: [
	        /\A(?:nullptr|NULL|true|false|0|1|break|continue)\s*;?\z/,
	        /\Areturn\s+(?:nullptr|NULL|true|false|0|1)\s*;?\z/
	      ].freeze
	    ).freeze
	    CSHARP_LEXICON = LanguageLexicon.new(
	      nil_literal_patterns: [/\bnull\b/].freeze,
	      type_guard_patterns: [
	        /\bnull\b/,
	        /(?:\?\.|\?\?)/,
	        /\b(?:is|as|typeof)\b/
	      ].freeze,
	      diagnostic_patterns: [
	        /\bthrow\b/,
	        /\b(?:Debug\.Assert|Trace\.Assert|Environment\.Exit)\s*\(/
	      ].freeze,
	      trivial_patterns: [
	        /\A(?:null|true|false|0|1|break|continue)\s*;?\z/,
	        /\Areturn\s+(?:null|true|false|0|1)\s*;?\z/
	      ].freeze
	    ).freeze
	    JAVA_LEXICON = LanguageLexicon.new(
	      nil_literal_patterns: [/\bnull\b/].freeze,
	      type_guard_patterns: [
	        /\bnull\b/,
	        /\binstanceof\b/,
	        /\bObjects\.(?:isNull|nonNull|requireNonNull)\s*\(/
	      ].freeze,
	      diagnostic_patterns: [
	        /\bthrow\b/,
	        /\bassert\b/,
	        /\bSystem\.exit\s*\(/
	      ].freeze,
	      trivial_patterns: [
	        /\A(?:null|true|false|0|1|break|continue)\s*;?\z/,
	        /\Areturn\s+(?:null|true|false|0|1)\s*;?\z/
	      ].freeze
	    ).freeze
	    SWIFT_LEXICON = LanguageLexicon.new(
	      nil_literal_patterns: [/\bnil\b/].freeze,
	      type_guard_patterns: [
	        /\bnil\b/,
	        /(?:\?\.|\?\?)/,
	        /\b(?:if|guard)\s+let\b/,
	        /\b(?:as\?|is)(?:\s|$)/
	      ].freeze,
	      diagnostic_patterns: [
	        /\bthrow\b/,
	        /\b(?:fatalError|preconditionFailure|assertionFailure|assert|precondition)\s*\(/
	      ].freeze,
	      trivial_patterns: [
	        /\A(?:nil|true|false|0|1|break|continue)\s*;?\z/,
	        /\Areturn\s+(?:nil|true|false|0|1)\s*;?\z/
	      ].freeze
	    ).freeze
	    KOTLIN_LEXICON = LanguageLexicon.new(
	      nil_literal_patterns: [/\bnull\b/].freeze,
	      type_guard_patterns: [
	        /\bnull\b/,
	        /(?:\?\.|\?\?)/,
	        /\b(?:is|as\?)(?:\s|$)/
	      ].freeze,
	      diagnostic_patterns: [
	        /\bthrow\b/,
	        /\b(?:error|require|check|assert|TODO)\s*\(/
	      ].freeze,
	      trivial_patterns: [
	        /\A(?:null|true|false|0|1|break|continue)\s*;?\z/,
	        /\Areturn\s+(?:null|true|false|0|1)\s*;?\z/
	      ].freeze
	    ).freeze
    class TreeSitterLanguageAdapter
      attr_reader :language, :extensions, :lexicon, :package, :grammar_names,
                  :tree_sitter_language_name

      def initialize(language:, extensions:, lexicon:, package:, grammar_names: nil,
                     tree_sitter_language_name: nil, first_argument_receiver: false)
        @language = language.to_sym
        @extensions = Array(extensions).freeze
        @lexicon = lexicon
        @package = package
        @grammar_names = Array(grammar_names || language.to_s).freeze
        @tree_sitter_language_name = tree_sitter_language_name || language.to_s
        @first_argument_receiver = first_argument_receiver
      end

      def first_argument_receiver?
        @first_argument_receiver
      end

      def function_name(node)
        case node.kind
	        when "method", "function_definition", "function_declaration",
	             "method_definition", "function_item"
	          named_field(node, "name")&.text ||
	            declarator_name(named_field(node, "declarator")) ||
	            first_named_text(node, %w[identifier constant property_identifier])
        when "method_declaration"
          named_field(node, "name")&.text ||
            first_named_text(node, %w[field_identifier identifier])
        end
      end

      def function_kind(_document, node, stack)
        owner_for_node(nil, node, stack: stack) ? :method : :function
      end

      def visibility(_document, node)
        modifier_visibility(node)
      end

      def owner_name_from_declaration(document, node)
        case node.kind
	        when "class", "class_definition", "class_declaration", "class_specifier", "module"
	          named_field(node, "name")&.text ||
              first_named_text(node, %w[constant identifier type_identifier])
        when "impl_item", "impl_block"
          impl_owner_name(node)
        when "struct_item", "struct_spec", "struct_specifier", "type_spec", "type_declaration"
          named_field(node, "name")&.text ||
            first_named_text(node, %w[type_identifier identifier])
        when "struct_declaration", "union_declaration", "enum_declaration"
          bound_container_name(node) ||
            returned_container_owner(document, node) ||
            anonymous_owner_name(document, node)
        end
      end

      def owner_kind(node)
        case node.kind
	        when "class", "class_definition", "class_declaration", "class_specifier" then :class
        when "module" then :module
        when "impl_item", "impl_block" then :impl
        when "struct_declaration", "struct_item", "struct_spec", "struct_specifier" then :struct
        when "union_declaration" then :union
        when "enum_declaration" then :enum
        else :owner
        end
      end

      def function_receiver_name(node, stack)
        receiver_param = method_receiver_param_node(node)
        receiver_param&.text ||
          receiver_convention_param_name(node, stack: stack)
      end

      def receiver_convention_owner_name(node, **_context)
        return nil unless first_argument_receiver?
        return nil unless node.kind == "function_definition"

        receiver = first_argument_receiver_parameter(node)
        return nil unless receiver

        type = normalize_type_owner(receiver[:type])
        name = function_name(node).to_s
        return nil if type.empty? || name.empty?

        prefix = snake_case_type_name(type)
        name.start_with?("#{prefix}_") ? type : nil
      end

      def receiver_convention_param_name(node, **_context)
        return nil unless first_argument_receiver?

        first_argument_receiver_parameter(node)&.fetch(:name, nil)
      end

      def generated_prelude?(_document, _node)
        false
      end

      def call_target(document, node)
        case node.kind
	      when "call_expression", "method_invocation", "invocation_expression", "function_call", "method_call"
          generic_call_target(document, node)
	      when "attribute", "selector_expression", "field", "field_access", "member_expression",
	           "member_access_expression", "field_expression", "expression_list",
             "dot_index_expression", "variable_list", "identifier", "simple_identifier"
          adjacent_argument_call_target(node)
        end
      end

      def state_declaration(node)
        generic_state_declaration(node)
      end

      def state_read_target(node)
        generic_state_read_target(node)
      end

      def state_target(lhs)
        generic_state_target(lhs)
      end
    end

    class RubySyntaxAdapter < TreeSitterLanguageAdapter; end

    class PythonSyntaxAdapter < TreeSitterLanguageAdapter
      def visibility(_document, node)
        name = function_name(node).to_s
        return :private if name.start_with?("_") && !name.start_with?("__")

        :public
      end

      def call_target(document, node)
        python_adjacent_call_target(node) || super
      end

      def local_methods(document)
        super
      end

      private

      def python_function_body_statements(node)
        body = named_field(node, "body") ||
               node.named_children.find { |child| child.kind == "block" }
        return [] unless body

        body.named_children.reject { |child| child.kind == "comment" }
      end

      def python_adjacent_call_target(node)
        return nil unless %w[identifier].include?(node.kind)

        args = next_sibling(node)
        return nil unless args&.kind == "argument_list"

        {
          receiver: "self",
          message: node.text,
          arguments: args.named_children.map { |child| normalize_text(child.text) }
        }
      rescue StandardError
        nil
      end
    end

    class GoSyntaxAdapter < TreeSitterLanguageAdapter
      def visibility(_document, node)
        exported_name_visibility(function_name(node))
      end
    end

    class RustSyntaxAdapter < TreeSitterLanguageAdapter
      def visibility(_document, node)
        modifier_visibility(node) || :private
      end
    end

    class JavaScriptSyntaxAdapter < TreeSitterLanguageAdapter
      def visibility(_document, node)
        modifier_visibility(node) || private_name_visibility(node)
      end

      private

      def private_name_visibility(node)
        function_name(node).to_s.start_with?("#") ? :private : :public
      end
    end

    class CppSyntaxAdapter < TreeSitterLanguageAdapter
      def visibility(_document, node)
        modifier_visibility(node) || cpp_visibility(node)
      end
    end

    class CSharpSyntaxAdapter < TreeSitterLanguageAdapter
      def visibility(_document, node)
        modifier_visibility(node) || :private
      end
    end

    class CSyntaxAdapter < TreeSitterLanguageAdapter
      def visibility(_document, node)
        c_visibility(node)
      end
    end

    class LuaSyntaxAdapter < TreeSitterLanguageAdapter
      def generated_prelude?(document, node)
        return false unless line(node) == 1

        first_line = document.lines.first.to_s
        first_line.include?("_tl_compat") && first_line.include?("compat53.module")
      end
    end

    class ZigSyntaxAdapter < TreeSitterLanguageAdapter
      def visibility(_document, node)
        modifier_visibility(node) || :private
      end

      def state_declaration(node)
        return zig_container_field_declaration(node) if node.kind == "container_field"

        super
      end

      private

      def zig_container_field_declaration(node)
        name = node.named_children.find { |child| child.kind == "identifier" }
        return nil unless name

        { field: name.text, type: declared_type_text(node, name) }
      end
    end

    class CppSyntaxAdapter
      def implicit_state_accesses?
        true
      end

      private

      def cpp_visibility(node)
        visibility = previous_cpp_access_specifier(node)
        return visibility if visibility

        owner = nearest_owner_declaration(node)
        return :public if owner&.kind == "struct_specifier"

        :private
      end

      def previous_cpp_access_specifier(node)
        sibling = prev_sibling(node)
        while sibling
          return sibling.text.to_sym if sibling.kind == "access_specifier" &&
                                       %w[public private protected].include?(sibling.text)

          sibling = prev_sibling(sibling)
        end
        nil
      end

      def nearest_owner_declaration(node)
        parent = parent_node(node)
        seen = Set.new
        while parent && !seen.include?(node_key(parent))
          seen << node_key(parent)
          return parent if %w[class_specifier struct_specifier class class_definition class_declaration].include?(parent.kind)

          parent = parent_node(parent)
        end
        nil
      end
    end

    class CSharpSyntaxAdapter
      def implicit_state_accesses?
        true
      end
    end

    class CSyntaxAdapter
      private

      def c_visibility(node)
        node.children.any? { |child| child.text == "static" } ? :private : :public
      end
    end

    class TreeSitterLanguageAdapter
      BRANCH_KINDS = %w[if unless if_statement if_modifier unless_modifier if_expression
                        while until while_statement for for_statement
                        case switch_statement expression_switch_statement switch_expression
                        match_statement match_expression when_expression].freeze
      COMPARISON_OPERATORS = %w[== !=].freeze
      NOISE_MESSAGES = %w[! != == === < <= > >= [] []= to_s inspect class].freeze

      def initial_stack(document)
        [{ file_owner: file_owner(document.file), language: document.language }]
      end

      def push_context(document, stack, node)
        next_stack = push_owner_context(document, stack, node)
        name = function_name(node)
        next_stack = name ? next_stack + [function_context(node, next_stack)] : next_stack
        control = control_context(node)
        control ? next_stack + [{ control: control }] : next_stack
      end

      def structural_facts_for_node(document, node, stack)
        out = {
          function_defs: [],
          owner_defs: [],
          call_sites: [],
          state_declarations: [],
          state_param_origins: [],
          state_reads: [],
          state_writes: []
        }
        record_function_def(document, node, stack, out[:function_defs])
        record_owner_def(document, node, stack, out[:owner_defs])
        record_call_site(document, node, stack, out[:call_sites])
        record_state_declaration(document, node, stack, out[:state_declarations])
        record_state_param_origin(document, node, stack, out[:state_param_origins])
        record_state_read(document, node, stack, out[:state_reads])
        record_state_write(document, node, stack, out[:state_writes])
        out
      end

      def after_structural_facts(document, out)
        record_implicit_state_accesses(document, out) if implicit_state_accesses?
      end

      def decision_site_facts(document, node, stack)
        out = []
        record_decision_site(document, node, stack, out)
        out
      end

      def branch_decision_facts(document, node, stack, immutable_readers:, immutable_reader_types:, type_aliases:)
        out = []
        record_branch_decision(
          document,
          node,
          stack,
          out,
          immutable_readers: immutable_readers,
          immutable_reader_types: immutable_reader_types,
          type_aliases: type_aliases,
          method_param_types: method_param_types(document)
        )
        out
      end

      def branch_arm_facts(document, node, stack)
        out = []
        record_branch_arm(document, node, stack, out)
        out
      end

      def comparison_site_facts(document, node, stack)
        target = comparison_target(node)
        return [] unless target

        [
          ComparisonSite.new(
            file: document.file,
            function: current_function(stack),
            line: line(node),
            span: span(node),
            source: target[:source],
            operator: target[:operator]
          )
        ]
      end

      def implicit_state_accesses?
        false
      end

      def function_params(node)
        params = if node.kind == "method_declaration"
                   lists = node.named_children.select { |child| child.kind == "parameter_list" }
                   lists.size > 1 ? lists[1] : lists.first
                 else
                   named_field(node, "parameters") ||
                     node.named_children.find do |child|
                       %w[parameters formal_parameters function_value_parameters parameter_list].include?(child.kind)
                     end
                 end
        params ||= node.named_children.select { |child| child.kind == "parameter" } if node.kind == "function_declaration"
        return [] unless params

        Array(params.respond_to?(:named_children) ? params.named_children : params).filter_map do |param|
          parameter_name(param)
        end.uniq
      end

      def function_signature(document, node)
        body = named_field(node, "body")
        text =
          if body
            document.source.byteslice(node.start_byte, body.start_byte - node.start_byte).to_s.strip
          else
            line_text(document, node).strip
          end
        normalize_text(text.empty? ? line_text(document, node) : text)
      rescue StandardError
        normalize_text(line_text(document, node))
      end

      def method_param_types(_document)
        {}
      end

      def predicate_def(_document, function_def)
        body = generic_predicate_body(function_def.body)
        return nil unless body

        PredicateDef.new(
          file: function_def.file,
          name: function_def.name,
          owner: function_def.owner,
          body: body,
          line: function_def.line,
          span: function_def.span
        )
      end

      def local_methods(document)
        document.function_defs.map do |function_def|
          statements = generic_function_body_statements(function_def.body)
          local_names = generic_local_names(function_def, statements)
          local_statements = statements.each_with_index.map do |statement, index|
            generic_local_statement(statement, index, local_names)
          end
          owner = function_def.owner.to_s == file_owner(document.file) ? "(top-level)" : function_def.owner

          LocalMethod.new(
            id: "#{owner}##{function_def.name}",
            owner: owner,
            name: function_def.name,
            file: function_def.file,
            line: function_def.line,
            span: function_def.span,
            node: function_def.body,
            statements: local_statements,
            boundaries: generic_structural_boundaries(document, local_statements)
          )
        end
      end

      def path_condition_sites(document)
        out = []
        document.function_defs.each do |function_def|
          generic_function_body_statements(function_def.body).each do |statement|
            generic_path_walk(document, statement, function_def.name, [], out)
          end
        end
        out
      end

      private

      def generic_predicate_body(node)
        body = generic_function_body_node(node)
        return nil unless body

        statement = generic_function_body_statements(node).last || body
        source = normalize_text(statement.text)
        source = source.sub(/\Areturn\s+/, "").sub(/;\z/, "").strip
        return nil if source.empty? || source.length > 200
        return nil unless source.match?(/\A(?:true|false)\z|\b(?:true|false|null|nil)\b|(?:==|!=|&&|\|\||\band\b|\bor\b)/i)

        source
      end

      def generic_function_body_node(node)
        return nil unless ts_node?(node)

        named_field(node, "body") ||
          node.named_children.reverse.find do |child|
            %w[block body body_statement function_body statement_block compound_statement declaration_list].include?(child.kind)
          end
      end

      def generic_function_body_statements(node)
        body = generic_function_body_node(node)
        return [] unless body

        named = body.named_children.reject { |child| comment_node?(child) }
        if named.size == 1 && %w[statements statement_list].include?(named.first.kind)
          return [named.first] if branch_node?(named.first)

          named = named.first.named_children.reject { |child| comment_node?(child) }
        end
        return [] if named.empty? && body.text.to_s.strip.empty?
        return [body] if branch_node?(body)
        return [body] if generic_assignment_statement?(body)
        return [body] if named.empty?

        named
      end

      def generic_local_names(function_def, statements)
        names = Set.new(function_def.params.to_a.map(&:to_s))
        statements.each do |statement|
          names.merge(generic_local_writes(statement))
        end
        names
      end

      def generic_local_statement(node, index, local_names)
        reads = generic_local_reads(node, local_names).uniq
        writes = generic_local_writes(node).uniq
        LocalStatement.new(
          index: index,
          line: line(node),
          end_line: span(node)[2],
          span: span(node),
          source: normalize_text(node.text),
          reads: reads.to_set,
          writes: writes.to_set,
          dependencies: generic_assignment_dependencies(node, local_names),
          co_uses: reads.combination(2).map { |left, right| [left, right] }
        )
      end

      def generic_local_reads(node, local_names)
        reads = []
        generic_walk_local(node) do |child|
          name = generic_local_identifier_text(child)
          next unless name
          next unless local_names.include?(name)
          next if generic_local_write_node?(child)
          next if generic_declaration_name?(child)
          next if generic_member_name?(child)
          next if generic_call_name?(child)

          reads << name
        end
        reads
      end

      def generic_local_writes(node)
        writes = []
        if (name = generic_local_declaration_name(node))
          writes << name
        end
        writes.concat(generic_assignment_lhs_names(node))

        generic_walk_local(node) do |child|
          next unless generic_identifier?(child)
          next unless generic_local_write_node?(child)

          writes << child.text.to_s
        end
        writes
      end

      def generic_assignment_dependencies(node, local_names)
        lhs_names = generic_local_writes(node)
        return [] if lhs_names.empty?

        reads = generic_local_reads(node, local_names) - lhs_names
        lhs_names.product(reads).reject { |left, right| left == right }.uniq
      end

      def generic_structural_boundaries(document, statements)
        statements.each_cons(2).filter_map do |left, right|
          boundary = generic_source_boundary(document, left.end_line + 1, right.line - 1)
          next unless boundary

          LocalBoundary.new(
            before_index: left.index,
            after_index: right.index,
            line: boundary[:line],
            kind: boundary[:kind],
            text: boundary[:text]
          )
        end
      end

      def generic_source_boundary(document, first_line, last_line)
        return nil if first_line > last_line

        blank = nil
        (first_line..last_line).each do |line_number|
          text = document.lines[line_number - 1].to_s
          stripped = text.strip
          return { line: line_number, kind: :comment, text: stripped } if stripped.start_with?("#", "//", "--")

          blank ||= { line: line_number, kind: :blank, text: stripped } if stripped.empty?
        end
        blank
      end

      def generic_walk_local(node, &block)
        return unless ts_node?(node)

        stack = [node]
        until stack.empty?
          current = stack.pop
          next unless ts_node?(current)
          next if current != node && generic_nested_local_scope?(current)

          yield current
          current.named_children.reverse_each { |child| stack << child }
        end
      end

      def generic_nested_local_scope?(node)
        function_name(node) || owner_name_from_declaration(nil, node)
      end

      def generic_identifier?(node)
        ts_node?(node) && %w[identifier simple_identifier field_identifier property_identifier].include?(node.kind)
      end

      def generic_local_identifier_text(node)
        return node.text.to_s if generic_identifier?(node)
        return nil unless ts_node?(node)
        return nil unless %w[argument pattern directly_assignable_expression value_argument].include?(node.kind)
        return nil unless node.named_children.empty?

        text = node.text.to_s
        simple_identifier_text?(text) ? text : nil
      end

      def generic_assignment_statement?(node)
        ts_node?(node) &&
          (%w[assignment assignment_expression augmented_assignment assignment_statement operator_assignment].include?(node.kind) ||
           node.children.any? { |child| !child.named? && %w[= += -= *= /= %=].include?(child.text.to_s) })
      end

      def generic_local_write_node?(node)
        return false unless generic_identifier?(node)

        parent = parent_node(node)
        return false unless parent
        return false if generic_member_name?(node)
        return true if generic_declaration_name?(node)

        if %w[assignment assignment_expression augmented_assignment assignment_statement operator_assignment].include?(parent.kind)
          lhs = named_field(parent, "left") || parent.named_children.first
          return lhs == node
        end

        assignment_lhs?(node)
      end

      def generic_declaration_name?(node)
        parent = parent_node(node)
        return false unless parent

        generic_local_declaration_name_node(parent) == node
      end

      def generic_local_declaration_name(node)
        generic_local_declaration_name_node(node)&.text
      end

      def generic_local_declaration_name_node(node)
        return nil unless ts_node?(node)
        return nil unless %w[
          declaration init_declarator let_declaration lexical_declaration local_variable_declaration
          property_declaration short_var_declaration variable_declaration variable_declarator
        ].include?(node.kind)

        if node.kind == "short_var_declaration"
          left = node.named_children.find { |child| child.kind == "expression_list" }
          if left
            identifier = left.named_children.find { |child| generic_identifier?(child) }
            return identifier if identifier
          end
          return left if simple_identifier_text?(left&.text)
        end

        variable = node.named_children.find { |child| child.kind == "variable_declaration" }
        return variable if simple_identifier_text?(variable&.text)

        declaration_assignment = node.named_children.find { |child| child.kind == "assignment_statement" }
        if declaration_assignment
          lhs = declaration_assignment.named_children.first
          identifier = lhs&.named_children&.find { |child| generic_identifier?(child) }
          return identifier if identifier
          return lhs if simple_identifier_text?(lhs&.text)
        end

        named_field(node, "pattern") ||
          named_field(node, "name") ||
          node.named_children.find { |child| child.kind == "pattern" } ||
          node.named_children.find { |child| child.kind == "variable_declaration" }&.named_children&.find { |child| generic_identifier?(child) } ||
          node.named_children.find { |child| child.kind == "expression_list" }&.named_children&.find { |child| generic_identifier?(child) } ||
          node.named_children.find { |child| generic_identifier?(child) }
      end

      def generic_assignment_lhs_names(node)
        return [] unless ts_node?(node)
        return [] unless %w[assignment assignment_expression assignment_statement augmented_assignment operator_assignment].include?(node.kind)

        lhs = named_field(node, "left") || node.named_children.first
        return [] unless ts_node?(lhs)
        return [lhs.text] if generic_identifier?(lhs)
        return [lhs.text] if simple_identifier_text?(lhs.text)

        lhs.named_children.filter_map { |child| child.text if generic_identifier?(child) }
      end

      def simple_identifier_text?(text)
        text.to_s.match?(/\A[A-Za-z_]\w*\z/)
      end

      def generic_member_name?(node)
        parent = parent_node(node)
        if parent&.kind == "navigation_suffix"
          owner = parent_node(parent)
          return true if owner && field_like_node?(owner)
        end
        return false unless parent && field_like_node?(parent)

        field = named_field(parent, "field") || named_field(parent, "property") ||
                named_field(parent, "name") || named_field(parent, "suffix") ||
                parent.named_children.last
        field == node
      end

      def generic_call_name?(node)
        parent = parent_node(node)
        return false unless parent

        %w[call_expression method_invocation invocation_expression].include?(parent.kind) &&
          (named_field(parent, "function") == node || parent.named_children.first == node)
      end

      def generic_path_walk(document, node, function, guards, out)
        return unless ts_node?(node)
        return if generic_nested_local_scope?(node)

        if branch_node?(node)
          condition = generic_branch_condition(node)
          atoms = generic_path_condition_atoms(condition)
          generic_branch_body_nodes(node).each do |child|
            generic_path_walk(document, child, function, guards + atoms, out)
          end
          return
        end

        if guards.size >= 2 && generic_path_action_node?(node)
          out << PathConditionSite.new(
            guards: guards.uniq.sort,
            action: normalize_text(node.text),
            file: document.file,
            function: function,
            line: line(node),
            span: span(node)
          )
          return
        end

        node.named_children.each { |child| generic_path_walk(document, child, function, guards, out) }
      end

      def generic_branch_condition(node)
        named_field(node, "condition") || named_field(node, "value") ||
          named_field(node, "subject") || node.named_children.first
      end

      def generic_branch_body_nodes(node)
        bodies = [
          named_field(node, "consequence"),
          named_field(node, "body"),
          named_field(node, "alternative")
        ].compact
        bodies = node.named_children.drop(1) if bodies.empty?
        bodies.flat_map do |body|
          children = body.named_children.reject { |child| comment_node?(child) }
          children.empty? ? [body] : children
        end
      end

      def comment_node?(node)
        node.kind.to_s.include?("comment")
      end

      def generic_path_condition_atoms(condition)
        return [] unless ts_node?(condition)

        if boolean_container?(condition) && boolean_and?(condition)
          flatten_boolean_and(condition).map { |child| decision_member_text(child) }.uniq.sort
        else
          [decision_member_text(condition)]
        end
      end

      def generic_path_action_node?(node)
        return false unless ts_node?(node)
        return false if branch_node?(node)

        generic_assignment_statement?(node) ||
          %w[call call_expression expression_statement return_statement identifier simple_identifier].include?(node.kind)
      end

      def comparison_target(node)
        return nil unless %w[binary binary_expression].include?(node.kind)

        operator = direct_operator(node)
        return nil unless COMPARISON_OPERATORS.include?(operator)

        { source: normalize_text(node.text), operator: operator }
      end

      def push_owner_context(document, stack, node)
        owner = owner_name_from_declaration(document, node)
        return stack unless owner

        parent_owner = current_owner_from_stack(stack)
        full_owner = if parent_owner && parent_owner != owner && !owner.include?("::")
                       "#{parent_owner}::#{owner}"
                     else
                       owner
                     end
        stack + [{ owner: full_owner, owner_declaration: true, owner_kind: owner_kind(node) }]
      end

      def current_function(stack)
        entry = stack.reverse.find { |item| item.is_a?(Hash) && item[:function] }
        entry ? entry[:function] : "(top-level)"
      end

      def current_owner(document, stack)
        current_owner_from_stack(stack) || file_owner(document.file)
      end

      def current_owner_from_stack(stack)
        entry = stack.reverse.find { |item| item.is_a?(Hash) && item[:owner] }
        entry && entry[:owner]
      end

      def current_language(stack)
        entry = stack.reverse.find { |item| item.is_a?(Hash) && item[:language] }
        entry && entry[:language]
      end

      def conditional_context?(stack)
        stack.any? { |item| item.is_a?(Hash) && %i[conditional iterates].include?(item[:control]) }
      end

      def current_control(stack)
        entry = stack.reverse.find { |item| item.is_a?(Hash) && item[:control] }
        entry ? entry[:control] : :always
      end

      def function_context(node, stack)
        {
          function: function_name(node),
          owner: function_owner_name(node, stack),
          params: function_params(node),
          receiver: function_receiver_name(node, stack)
        }
      end

      def function_owner_name(node, stack)
        receiver_owner_name(node) ||
          current_owner_from_stack(stack) ||
          receiver_convention_owner_name(node, stack: stack)
      end

      def line_text(document, node)
        document.lines[line(node) - 1].to_s
      end

      def control_context(node)
        return :iterates if %w[while until while_statement for for_statement for_in_statement
                               loop_expression do_block].include?(node.kind)
        return :iterates if node.kind == "expression_statement" && node.text.to_s.lstrip.match?(/\A(?:for|while|loop)\b/)
        return :iterates if node.kind == "labeled_statement" && node.text.to_s.lstrip.start_with?("for ")
        return :conditional if branch_node?(node)

        nil
      end

      def record_decision_site(document, node, stack, out)
        return if generated_prelude?(document, node)

        if boolean_container?(node) && boolean_and?(node)
          record_conjunction_decision(document, node, stack, out)
          return
        end

        case node.kind
        when "case", "switch_statement", "expression_switch_statement", "switch_expression",
             "match_statement", "match_expression", "when_expression"
          return if predicate_less_case?(node)

          patterns = case_patterns(node)
          return if patterns.size < 2

          out << DecisionSite.new(
            kind: :case_dispatch,
            members: patterns,
            file: document.file,
            function: current_function(stack),
            line: line(node),
            span: span(node),
            predicate: decision_predicate(node),
            enclosing_span: span(node)
          )
        when "body_statement", "block", "block_body", "argument_list", "statements"
          return unless hidden_case?(node)
          return if node.named_children.any? { |child| child.kind == "case" }
          return if predicate_less_case?(node)

          patterns = case_patterns(node)
          return if patterns.size < 2

          out << DecisionSite.new(
            kind: :case_dispatch,
            members: patterns,
            file: document.file,
            function: current_function(stack),
            line: line(node),
            span: span(node),
            predicate: decision_predicate(node),
            enclosing_span: span(node)
          )
        when "expression_statement"
          return unless hidden_match?(node)

          patterns = case_patterns(node)
          return if patterns.size < 2

          out << DecisionSite.new(
            kind: :case_dispatch,
            members: patterns,
            file: document.file,
            function: current_function(stack),
            line: line(node),
            span: span(node),
            predicate: decision_predicate(node),
            enclosing_span: span(node)
          )
        end
      end

      def record_conjunction_decision(document, node, stack, out)
        from_wrapper = parenthesized_wrapper?(node)
        return if from_wrapper &&
                  ts_node?(node.parent) &&
                  boolean_container?(node.parent) &&
                  boolean_and?(node.parent)

        node = node.named_children.first if from_wrapper
        return if !from_wrapper &&
                  ts_node?(node.parent) &&
                  boolean_container?(node.parent) &&
                  boolean_and?(node.parent) &&
                  !same_span?(node.parent, node)

        members = flatten_boolean_and(node).map { |child| decision_member_text(child) }.uniq.sort
        return if members.size < 2

        out << DecisionSite.new(
          kind: :conjunction,
          members: members,
          file: document.file,
          function: current_function(stack),
          line: conjunction_span(node)[0],
          span: conjunction_span(node),
          predicate: normalize_text(node.text),
          enclosing_span: decision_enclosing_span(node)
        )
      end

      def decision_enclosing_span(node)
        parent = parent_node(node)
        seen = Set.new
        while ts_node?(parent) && !seen.include?(node_key(parent))
          seen << node_key(parent)
          return span(parent) if branch_node?(parent) || %w[while until].include?(parent.kind)

          parent = parent_node(parent)
        end
        span(node)
      end

      def record_function_def(document, node, stack, out)
        name = function_name(node)
        return unless name

        out << FunctionDef.new(
          file: document.file,
          name: name,
          owner: owner_for_node(document, node, stack: stack),
          line: line(node),
          span: span(node),
          body: node,
          visibility: visibility(document, node),
          params: function_params(node),
          signature: function_signature(document, node),
          kind: function_kind(document, node, stack)
        )
      end

      def record_owner_def(document, node, stack, out)
        owner = owner_name_from_declaration(document, node)
        return unless owner

        full_owner = current_owner(document, stack)
        out << OwnerDef.new(
          file: document.file,
          name: full_owner,
          kind: owner_kind(node),
          line: line(node),
          span: span(node)
        )
      end

      def record_call_site(document, node, stack, out)
        target = call_target(document, node)
        return unless target
        target = normalize_target_receiver(target, stack)
        return if noise_call?(target)

        source_node = target[:source_node] || node
        out << CallSite.new(
          receiver: target[:receiver],
          message: target[:message],
          file: document.file,
          function: current_function(stack),
          owner: current_owner(document, stack),
          line: line(source_node),
          span: span(source_node),
          conditional: conditional_context?(stack),
          arguments: target[:arguments],
          control: current_control(stack),
          safe_navigation: target[:safe_navigation] || false,
          block: target[:block] || call_has_block?(source_node)
        )
      end

      def record_state_declaration(document, node, stack, out)
        declaration = state_declaration(node)
        return unless declaration

        out << StateDeclaration.new(
          field: declaration[:field],
          owner: owner_for_node(document, node, stack: stack),
          type: declaration[:type],
          file: document.file,
          line: line(node),
          span: span(node)
        )
      end

      def record_state_write(document, node, stack, out)
        return if skip_state_write_node?(node)

        lhs =
          if %w[assignment assignment_expression augmented_assignment assignment_statement operator_assignment].include?(node.kind)
            named_field(node, "left") || node.named_children.first
          elsif assignment_lhs?(node)
            node
          end
        return unless lhs

        target = state_target(lhs)
        return unless target
        target = normalize_target_receiver(target, stack)
        return if skip_state_write_target?(target)

        source_node = state_write_source_node(node)
        out << StateWrite.new(
          field: target[:field],
          receiver: target[:receiver],
          file: document.file,
          function: current_function(stack),
          line: line(source_node),
          span: span(source_node),
          owner: current_owner(document, stack)
        )
      end

      def skip_state_write_node?(_node)
        false
      end

      def skip_state_write_target?(target)
        target[:field] == "[]"
      end

      def state_write_source_node(node)
        node
      end

      def record_state_read(document, node, stack, out)
        target = state_read_target(node)
        return unless target
        target = normalize_target_receiver(target, stack)

        out << StateRead.new(
          field: target[:field],
          receiver: target[:receiver],
          file: document.file,
          function: current_function(stack),
          line: line(node),
          span: span(node),
          owner: current_owner(document, stack)
        )
      end

      def record_state_param_origin(document, node, stack, out)
        lhs = nil
        rhs = nil
        if %w[assignment assignment_expression augmented_assignment assignment_statement].include?(node.kind)
          lhs = named_field(node, "left") || node.named_children.first
          rhs = named_field(node, "right") || named_field(node, "value") || node.named_children[1]
        elsif assignment_lhs?(node)
          lhs = node
          rhs = next_sibling(next_sibling(node))
        end
        return unless lhs && rhs

        target = state_target(lhs)
        return unless target && rhs
        target = normalize_target_receiver(target, stack)

        params = current_params(stack)
        return if params.empty?

        rhs_param_names(rhs, params).each do |param|
          out << StateParamOrigin.new(
            field: target[:field],
            receiver: target[:receiver],
            owner: current_owner(document, stack),
            param: param,
            file: document.file,
            function: current_function(stack),
            line: line(node),
            span: span(node)
          )
        end
      end

      def record_branch_decision(document, node, stack, out, immutable_readers:, immutable_reader_types:, type_aliases:,
                                 method_param_types:)
        return unless branch_node?(node)

        cond = if hidden_modifier_if?(node)
                 modifier_condition(node)
               else
                 named_field(node, "condition") || named_field(node, "value") ||
                   named_field(node, "subject") || node.named_children.first
               end
        return unless cond

        refs = []
        collect_state_refs(
          cond,
          refs,
          defn: current_function(stack),
          immutable_readers: immutable_readers,
          immutable_reader_types: immutable_reader_types,
          type_aliases: type_aliases,
          method_param_types: method_param_types
        )
        refs.uniq!
        refs.sort!
        return if refs.empty?

        out << BranchDecision.new(
          file: document.file,
          function: current_function(stack),
          line: line(node),
          span: span(node),
          predicate: normalize_text(cond.text),
          state_refs: refs
        )
      end

      def record_branch_arm(document, node, stack, out)
        return if generated_prelude?(document, node)

        if if_node?(node)
          record_if_arms(document, node, stack, out)
          return
        end

        case node.kind
        when "while", "until", "while_statement", "for", "for_statement"
          record_loop_arm(document, node, stack, out)
        when "case", "body_statement", "block", "expression_statement", "statements", "switch_statement", "expression_switch_statement", "switch_expression",
             "match_statement", "match_expression", "when_expression"
          return if node.kind == "body_statement" && !hidden_case?(node)
          return if node.kind == "block" && !hidden_case?(node)
          return if node.kind == "statements" && !hidden_case?(node)
          return if node.kind == "expression_statement" && !hidden_match?(node)

          record_case_arms(document, node, stack, out)
        end
      end

      def record_if_arms(document, node, stack, out)
        predicate = decision_predicate(node)
        dspan = span(node)
        dline = line(node)
        consequence = named_field(node, "consequence") || named_field(node, "body") ||
                      node.named_children[1]
        alternative = named_field(node, "alternative") ||
                      node.named_children.find { |child| child.kind.match?(/else|elsif|alternative/) }
        alternative ||= node.named_children[2] if node.named_children[2] != consequence

        [[consequence, "then"], [alternative, "else"]].each do |arm_node, member|
          next unless ts_node?(arm_node)

          out << BranchArm.new(
            file: document.file,
            function: current_function(stack),
            kind: :if,
            line: line(arm_node),
            span: span(arm_node),
            decision_line: dline,
            decision_span: dspan,
            predicate: predicate,
            member: member,
            body: normalize_text(arm_node.text)
          )
        end
      end

      def record_loop_arm(document, node, stack, out)
        body = named_field(node, "body") || node.named_children[1]
        return unless ts_node?(body)

        out << BranchArm.new(
          file: document.file,
          function: current_function(stack),
          kind: :loop,
          line: line(body),
          span: span(body),
          decision_line: line(node),
          decision_span: span(node),
          predicate: decision_predicate(node),
          member: "body",
          body: normalize_text(body.text)
        )
      end

      def record_case_arms(document, node, stack, out)
        predicate = decision_predicate(node)
        dspan = span(node)
        dline = line(node)
        case_arms(node).each do |arm|
          pattern = case_arm_pattern(arm)
          next if default_case_pattern?(pattern)

          out << BranchArm.new(
            file: document.file,
            function: current_function(stack),
            kind: :case,
            line: line(arm),
            span: span(arm),
            decision_line: dline,
            decision_span: dspan,
            predicate: predicate,
            member: pattern,
            body: normalize_text(case_arm_body(arm))
          )
        end
      end

      def record_implicit_state_accesses(document, out)
        declared = declared_state_index(out[:state_declarations])
        return if declared.empty?

        locals = local_declaration_index(document)
        params = function_param_index(out[:function_defs])
        TreeSitterAdapter.walk_document(document, initial_stack(document), self) do |node, stack|
          next unless implicit_state_identifier?(node)

          owner = current_owner(document, stack)
          function = current_function(stack)
          next if function == "(top-level)"

          field = node.text.to_s
          next unless declared[owner].include?(field)
          next if params[[owner, function]].include?(field)
          next if locals[[owner, function]].include?(field)
          next if identifier_declaration_site?(node)
          next if member_message_identifier?(node)

          if implicit_assignment_lhs?(node)
            out[:state_writes] << StateWrite.new(
              field: field,
              receiver: "self",
              file: document.file,
              function: function,
              line: line(node),
              span: span(node),
              owner: owner
            )
          else
            out[:state_reads] << StateRead.new(
              field: field,
              receiver: "self",
              file: document.file,
              function: function,
              line: line(node),
              span: span(node),
              owner: owner
            )
          end
        end
      end

      def case_patterns(node)
        case_arms(node).flat_map do |child|
          case_arm_patterns(child).reject { |normalized| default_case_pattern?(normalized) }
        end.uniq.sort
      end

      def case_arm_patterns(child)
        case child.kind
        when "when", "match_arm"
          patterns = child.named_children.select { |node| %w[pattern case_pattern match_pattern].include?(node.kind) }
          patterns = [named_field(child, "pattern") || child.named_children.first].compact if patterns.empty?
          case_pattern_texts(patterns)
	        when "switch_case", "case_clause", "expression_case", "case_statement", "switch_section",
	             "switch_block_statement_group", "switch_entry", "when_entry"
          return [] if child.text.to_s.lstrip.start_with?("else")

          value = named_field(child, "value") || named_field(child, "pattern") ||
                  child.named_children.find { |candidate| candidate.kind == "when_condition" } ||
                  child.named_children.find { |candidate| candidate.kind == "switch_pattern" } ||
                  child.named_children.first
          value && value.kind !~ /statement|block/ ? [normalize_text(value.text)] : []
        else
          []
        end
      end

      def case_arm_pattern(child)
        patterns = case_arm_patterns(child)
        return nil if patterns.empty?

        patterns.join(", ")
      end

      def case_pattern_texts(patterns)
        return [] if patterns.empty?

        patterns.map { |pattern| normalize_text(pattern.text) }
      end

      def case_arm_body(child)
        pattern = named_field(child, "pattern") || named_field(child, "value") || child.named_children.first
        members = child.named_children
        body = members.drop_while { |node| node == pattern }.drop(1)
        body = members[1..] if body.empty?
        Array(body).map(&:text).join(" ")
      end

      def case_arms(node)
        arms = []
        stack = node.named_children.dup
        until stack.empty?
          child = stack.shift
          next unless ts_node?(child)

	          if %w[when switch_case case_clause expression_case case_statement switch_section switch_block_statement_group switch_entry when_entry match_arm].include?(child.kind)
            arms << child
          elsif !%w[method function_definition function_declaration method_definition
                    method_declaration function_item class class_definition
                    class_declaration].include?(child.kind)
            stack.concat(child.named_children)
          end
        end
        arms
      end

      def decision_predicate(node)
        return normalize_text(modifier_condition(node).text) if hidden_modifier_if?(node) && modifier_condition(node)

        target = decision_subject(node)
        strip_enclosing_parentheses(normalize_text(target ? target.text : node.text))
      end

      def decision_subject(node)
        named_field(node, "value") || named_field(node, "subject") ||
          node.named_children.find { |child| child.kind == "when_subject" } ||
          named_field(node, "condition") ||
          node.named_children.find do |child|
	            !%w[when switch_case case_clause expression_case case_statement switch_section switch_block_statement_group switch_entry when_entry match_arm else then comment].include?(child.kind)
          end
      end

      def predicate_less_case?(node)
        (node.kind == "case" || hidden_case?(node)) && !decision_subject(node)
      end

      def default_case_pattern?(text)
        text.nil? || %w[_ default].include?(text)
      end

      def boolean_and?(node)
        if parenthesized_wrapper?(node)
          child = node.named_children.first
          return boolean_and?(child)
        end

        %w[&& and].include?(direct_operator(node))
      end

      def flatten_boolean_and(node)
        return [node] unless ts_node?(node) &&
                             boolean_container?(node) &&
                             boolean_and?(node)
        return flatten_boolean_and(node.named_children.first) if parenthesized_wrapper?(node)

        node.named_children.flat_map { |child| flatten_boolean_and(child) }
      end

      def boolean_container?(node)
        return false unless ts_node?(node)
        return true if %w[binary binary_expression boolean_operator conjunction_expression disjunction_expression].include?(node.kind)
        return boolean_container?(node.named_children.first) if parenthesized_wrapper?(node)
        return false unless %w[body_statement block_body statement pattern argument_list].include?(node.kind)
        return false unless %w[&& and].include?(direct_operator(node))
        return false if node.named_children.size < 2

        node.children.all? do |child|
          child.named? || %w[&& and ( )].include?(child.text.to_s)
        end
      end

      def same_span?(left, right)
        span(left) == span(right)
      end

      def conjunction_span(node)
        base = span(node)
        if node.kind == "pattern" && node.text.to_s.lstrip.start_with?("(")
          base = base.dup
          base[1] += 1
        end
        base
      end

      def parenthesized_wrapper?(node)
        ts_node?(node) && %w[condition_clause parenthesized_statements parenthesized_expression].include?(node.kind) &&
          node.named_children.size == 1
      end

      def decision_member_text(node)
        normalize_text(strip_enclosing_parentheses(node.text))
      end

      def strip_enclosing_parentheses(text)
        value = text.to_s.strip
        loop do
          break value unless value.start_with?("(") && value.end_with?(")")
          break value unless enclosing_parentheses_wrap_all?(value)

          value = value[1...-1].strip
        end
        value
      end

      def enclosing_parentheses_wrap_all?(text)
        depth = 0
        text.each_char.with_index do |char, index|
          depth += 1 if char == "("
          depth -= 1 if char == ")"
          return false if depth.zero? && index < text.length - 1
          return false if depth.negative?
        end
        depth.zero?
      end

      def direct_operator(node)
        node.children.find { |child| !child.named? && !%w[( )].include?(child.text.to_s) }&.text.to_s
      rescue StandardError
        ""
      end

      def branch_node?(node)
        BRANCH_KINDS.include?(node.kind) || hidden_match?(node) || hidden_if?(node) ||
          hidden_modifier_if?(node) || hidden_case?(node)
      end

      def if_node?(node)
        %w[if unless if_statement if_expression if_modifier unless_modifier].include?(node.kind) ||
          hidden_if?(node) || hidden_modifier_if?(node)
      end

      def hidden_if?(node)
        return false unless ts_node?(node)
        return true if node.kind == "expression_statement" && node.text.to_s.lstrip.start_with?("if ")
        return false unless %w[block body_statement statements statement_list].include?(node.kind)

        first_token = node.children.first
        first_token && !first_token.named? && %w[if unless].include?(first_token.kind.to_s)
      end

      def hidden_modifier_if?(node)
        false
      end

      def modifier_condition(node)
        node.named_children.last
      end

      def hidden_case?(node)
        return false unless ts_node?(node)
        return false unless %w[body_statement block statements statement_list].include?(node.kind)

        first_token = node.children.first
        first_token && !first_token.named? && %w[case match switch when].include?(first_token.kind.to_s)
      end

      def hidden_match?(node)
        ts_node?(node) &&
          node.kind == "expression_statement" &&
          node.text.to_s.lstrip.start_with?("match ")
      end

      def first_token_kind(node)
        node.children.first&.kind.to_s
      end

      def collect_state_refs(node, refs, defn:, immutable_readers:, immutable_reader_types:, type_aliases:,
                             method_param_types:)
        if (ref = direct_state_ref(node))
          refs << ref
        elsif (target = state_read_target(node))
          unless namespace_receiver?(target[:receiver])
            unless immutable_state_read?(target, defn, immutable_readers, immutable_reader_types, type_aliases, method_param_types)
              refs << (target[:receiver] == "self" ? target[:field] : "#{target[:receiver]}.#{target[:field]}")
            end
          end
        end
        node.children.each do |child|
          collect_state_refs(
            child,
            refs,
            defn: defn,
            immutable_readers: immutable_readers,
            immutable_reader_types: immutable_reader_types,
            type_aliases: type_aliases,
            method_param_types: method_param_types
          ) if ts_node?(child)
        end
      end

      def immutable_state_read?(target, defn, immutable_readers, immutable_reader_types, type_aliases, method_param_types)
        receiver = target[:receiver].to_s
        field = target[:field].to_sym
        return false if receiver.empty? || receiver == "self"

        parts = receiver.split(".")
        param = parts.shift
        type = method_param_types.fetch(defn, {})[param]
        return false unless type

        parts.each do |reader|
          type = immutable_reader_result_type(type, reader.to_sym, immutable_reader_types, type_aliases)
          return false unless type
        end
        immutable_reader?(type, field, immutable_readers, type_aliases)
      end

      def immutable_reader?(type_name, field, immutable_readers, type_aliases)
        resolved = resolve_type_alias(type_name, type_aliases)
        short = resolved.to_s.split("::").last
        readers = if immutable_readers.key?(resolved)
                    immutable_readers[resolved]
                  else
                    immutable_readers[short]
                  end
        readers&.include?(field) || false
      end

      def immutable_reader_result_type(type_name, field, immutable_reader_types, type_aliases)
        resolved = resolve_type_alias(type_name, type_aliases)
        short = resolved.to_s.split("::").last
        reader_types = if immutable_reader_types.key?(resolved)
                         immutable_reader_types[resolved]
                       else
                         immutable_reader_types[short]
                       end
        reader_types && reader_types[field]
      end

      def resolve_type_alias(type_name, type_aliases)
        seen = Set.new
        current = type_name.to_s
        loop do
          break current if seen.include?(current)

          seen.add(current)
          target = type_aliases[current] || type_aliases[current.split("::").last]
          break current unless target

          current = target
        end
      end

      def current_params(stack)
        entry = stack.reverse.find { |item| item.is_a?(Hash) && item[:params] }
        Array(entry && entry[:params])
      end

      def rhs_param_names(node, params)
        found = []
        collect_identifiers(node, found)
        found & params
      end

      def collect_identifiers(node, out)
        return unless ts_node?(node)

        pending = [node]
        seen = Set.new
        until pending.empty?
          current = pending.pop
          next unless ts_node?(current)
          key = node_key(current)
          next if seen.include?(key)

          seen << key
          out << current.text if current.kind == "identifier"
          current.children.reverse_each { |child| pending << child }
        end
      end

      def declared_state_index(declarations)
        declarations.each_with_object(Hash.new { |h, k| h[k] = Set.new }) do |decl, index|
          index[decl.owner.to_s].add(decl.field.to_s)
        end
      end

      def function_param_index(functions)
        functions.each_with_object(Hash.new { |h, k| h[k] = Set.new }) do |fn, index|
          index[[fn.owner.to_s, fn.name.to_s]].merge(Array(fn.params).map(&:to_s))
        end
      end

      def local_declaration_index(document)
        index = Hash.new { |h, k| h[k] = Set.new }
        TreeSitterAdapter.walk_document(document, initial_stack(document), self) do |node, stack|
          next unless local_variable_declarator?(node)

          owner = current_owner(document, stack)
          function = current_function(stack)
          next if function == "(top-level)"

          local_name_node(node)&.then { |name| index[[owner, function]].add(name.text.to_s) }
        end
        index
      end

      def local_variable_declarator?(node)
        return false unless ts_node?(node)
        return false unless %w[variable_declarator init_declarator].include?(node.kind)

        !inside_kind?(node, %w[field_declaration property_declaration public_field_definition])
      end

      def local_name_node(node)
        named_field(node, "name") ||
          node.named_children.find { |child| %w[identifier field_identifier property_identifier].include?(child.kind) }
      end

      def implicit_state_identifier?(node)
        ts_node?(node) && %w[identifier field_identifier property_identifier].include?(node.kind)
      end

      def identifier_declaration_site?(node)
        parent = parent_node(node)
        return false unless parent
        return true if %w[parameter_declaration parameter variable_declarator init_declarator function_declarator
                          method_declaration function_definition class_specifier class].include?(parent.kind)
        return true if inside_kind?(node, %w[field_declaration property_declaration public_field_definition])

        false
      end

      def member_message_identifier?(node)
        parent = parent_node(node)
        return false unless parent && field_like_node?(parent)

        field = named_field(parent, "field") || named_field(parent, "property") ||
                named_field(parent, "name") || parent.named_children.last
        field == node
      end

      def implicit_assignment_lhs?(node)
        parent = parent_node(node)
        return false unless parent

        if %w[assignment_expression assignment assignment_statement augmented_assignment operator_assignment].include?(parent.kind)
          lhs = named_field(parent, "left") || parent.named_children.first
          return lhs == node
        end

        assignment_lhs?(node)
      end

      def inside_kind?(node, kinds)
        parent = parent_node(node)
        seen = Set.new
        while parent && !seen.include?(node_key(parent))
          seen << node_key(parent)
          return true if kinds.include?(parent.kind)

          parent = parent_node(parent)
        end
        false
      end

      def owner_for_node(document, node, stack: nil)
        receiver_owner = receiver_owner_name(node)
        return receiver_owner if receiver_owner
        convention_owner = receiver_convention_owner_name(node)
        return convention_owner if convention_owner

        stacked_owner = current_owner_from_stack(Array(stack))
        return stacked_owner if stacked_owner

        chain = owner_chain_for_node(document, node)
        return chain.join("::") unless chain.empty?

        return file_owner(document.file) if document

        nil
      end

      def owner_chain_for_node(document, node)
        chain = []
        seen = Set.new
        seen_nodes = Set.new
        parent = parent_node(node)
        while parent && !seen_nodes.include?(node_key(parent))
          seen_nodes << node_key(parent)
          if (owner = owner_name_from_declaration(document, parent))
            unless seen.include?(owner)
              chain << owner
              seen << owner
            end
          end
          parent = parent_node(parent)
        end
        chain.reverse
      end

      def impl_owner_name(node)
        type = named_field(node, "type") ||
               node.named_children.find { |child| child.kind.match?(/type|identifier/) }
        normalize_type_owner(type&.text)
      end

      def receiver_owner_name(node)
        receiver_type = method_receiver_type_node(node)
        receiver_type && normalize_type_owner(receiver_type.text)
      end

      def method_receiver_type_node(node)
        declaration = method_receiver_declaration(node)
        return nil unless declaration

        declaration.named_children.reverse.find do |child|
          %w[pointer_type type_identifier qualified_type generic_type scoped_type_identifier].include?(child.kind)
        end
      end

      def method_receiver_param_node(node)
        declaration = method_receiver_declaration(node)
        return nil unless declaration

        declaration.named_children.find { |child| child.kind == "identifier" }
      end

      def method_receiver_declaration(node)
        return nil unless ts_node?(node) && node.kind == "method_declaration"

        receiver_params = node.named_children.find { |child| child.kind == "parameter_list" }
        receiver_params&.named_children&.find { |child| child.kind == "parameter_declaration" }
      end

      def first_argument_receiver_parameter(node)
        params = named_field(named_field(node, "declarator"), "parameters") ||
                 named_field(node, "parameters") ||
                 node.named_children.find { |child| child.kind == "parameter_list" } ||
                 named_field(node, "declarator")&.named_children&.find { |child| child.kind == "parameter_list" }
        first = params&.named_children&.find { |child| child.kind == "parameter_declaration" }
        return nil unless first

        type_node = first.named_children.find do |child|
          %w[type_identifier primitive_type qualified_identifier scoped_type_identifier].include?(child.kind)
        end
        name_node = first.named_children.reverse.find do |child|
          %w[identifier field_identifier].include?(child.kind)
        end
        name_node ||= declarator_name(first)
        return nil unless type_node && name_node

        name = ts_node?(name_node) ? name_node.text : name_node.to_s
        { type: type_node.text, name: name }
      end

      def snake_case_type_name(type)
        type.to_s
            .split("::").last
            .gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
            .gsub(/([a-z\d])([A-Z])/, '\1_\2')
            .downcase
      end

      def bound_container_name(node)
        parent = parent_node(node)
        seen_nodes = Set.new
        while parent && !seen_nodes.include?(node_key(parent)) &&
              %w[ERROR expression_statement return_expression].include?(parent.kind)
          seen_nodes << node_key(parent)
          parent = parent_node(parent)
        end
        return nil unless parent

        if %w[variable_declaration const_declaration lexical_declaration public_field_definition
              field_declaration property_declaration].include?(parent.kind)
          name = named_field(parent, "name") ||
                 parent.named_children.find { |child| %w[identifier field_identifier property_identifier type_identifier].include?(child.kind) }
          return name.text if name
        end
        nil
      end

      def returned_container_owner(document, node)
        parent = parent_node(node)
        seen_nodes = Set.new
        while parent && !seen_nodes.include?(node_key(parent))
          seen_nodes << node_key(parent)
          if (name = function_name(parent))
            return name
          end

          parent = parent_node(parent)
        end
        nil
      end

      def anonymous_owner_name(document, node)
        return nil unless document

        "#{file_owner(document.file)}::anonymous@#{line(node)}"
      end

      def generic_call_target(document, node)
        if %w[method_invocation invocation_expression].include?(node.kind)
          adjacent = generic_adjacent_method_invocation_target(node)
          return adjacent if adjacent
        end

        callee = named_field(node, "function") || named_field(node, "callee") || node.named_children.first
        return nil unless callee
        return nil if callee.kind == "builtin_function" || callee.text.to_s.start_with?("@")

        target = target_from_callee(callee).merge(
          arguments: call_argument_nodes(node).map { |argument| normalize_text(argument.text) }
        )
        first_argument_receiver_call_target(document, node, target) || target
      rescue NoMethodError
        nil
      end

      def generic_adjacent_method_invocation_target(node)
        names = node.named_children.select { |child| %w[identifier simple_identifier].include?(child.kind) }
        return nil unless names.size >= 2

        args = node.named_children.find { |child| %w[argument_list arguments call_suffix].include?(child.kind) }
        {
          receiver: normalize_text(names.first.text),
          message: names[1].text,
          arguments: Array(args&.named_children).map { |child| normalize_text(child.text) }
        }
      end

      def first_argument_receiver_call_target(_document, node, target)
        return nil unless first_argument_receiver?
        return nil unless target[:receiver] == "self"

        first_arg = call_argument_nodes(node).first
        arg_target = state_read_target(first_arg)
        return nil unless arg_target

        {
          receiver: "#{arg_target[:receiver]}.#{arg_target[:field]}",
          message: target[:message],
          arguments: target[:arguments]
        }
      end

      def call_argument_nodes(node)
        args = named_field(node, "arguments") ||
               node.named_children.find { |child| %w[argument_list arguments].include?(child.kind) }
        return Array(args&.named_children) if args
        return [] unless node.kind == "call_expression"

        callee = named_field(node, "function") || named_field(node, "callee") || node.named_children.first
        node.named_children.reject { |child| child == callee }
      end

      def adjacent_argument_call_target(node)
        args = next_sibling(node)
        return nil unless %w[argument_list arguments call_suffix].include?(args&.kind)

        target_from_callee(node).merge(arguments: args.named_children.map { |child| normalize_text(child.text) })
      rescue NoMethodError
        nil
      end

      def target_from_callee(callee)
        if field_like_node?(callee)
          object = named_field(callee, "object") || named_field(callee, "receiver") ||
                   named_field(callee, "operand") || named_field(callee, "value") ||
                   named_field(callee, "expression") ||
                   callee.named_children.find { |child| child.kind != "navigation_suffix" }
          field = named_field(callee, "field") || named_field(callee, "property") ||
                  named_field(callee, "suffix") ||
                  callee.named_children.find { |child| child.kind == "navigation_suffix" } ||
                  callee.named_children.last
          field_text = member_field_text(field)
          return nil unless object && field_text

          {
            receiver: normalize_text(object.text).sub(/\A\*/, ""),
            message: field_text
          }
        elsif %w[identifier field_identifier property_identifier constant type_identifier].include?(callee.kind)
          {
            receiver: "self",
            message: callee.text
          }
        else
          text = normalize_text(callee.text)
          return nil if text.empty?

          parts = text.split(".")
          if parts.size > 1
            {
              receiver: parts[0...-1].join("."),
              message: parts[-1]
            }
          else
            {
              receiver: "self",
              message: text
            }
          end
        end
      end

      def noise_call?(target)
        message = target[:message].to_s
        receiver = target[:receiver].to_s
        return true if message.empty?
        return true if NOISE_MESSAGES.include?(message)
        return true if message.start_with?("@")
        return true if receiver.match?(/\A(?:std|builtin|build_options)(?:\.|\z)/)

        false
      end

      def generic_state_declaration(node)
        case node.kind
        when "assignment", "assignment_expression", "assignment_statement"
          assignment_state_declaration(node)
        when "property_declaration", "public_field_definition", "field_definition", "field_declaration"
          generic_field_declaration(node)
        else
          nil
        end
      end

      def generic_field_declaration(node)
        name = field_declaration_name_node(node)
        return nil unless name

        { field: name.text, type: declared_type_text(node, name) }
      end

      def field_declaration_name_node(node)
        named_field(node, "name") ||
          variable_declarator_name(node) ||
          node.named_children.find { |child| %w[field_identifier property_identifier].include?(child.kind) } ||
          node.named_children.reverse.find { |child| child.kind == "identifier" }
      end

      def variable_declarator_name(node)
        pending = node.named_children.dup
        seen = Set.new
        until pending.empty?
          current = pending.shift
          next unless ts_node?(current)
          key = node_key(current)
          next if seen.include?(key)

          seen << key
          if %w[variable_declarator pointer_declarator declarator].include?(current.kind)
            direct_name = named_field(current, "name") ||
                          current.named_children.find do |child|
                            %w[identifier field_identifier property_identifier].include?(child.kind)
                          end
            return direct_name if direct_name
            return current if current.kind == "variable_declarator" && current.text.match?(/\A[A-Za-z_]\w*\z/)
          elsif current.kind == "init_declarator"
            return named_field(current, "name") ||
                   current.named_children.find do |child|
                     %w[identifier field_identifier property_identifier].include?(child.kind)
                   end
          end
          pending.concat(current.named_children)
        end
        nil
      end

      def declared_type_text(node, name_node)
        text = node.text.to_s
        after_name = text[(name_node.end_byte - node.start_byte)..].to_s
        if (match = after_name.match(/\A\s*:\s*([^=,\n]+)/))
          normalize_text(match[1])
        elsif (match = text.match(/\A\s*(?:pub\s+)?(?:const|var)\s+\w+\s*:\s*([^=;\n]+)/))
          normalize_text(match[1])
        elsif (match = after_name.match(/\A\s+([^=;,\n]+)/))
          normalize_text(match[1])
        elsif (type = declared_type_before_name(text, node, name_node))
          type
        end
      rescue StandardError
        nil
      end

      def declared_type_before_name(text, node, name_node)
        before_name = text[0...(name_node.start_byte - node.start_byte)].to_s
        before_name = before_name.gsub(/\b(?:public|private|protected|internal|static|readonly|const|pub|mut|var|let)\b/, " ")
        before_name = before_name.gsub(/[;,{].*\z/m, " ")
        before_name = normalize_text(before_name)
        return nil if before_name.empty?

        tokens = before_name.split(/\s+/).reject { |token| token.match?(/\A[*&]+\z/) }
        candidate = tokens.last.to_s.delete_suffix("*").delete_suffix("&")
        return nil if candidate.empty?

        candidate
      end

      def assignment_state_declaration(node)
        lhs = named_field(node, "left") || node.named_children.first
        rhs = named_field(node, "right") || named_field(node, "value") || node.named_children[1]
        target = state_target(lhs)
        return nil unless target
        return nil unless %w[self this].include?(target[:receiver].to_s)

        type = inferred_assignment_type(rhs)
        return nil unless type

        { field: target[:field], type: type }
      end

      def inferred_assignment_type(node)
        return nil unless ts_node?(node)

        text = normalize_text(node.text)
        patterns = [
          /\Anew\s+([A-Z][A-Za-z0-9_:]*)\s*(?:[({<]|$)/,
          /\A([A-Z][A-Za-z0-9_:]*)\s*(?:[({<]|$)/
        ]
        match = patterns.filter_map { |pattern| text.match(pattern) }.first
        match && match[1]
      end

      def generic_state_read_target(node)
        case node.kind
        when "call"
          receiver = named_field(node, "receiver")
          method = named_field(node, "method")
          return nil unless receiver && method
          return nil if namespace_receiver?(receiver.text)
          return nil if NOISE_MESSAGES.include?(method.text)
          return nil if named_field(node, "arguments")

          { receiver: normalize_text(receiver.text), field: method.text }
        when "field", "field_access", "selector_expression", "member_expression", "member_access_expression", "attribute",
             "field_expression", "navigation_expression", "directly_assignable_expression", "expression_list",
             "dot_index_expression", "variable_list"
          return nil if node.kind == "expression_list" && !(named_field(node, "operand") && named_field(node, "field"))

          object = named_field(node, "object") || named_field(node, "receiver") ||
                   named_field(node, "expression") ||
                   named_field(node, "operand") || named_field(node, "value") ||
                   named_field(node, "argument") ||
                   node.named_children.find { |child| child.kind != "navigation_suffix" }
          field = named_field(node, "field") || named_field(node, "property") ||
                  named_field(node, "name") || named_field(node, "suffix") ||
                  node.named_children.find { |child| child.kind == "navigation_suffix" } ||
                  node.named_children.last
          if node.kind == "field_expression" && node.text.to_s.start_with?(".")
            field = node.named_children.find { |child| child.kind == "identifier" } || field
            return { receiver: ".literal", field: field.text } if field
          end
          field_text = member_field_text(field)
          return nil unless object && field_text
          return nil if namespace_receiver?(object.text)
          return nil if NOISE_MESSAGES.include?(field_text)

          { receiver: normalize_text(object.text), field: field_text }
        end
      end

      def generic_state_target(lhs)
        return nil unless ts_node?(lhs)
        return nil if prev_sibling(lhs)&.text == ":"

        case lhs.kind
        when "call"
          receiver = named_field(lhs, "receiver")
          method = named_field(lhs, "method")
          return nil unless receiver && method

          { receiver: normalize_text(receiver.text), field: method.text.sub(/=\z/, "") }
        when "field", "field_access", "selector_expression", "member_expression", "member_access_expression", "attribute",
             "field_expression", "navigation_expression", "directly_assignable_expression", "expression_list",
             "dot_index_expression", "variable_list"
          if lhs.kind == "expression_list" && !(named_field(lhs, "operand") && named_field(lhs, "field"))
            return generic_state_target(lhs.named_children.first)
          end

          object = named_field(lhs, "object") || named_field(lhs, "receiver") ||
                   named_field(lhs, "expression") ||
                   named_field(lhs, "operand") || named_field(lhs, "value") ||
                   named_field(lhs, "argument") ||
                   lhs.named_children.find { |child| child.kind != "navigation_suffix" }
          field = named_field(lhs, "field") || named_field(lhs, "property") ||
                  named_field(lhs, "name") || named_field(lhs, "suffix") ||
                  lhs.named_children.find { |child| child.kind == "navigation_suffix" } ||
                  lhs.named_children.last
          if lhs.kind == "field_expression" && lhs.text.to_s.start_with?(".")
            field = lhs.named_children.find { |child| child.kind == "identifier" } || field
            return { receiver: ".literal", field: field.text.sub(/=\z/, "") } if field
          end
          field_text = member_field_text(field)
          return nil unless object && field_text

          { receiver: normalize_text(object.text), field: field_text.sub(/=\z/, "") }
        end
      end

      def assignment_lhs?(node)
        return false if prev_sibling(node)&.text == ":"

        sibling = next_sibling(node)
        sibling && %w[= += -= *= /= %= &&= ||=].include?(sibling.text.to_s)
      end

      def direct_state_ref(_node)
        nil
      end

      def call_has_block?(node)
        ts_node?(node) &&
          node.named_children.any? { |child| %w[block do_block lambda].include?(child.kind) }
      end

      def next_sibling(node)
        node.next_sibling
      rescue StandardError
        nil
      end

      def prev_sibling(node)
        node.prev_sibling
      rescue StandardError
        nil
      end

      def namespace_receiver?(text)
        receiver = text.to_s
        return true if receiver.match?(/\A(?:std|builtin|build_options)(?:\.|\z)/)
        return true if receiver.start_with?("@")

        receiver.match?(/\A[A-Z][A-Za-z0-9_]*(?:\.[A-Z][A-Za-z0-9_]*)*\z/)
      end

      def named_field(node, name)
        node.child_by_field_name(name)
      rescue StandardError
        nil
      end

      def parent_node(node)
        node.parent
      rescue StandardError
        nil
      end

      def field_like_node?(node)
        %w[
          attribute directly_assignable_expression dot_index_expression expression_list field field_access
          field_expression member_access_expression member_expression navigation_expression scoped_identifier
          selector_expression variable_list
        ].include?(node.kind)
      end

      def member_field_text(field)
        return nil unless ts_node?(field)

        if field.kind == "navigation_suffix"
          suffix = named_field(field, "suffix") ||
                   field.named_children.find { |child| %w[identifier simple_identifier field_identifier property_identifier].include?(child.kind) } ||
                   field.named_children.last
          text = suffix&.text.to_s
          return nil if text.empty?

          return text.sub(/\A[.?]+/, "")
        end

        field.text.to_s.sub(/\A[.?]+/, "")
      end

      def normalize_type_owner(text)
        value = text.to_s.strip
        value = value.sub(/\A[&*]+/, "")
        value = value.gsub(/\b(?:const|mut|var)\b/, "").strip
        value.split(/[({<\s]/).first.to_s.split(".").last
      end

      def first_named_text(node, kinds)
        expanded = kinds.include?("identifier") ? kinds + %w[simple_identifier] : kinds
        child = node.named_children.find { |c| expanded.include?(c.kind) }
        child&.text
      end

      def declarator_name(node)
        return nil unless ts_node?(node)

        pending = [node]
        seen = Set.new
        until pending.empty?
          current = pending.pop
          next unless ts_node?(current)
          key = node_key(current)
          next if seen.include?(key)

          seen << key
          return current.text if %w[identifier simple_identifier field_identifier property_identifier].include?(current.kind)

          current.named_children.reverse_each { |child| pending << child }
        end
        nil
      end

      def exported_name_visibility(name)
        text = name.to_s
        return nil if text.empty?

        text.match?(/\A[A-Z]/) ? :public : :private
      end

      def modifier_visibility(node)
        return :private if node.children.any? { |child| child.text == "private" }
        return :protected if node.children.any? { |child| child.text == "protected" }
        return :public if node.children.any? { |child| %w[public pub].include?(child.text) }

        nil
      end

      def parameter_name(param)
        return nil unless ts_node?(param)
        return param.text if %w[identifier simple_identifier shorthand_property_identifier_pattern].include?(param.kind)

        name = named_field(param, "name") ||
               param.named_children.select do |child|
                 %w[identifier simple_identifier field_identifier property_identifier].include?(child.kind)
               end.last
        text = name&.text.to_s
        return nil if text.empty? || text == "_"

        text
      end

      def normalize_target_receiver(target, stack)
        receiver = target[:receiver].to_s
        return target.merge(receiver: "self") if %w[self this].include?(receiver)

        current_receiver = current_receiver_name(stack)
        return target unless current_receiver
        return target.merge(receiver: "self") if receiver == current_receiver

        if receiver.start_with?("#{current_receiver}.")
          return target.merge(receiver: "self.#{receiver.delete_prefix("#{current_receiver}.")}")
        end

        target
      end

      def current_receiver_name(stack)
        entry = stack.reverse.find { |item| item.is_a?(Hash) && item[:receiver] }
        entry && entry[:receiver]
      end

      def file_owner(file)
        base = File.basename(file.to_s, File.extname(file.to_s))
        base.empty? ? "(file)" : base
      end

      def node_key(node)
        [node.kind, node.start_byte, node.end_byte]
      rescue StandardError
        node.object_id
      end

      def ts_node?(node)
        node && node.respond_to?(:kind) && node.respond_to?(:children)
      end

      def span(node)
        [node.start_point.row + 1, node.start_point.column,
         node.end_point.row + 1, node.end_point.column]
      end

      def line(node)
        node.start_point.row + 1
      end

      def normalize_text(text)
        text.to_s.strip.gsub(/\s+/, " ")
      end
    end

    LanguageProfile = TreeSitterLanguageAdapter

	    LANGUAGE_PROFILES = {
	      ruby: RubySyntaxAdapter.new(
          language: :ruby,
          extensions: %w[.rb],
          lexicon: RUBY_LEXICON,
          package: "tree-sitter-ruby"
        ),
	      python: PythonSyntaxAdapter.new(
          language: :python,
          extensions: %w[.py .pyi],
          lexicon: PYTHON_LEXICON,
          package: "tree-sitter-python"
        ),
	      javascript: JavaScriptSyntaxAdapter.new(
          language: :javascript,
          extensions: %w[.js .jsx .mjs .cjs],
          lexicon: JAVASCRIPT_LEXICON,
          package: "tree-sitter-javascript"
        ),
	      typescript: JavaScriptSyntaxAdapter.new(
          language: :typescript,
          extensions: %w[.ts .tsx],
          lexicon: JAVASCRIPT_LEXICON,
          package: "tree-sitter-typescript"
        ),
	      go: GoSyntaxAdapter.new(
          language: :go,
          extensions: %w[.go],
          lexicon: GO_LEXICON,
          package: "tree-sitter-go"
        ),
	      rust: RustSyntaxAdapter.new(
          language: :rust,
          extensions: %w[.rs],
          lexicon: RUST_LEXICON,
          package: "tree-sitter-rust"
        ),
	      zig: ZigSyntaxAdapter.new(
          language: :zig,
          extensions: %w[.zig],
          lexicon: ZIG_LEXICON,
          package: "@tree-sitter-grammars/tree-sitter-zig"
        ),
	      lua: LuaSyntaxAdapter.new(
          language: :lua,
          extensions: %w[.lua],
          lexicon: LUA_LEXICON,
          package: "@tree-sitter-grammars/tree-sitter-lua"
        ),
	      c: CSyntaxAdapter.new(
          language: :c,
          extensions: %w[.c .h],
          lexicon: C_LEXICON,
          package: "tree-sitter-c",
          first_argument_receiver: true
        ),
	      cpp: CppSyntaxAdapter.new(
          language: :cpp,
          extensions: %w[.cc .cpp .cxx .hh .hpp .hxx],
          lexicon: CPP_LEXICON,
          package: "tree-sitter-cpp"
        ),
	      csharp: CSharpSyntaxAdapter.new(
          language: :csharp,
          extensions: %w[.cs],
          lexicon: CSHARP_LEXICON,
          package: "tree-sitter-c-sharp",
          grammar_names: %w[c-sharp csharp],
          tree_sitter_language_name: "c_sharp"
        ),
	      java: TreeSitterLanguageAdapter.new(
          language: :java,
          extensions: %w[.java],
          lexicon: JAVA_LEXICON,
          package: "tree-sitter-java"
        ),
	      swift: TreeSitterLanguageAdapter.new(
          language: :swift,
          extensions: %w[.swift],
          lexicon: SWIFT_LEXICON,
          package: "tree-sitter-swift"
        ),
	      kotlin: TreeSitterLanguageAdapter.new(
          language: :kotlin,
          extensions: %w[.kt .kts],
          lexicon: KOTLIN_LEXICON,
          package: "tree-sitter-kotlin"
        )
	    }.freeze

    LANGUAGE_BY_EXTENSION = LANGUAGE_PROFILES.values.each_with_object({}) do |profile, index|
      profile.extensions.each { |extension| index[extension] ||= profile.language }
    end.freeze

    module_function

    def parse(file, language: nil, parser: ENV.fetch("DECOMPLEX_PARSER", "tree_sitter"))
      normalized_parser = parser.to_s.tr("-", "_")
      lang = (language || language_for(file)).to_sym
      key = document_cache_key(file, lang, normalized_parser)
      document_cache.fetch(key) do
        document_cache[key] =
          case normalized_parser
          when "", "tree_sitter", "treesitter"
            TreeSitterAdapter.new.parse(file, language: lang)
          else
            raise ArgumentError, "unknown decomplex parser #{parser.inspect}"
          end
      end
    end

    def document_cache
      @document_cache ||= {}
    end

    def document_cache_key(file, language, parser)
      stat = File.stat(file)
      [File.expand_path(file), language, parser, stat.size, stat.mtime.to_f]
    end

    def parse_uncached(file, language: nil, parser: ENV.fetch("DECOMPLEX_PARSER", "tree_sitter"))
      case parser.to_s.tr("-", "_")
      when "", "tree_sitter", "treesitter"
        TreeSitterAdapter.new.parse(file, language: language)
      else
        raise ArgumentError, "unknown decomplex parser #{parser.inspect}"
      end
    end

    def parser
      ENV.fetch("DECOMPLEX_PARSER", "tree_sitter").to_s.tr("-", "_")
    end

    def tree_sitter?
      %w[tree_sitter treesitter].include?(parser)
    end

	    def language_for(file)
	      forced = ENV["DECOMPLEX_FORCE_LANGUAGE"].to_s.strip
	      return forced.tr("-", "_").to_sym unless forced.empty?

        LANGUAGE_BY_EXTENSION.fetch(File.extname(file).downcase, :ruby)
	    end

    def supported_exts(parser: self.parser)
	      case parser.to_s.tr("-", "_")
	      when "", "tree_sitter", "treesitter"
	        LANGUAGE_PROFILES.values.flat_map(&:extensions).uniq
	      else
	        []
	      end
    end

    def supported_source?(file, parser: self.parser)
      supported_exts(parser: parser).include?(File.extname(file).downcase)
    end

    def language_lexicon(language)
      language_profile(language).lexicon
    end

    def language_profile(language)
      key = language.to_s.empty? ? nil : language.to_sym
      raise ArgumentError, "missing Syntax language profile" unless key

      LANGUAGE_PROFILES.fetch(key)
    rescue KeyError
      raise ArgumentError, "unsupported Syntax language profile: #{language.inspect}"
    end

    class Document
      attr_reader :file, :language, :source, :lines, :root, :adapter

      def initialize(file:, language:, source:, lines:, root:, adapter:)
        @file = file
        @language = language
        @source = source
        @lines = lines
        @tree_sitter_facade = TreeSitterFacadeContext.new(root)
        @root = @tree_sitter_facade.root
        @adapter = adapter
      end

      def decision_sites
        @decision_sites ||= adapter.decision_sites(self)
      end

      def state_writes
        @state_writes ||= adapter.state_writes(self)
      end

      def state_reads
        @state_reads ||= adapter.state_reads(self)
      end

      def branch_decisions(immutable_readers:, immutable_reader_types:, type_aliases:)
        adapter.branch_decisions(
          self,
          immutable_readers: immutable_readers,
          immutable_reader_types: immutable_reader_types,
          type_aliases: type_aliases
        )
      end

      def function_defs
        @function_defs ||= adapter.function_defs(self)
      end

      def owner_defs
        @owner_defs ||= adapter.owner_defs(self)
      end

      def call_sites
        @call_sites ||= adapter.call_sites(self)
      end

      def state_declarations
        @state_declarations ||= adapter.state_declarations(self)
      end

      def state_param_origins
        @state_param_origins ||= adapter.state_param_origins(self)
      end

      def branch_arms
        @branch_arms ||= adapter.branch_arms(self)
      end

      def predicate_defs
        @predicate_defs ||= adapter.predicate_defs(self)
      end

      def comparison_sites
        @comparison_sites ||= adapter.comparison_sites(self)
      end

      def local_methods
        @local_methods ||= adapter.local_methods(self)
      end

      def path_condition_sites
        @path_condition_sites ||= adapter.path_condition_sites(self)
      end

      def immutable_struct_readers
        adapter.immutable_struct_readers(lines)
      end

      def immutable_struct_reader_types
        adapter.immutable_struct_reader_types(lines)
      end

      def type_aliases
        adapter.type_aliases(lines)
      end
    end

    module SourceTextHelpers
      module_function

      def immutable_struct_readers(lines)
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

      def immutable_struct_reader_types(lines)
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

      def type_aliases(lines)
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
    end

    class TreeSitterFacadeContext
      attr_reader :root

      def initialize(raw_root)
        @wrappers = {}
        @children_cache = {}
        @named_children_cache = {}
        @named_field_cache = {}
        @parent_cache = {}
        @prev_sibling_cache = {}
        @next_sibling_cache = {}
        @prev_named_sibling_cache = {}
        @next_named_sibling_cache = {}
        @root = wrap(raw_root)
        index_tree(raw_root)
      end

      def wrap(raw)
        return nil unless raw
        return raw if raw.is_a?(TreeSitterNodeFacade)

        key = node_key(raw)
        @wrappers[key] ||= TreeSitterNodeFacade.new(self, raw, key)
      end

      def children(raw)
        node = unwrap(raw)
        @children_cache.fetch(node_key(node)) { [] }
      end

      def named_children(raw)
        node = unwrap(raw)
        @named_children_cache.fetch(node_key(node)) { [] }
      end

      def child_by_field_name(raw, name)
        node = unwrap(raw)
        key = [node_key(node), name.to_s]
        return @named_field_cache[key] if @named_field_cache.key?(key)

        @named_field_cache[key] = wrap(node.child_by_field_name(name))
      rescue StandardError
        nil
      end

      def parent(raw)
        @parent_cache[node_key(unwrap(raw))]
      end

      def prev_sibling(raw)
        @prev_sibling_cache[node_key(unwrap(raw))]
      end

      def next_sibling(raw)
        @next_sibling_cache[node_key(unwrap(raw))]
      end

      def prev_named_sibling(raw)
        @prev_named_sibling_cache[node_key(unwrap(raw))]
      end

      def next_named_sibling(raw)
        @next_named_sibling_cache[node_key(unwrap(raw))]
      end

      def node_key(raw)
        node = unwrap(raw)
        [node.kind, node.start_byte, node.end_byte, node.named?]
      end

      private

      def unwrap(raw)
        raw.is_a?(TreeSitterNodeFacade) ? raw.raw : raw
      end

      def index_tree(raw_root)
        pending = [raw_root]
        until pending.empty?
          raw = pending.pop
          key = node_key(raw)
          raw_children = Array(raw.children)
          wrapped_children = raw_children.map { |child| wrap(child) }
          @children_cache[key] = wrapped_children
          @named_children_cache[key] = wrapped_children.select(&:named?)

          raw_children.each do |child|
            child_key = node_key(child)
            @parent_cache[child_key] = wrap(raw)
          end

          index_siblings(raw_children, @prev_sibling_cache, @next_sibling_cache)
          index_siblings(raw_children.select(&:named?), @prev_named_sibling_cache, @next_named_sibling_cache)

          pending.concat(raw_children.reverse)
        end
      end

      def index_siblings(raw_children, prev_cache, next_cache)
        raw_children.each_with_index do |child, index|
          key = node_key(child)
          prev_cache[key] = wrap(raw_children[index - 1]) if index.positive?
          next_cache[key] = wrap(raw_children[index + 1]) if index + 1 < raw_children.length
        end
      end
    end

    class TreeSitterNodeFacade
      attr_reader :context, :raw

      def initialize(context, raw, key)
        @context = context
        @raw = raw
        @key = key
      end

      def kind
        @kind ||= raw.kind
      end

      def text
        @text ||= raw.text.to_s
      end

      def start_byte
        raw.start_byte
      end

      def end_byte
        raw.end_byte
      end

      def start_point
        raw.start_point
      end

      def end_point
        raw.end_point
      end

      def named?
        raw.named?
      end

      def has_error?
        raw.respond_to?(:has_error?) && raw.has_error?
      end

      def children
        context.children(self)
      end

      def child_count
        children.length
      end

      def named_children
        context.named_children(self)
      end

      def named_child_count
        named_children.length
      end

      def child_by_field_name(name)
        context.child_by_field_name(self, name)
      end

      def parent
        context.parent(self)
      end

      def prev_sibling
        context.prev_sibling(self)
      end

      def next_sibling
        context.next_sibling(self)
      end

      def prev_named_sibling
        context.prev_named_sibling(self)
      end

      def next_named_sibling
        context.next_named_sibling(self)
      end

      def ==(other)
        other = other.raw if other.is_a?(TreeSitterNodeFacade)
        other.respond_to?(:kind) &&
          kind == other.kind &&
          start_byte == other.start_byte &&
          end_byte == other.end_byte &&
          named? == other.named?
      end

      alias eql? ==

      def hash
        @key.hash
      end

      def inspect
        "#<#{self.class} kind=#{kind.inspect} start_byte=#{start_byte} end_byte=#{end_byte}>"
      end
    end

    class TreeSitterAdapter
      def self.walk_document(document, stack, profile, &block)
        node = document.root
        return unless tree_sitter_node?(node)

        pending = [[node, stack]]
        seen = Set.new
        until pending.empty?
          current, current_stack = pending.pop
          next unless tree_sitter_node?(current)
          key = node_key(current)
          next if seen.include?(key)

          seen << key

          next_stack = profile.push_context(document, current_stack, current)
          yield current, next_stack
          current.children.reverse_each { |child| pending << [child, next_stack] }
        end
      end

      def self.tree_sitter_node?(node)
        node && node.respond_to?(:kind) && node.respond_to?(:children)
      end

      def self.node_key(node)
        [node.kind, node.start_byte, node.end_byte]
      rescue StandardError
        node.object_id
      end

      def parse(file, language: nil)
        lang = (language || Syntax.language_for(file)).to_sym
        source = File.read(file)
        parser = parser_for(lang)
        tree = parser.parse(source)
        raise "tree-sitter parse timed out for #{file}" unless tree

        Document.new(
          file: file,
          language: lang,
          source: source,
          lines: source.lines,
          root: tree.root_node,
          adapter: self
        )
      end

      def decision_sites(document)
        profile = syntax_profile(document.language)
        out = []
        walk(document, profile) do |node, stack|
          out.concat(profile.decision_site_facts(document, node, stack))
        end
        out
      end

      def state_writes(document)
        structural_facts(document).fetch(:state_writes)
      end

      def state_reads(document)
        structural_facts(document).fetch(:state_reads)
      end

      def branch_decisions(document, immutable_readers:, immutable_reader_types:, type_aliases:)
        profile = syntax_profile(document.language)
        out = []
        walk(document, profile) do |node, stack|
          out.concat(profile.branch_decision_facts(
            document,
            node,
            stack,
            immutable_readers: immutable_readers,
            immutable_reader_types: immutable_reader_types,
            type_aliases: type_aliases
          ))
        end
        out
      end

      def function_defs(document)
        structural_facts(document).fetch(:function_defs)
      end

      def owner_defs(document)
        structural_facts(document).fetch(:owner_defs)
      end

      def call_sites(document)
        structural_facts(document).fetch(:call_sites)
      end

      def state_declarations(document)
        structural_facts(document).fetch(:state_declarations)
      end

      def state_param_origins(document)
        structural_facts(document).fetch(:state_param_origins)
      end

      def structural_facts(document)
        @structural_fact_cache ||= {}
        @structural_fact_cache[document.object_id] ||= begin
          profile = syntax_profile(document.language)
          out = {
            function_defs: [],
            owner_defs: [],
            call_sites: [],
            state_declarations: [],
            state_param_origins: [],
            state_reads: [],
            state_writes: []
          }
          walk(document, profile) do |node, stack|
            facts = profile.structural_facts_for_node(document, node, stack)
            facts.each do |key, values|
              out.fetch(key).concat(values)
            end
          end
          profile.after_structural_facts(document, out)
          out[:function_defs].uniq! { |fn| [fn.file, fn.owner, fn.name, fn.line] }
          out[:owner_defs].uniq! { |owner| [owner.file, owner.name, owner.kind] }
          out[:call_sites].uniq! { |call| [call.file, call.owner, call.function, call.span, call.receiver, call.message] }
          out[:state_declarations].uniq! { |decl| [decl.file, decl.owner, decl.field] }
          out[:state_param_origins].uniq! { |origin| [origin.file, origin.owner, origin.function, origin.field, origin.param] }
          out[:state_reads].uniq! { |read| [read.file, read.owner, read.function, read.span, read.receiver, read.field] }
          out[:state_writes].uniq! { |write| [write.file, write.owner, write.function, write.span, write.receiver, write.field] }
          out
        end
      end

      def branch_arms(document)
        profile = syntax_profile(document.language)
        out = []
        walk(document, profile) do |node, stack|
          out.concat(profile.branch_arm_facts(document, node, stack))
        end
        out
      end

      def predicate_defs(document)
        profile = syntax_profile(document.language)
        document.function_defs.filter_map { |function_def| profile.predicate_def(document, function_def) }
      end

      def comparison_sites(document)
        profile = syntax_profile(document.language)
        out = []
        walk(document, profile) do |node, stack|
          out.concat(profile.comparison_site_facts(document, node, stack))
        end
        out
      end

      def local_methods(document)
        syntax_profile(document.language).local_methods(document)
      end

      def path_condition_sites(document)
        syntax_profile(document.language).path_condition_sites(document)
      end

      def immutable_struct_readers(lines)
        SourceTextHelpers.immutable_struct_readers(lines)
      end

      def immutable_struct_reader_types(lines)
        SourceTextHelpers.immutable_struct_reader_types(lines)
      end

      def type_aliases(lines)
        SourceTextHelpers.type_aliases(lines)
      end

      private

      def syntax_profile(language)
        raise ArgumentError, "missing Syntax language profile context" if language.nil?

        Syntax.language_profile(language)
      end

	      def parser_for(language)
	        require_tree_sitter
	        lang_name = Syntax.language_profile(language).tree_sitter_language_name
	        register_language(lang_name, grammar_path(language))
	        ::TreeSitter::Parser.new.tap { |parser| parser.language = lang_name }
	      end

      def require_tree_sitter
        gem "tree_sitter", "~> 0.1"
        require "tree_sitter"
      rescue Gem::LoadError, LoadError => e
        raise LoadError, "DECOMPLEX_PARSER=tree_sitter requires the tree_sitter gem: #{e.message}"
      end

      def register_language(name, path)
        @registered ||= {}
        return if @registered[name]

        ::TreeSitter.register_language(name, path)
        @registered[name] = true
      end

      def grammar_path(language)
        env_name = "DECOMPLEX_TS_#{language.to_s.upcase}_PATH"
        return ENV.fetch(env_name) if ENV[env_name] && File.file?(ENV[env_name])

        candidates = grammar_candidates(language)
        found = candidates.find { |path| File.file?(path) }
        return found if found

        raise LoadError,
              "missing Tree-sitter grammar for #{language}. Set #{env_name} " \
              "to a parser shared library (.so/.dylib/.node). Checked: #{candidates.join(', ')}"
      end

	      def grammar_candidates(language)
	        profile = Syntax.language_profile(language)
	        pkg = profile.package
	        stems = profile.grammar_names
	        names = stems.flat_map do |stem|
	          ["#{stem}.so", "tree-sitter-#{stem}.so",
	           "libtree-sitter-#{stem}.so", "#{stem}.node",
	           "tree-sitter-#{stem}.node",
	           "#{stem}_binding.node",
	           "tree_sitter_#{stem.tr('-', '_')}_binding.node",
	           "@tree-sitter-grammars+tree-sitter-#{stem}.node"]
	        end
	        roots = [
	          File.expand_path("../../vendor/tree-sitter", __dir__),
	          File.expand_path("../../vendor/tree-sitter/#{language}", __dir__),
          File.expand_path("../../node_modules/#{pkg}", __dir__),
          File.expand_path("../../node_modules/#{pkg}/build/Release", __dir__),
          File.expand_path("../../../../node_modules/#{pkg}", __dir__),
          File.expand_path("../../../../node_modules/#{pkg}/build/Release", __dir__),
          File.expand_path("../../../../../node_modules/#{pkg}", __dir__),
          File.expand_path("../../../../../node_modules/#{pkg}/build/Release", __dir__)
	        ]
	        all_prebuilds = roots.flat_map do |root|
	          stems.flat_map do |stem|
	            Dir.glob(File.join(root, "prebuilds", "*", "*tree-sitter-#{stem}.node"))
	          end
	        end
        prebuilds = platform_prebuilds(all_prebuilds)
        roots.product(names).map { |root, name| File.join(root, name) } + prebuilds
      end

      def platform_prebuilds(paths)
        os = host_os
        arch = host_arch
        return paths if os.nil? || arch.nil?

        paths.select { |path| path.include?("/#{os}-#{arch}/") }
      end

      def host_os
        case RbConfig::CONFIG["host_os"]
        when /linux/i then "linux"
        when /darwin/i then "darwin"
        when /mswin|mingw|cygwin/i then "win32"
        end
      end

      def host_arch
        case RbConfig::CONFIG["host_cpu"]
        when /x86_64|amd64/i then "x64"
        when /aarch64|arm64/i then "arm64"
        end
      end

      def walk(document, profile, &block)
        self.class.walk_document(document, profile.initial_stack(document), profile, &block)
      end

    end

  end
end

require_relative "syntax/ruby"
require_relative "syntax/effects"
require_relative "syntax/protocols"
