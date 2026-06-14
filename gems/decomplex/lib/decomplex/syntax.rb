# frozen_string_literal: true

require "set"
require_relative "ast"

module Decomplex
  module Syntax
    FunctionDef = Struct.new(:file, :name, :owner, :line, :span, :body, :visibility,
                             :params, :signature, :kind, keyword_init: true)
    OwnerDef = Struct.new(:file, :name, :kind, :line, :span, keyword_init: true)
    CallSite = Struct.new(:receiver, :message, :file, :function, :owner, :line, :span,
                          :conditional, :arguments, :control, keyword_init: true)
    StateDeclaration = Struct.new(:field, :owner, :type, :file, :line, :span, keyword_init: true)
    StateParamOrigin = Struct.new(:field, :receiver, :owner, :param, :file, :function,
                                  :line, :span, keyword_init: true)
    DecisionSite = Struct.new(:kind, :members, :file, :function, :line, :span, :predicate, keyword_init: true)
    StateRead = Struct.new(:field, :receiver, :file, :function, :line, :span, :owner, keyword_init: true)
    StateWrite = Struct.new(:field, :receiver, :file, :function, :line, :span, :owner, keyword_init: true)
    BranchDecision = Struct.new(:file, :function, :line, :span, :predicate, :state_refs, keyword_init: true)
    BranchArm = Struct.new(:file, :function, :kind, :line, :span,
                           :decision_line, :decision_span, :predicate,
                           :member, :body, keyword_init: true)

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
      case File.extname(file).downcase
      when ".rb" then :ruby
      when ".py", ".pyi" then :python
      when ".js", ".jsx", ".mjs", ".cjs" then :javascript
      when ".ts", ".tsx" then :typescript
      when ".go" then :go
      when ".rs" then :rust
      when ".zig" then :zig
      else :ruby
      end
    end

    def supported_exts(parser: self.parser)
      case parser.to_s.tr("-", "_")
      when "", "tree_sitter", "treesitter"
        %w[.rb .py .pyi .js .jsx .mjs .cjs .ts .tsx .go .rs .zig]
      else
        []
      end
    end

    def supported_source?(file, parser: self.parser)
      supported_exts(parser: parser).include?(File.extname(file).downcase)
    end

    class Document
      attr_reader :file, :language, :source, :lines, :root, :adapter

      def initialize(file:, language:, source:, lines:, root:, adapter:)
        @file = file
        @language = language
        @source = source
        @lines = lines
        @root = root
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

    class TreeSitterAdapter
      BRANCH_KINDS = %w[if unless if_statement if_modifier unless_modifier if_expression
                        while until while_statement for for_statement
                        case switch_statement expression_switch_statement switch_expression
                        match_statement match_expression].freeze
      NOISE_MESSAGES = %w[! != == === < <= > >= [] []= to_s inspect class].freeze
      LANGUAGE_PACKAGES = {
        ruby: "tree-sitter-ruby",
        python: "tree-sitter-python",
        javascript: "tree-sitter-javascript",
        typescript: "tree-sitter-typescript",
        go: "tree-sitter-go",
        rust: "tree-sitter-rust",
        zig: "@tree-sitter-grammars/tree-sitter-zig"
      }.freeze

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
        out = []
        walk(document.root, []) do |node, stack|
          record_decision_site(document, node, stack, out)
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
        out = []
        walk(document.root, []) do |node, stack|
          record_branch_decision(
            document,
            node,
            stack,
          out,
          immutable_readers: immutable_readers,
          immutable_reader_types: immutable_reader_types,
          type_aliases: type_aliases,
          method_param_types: method_param_types(document.lines)
        )
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
          out = {
            function_defs: [],
            owner_defs: [],
            call_sites: [],
            state_declarations: [],
            state_param_origins: [],
            state_reads: [],
            state_writes: []
          }
          walk(document.root, [{ file_owner: file_owner(document.file) }]) do |node, stack|
            record_function_def(document, node, stack, out[:function_defs])
            record_owner_def(document, node, stack, out[:owner_defs])
            record_call_site(document, node, stack, out[:call_sites])
            record_state_declaration(document, node, stack, out[:state_declarations])
            record_state_param_origin(document, node, stack, out[:state_param_origins])
            record_state_read(document, node, stack, out[:state_reads])
            record_state_write(document, node, stack, out[:state_writes])
          end
          out[:function_defs].uniq! { |fn| [fn.file, fn.owner, fn.name, fn.line] }
          out[:owner_defs].uniq! { |owner| [owner.file, owner.name, owner.kind] }
          out[:call_sites].uniq! { |call| [call.file, call.owner, call.function, call.line, call.receiver, call.message] }
          out[:state_declarations].uniq! { |decl| [decl.file, decl.owner, decl.field] }
          out[:state_param_origins].uniq! { |origin| [origin.file, origin.owner, origin.function, origin.field, origin.param] }
          out[:state_reads].uniq! { |read| [read.file, read.owner, read.function, read.line, read.receiver, read.field] }
          out[:state_writes].uniq! { |write| [write.file, write.owner, write.function, write.line, write.receiver, write.field] }
          out
        end
      end

      def branch_arms(document)
        out = []
        walk(document.root, []) do |node, stack|
          record_branch_arm(document, node, stack, out)
        end
        out
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

      def parser_for(language)
        require_tree_sitter
        lang_name = language.to_s
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
        pkg = LANGUAGE_PACKAGES.fetch(language)
        names = ["#{language}.so", "tree-sitter-#{language}.so",
                 "libtree-sitter-#{language}.so", "#{language}.node",
                 "tree-sitter-#{language}.node",
                 "@tree-sitter-grammars+tree-sitter-#{language}.node"]
        roots = [
          File.expand_path("../../vendor/tree-sitter", __dir__),
          File.expand_path("../../vendor/tree-sitter/#{language}", __dir__),
          File.expand_path("../../node_modules/#{pkg}", __dir__),
          File.expand_path("../../../../node_modules/#{pkg}", __dir__),
          File.expand_path("../../../../../node_modules/#{pkg}", __dir__)
        ]
        prebuilds = roots.flat_map do |root|
          Dir.glob(File.join(root, "prebuilds", "*", "*tree-sitter-#{language}.node"))
        end
        roots.product(names).map { |root, name| File.join(root, name) } + prebuilds
      end

      def walk(node, stack, &block)
        return unless ts_node?(node)

        stack = push_context(stack, node)
        yield node, stack
        node.children.each { |child| walk(child, stack, &block) }
      end

      def push_context(stack, node)
        next_stack = push_owner_context(stack, node)
        name = function_name(node)
        next_stack = name ? next_stack + [function_context(node, next_stack)] : next_stack
        control = control_context(node)
        control ? next_stack + [{ control: control }] : next_stack
      end

      def push_owner_context(stack, node)
        owner = owner_name_from_declaration(nil, node)
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
          receiver: function_receiver_name(node)
        }
      end

      def function_owner_name(node, stack)
        receiver_owner_name(node) || current_owner_from_stack(stack)
      end

      def function_name(node)
        case node.kind
        when "body_statement"
          hidden_ruby_method_name(node)
        when "method", "function_definition", "function_declaration",
             "method_definition", "function_item"
          named_field(node, "name")&.text || first_named_text(node, %w[identifier constant property_identifier])
        when "singleton_method"
          name = named_field(node, "name")&.text ||
                 node.named_children.reverse.find { |child| %w[identifier field_identifier property_identifier].include?(child.kind) }&.text
          name && "self.#{name}"
        when "argument_list"
          inline_def_name(node)
        when "method_declaration"
          named_field(node, "name")&.text || first_named_text(node, %w[field_identifier identifier])
        end
      end

      def function_kind(node, stack)
        return :method if owner_for_node(nil, node, stack: stack)

        :function
      end

      def visibility_for(node)
        return ruby_inline_def_visibility(node) if inline_def_argument_list?(node)
        return :public if node.children.any? { |child| child.text == "pub" }

        nil
      end

      def function_params(node)
        return hidden_ruby_method_params(node) if hidden_ruby_method_definition?(node)

        params = if node.kind == "method_declaration"
                   node.named_children.select { |child| child.kind == "parameter_list" }[1]
                 else
                   named_field(node, "parameters") ||
                     node.named_children.find { |child| %w[parameters formal_parameters parameter_list].include?(child.kind) }
                 end
        params ||= node.named_children.find { |child| child.kind == "method_parameters" } if inline_def_argument_list?(node)
        return [] unless params

        params.named_children.filter_map do |param|
          parameter_name(param)
        end.uniq
      end

      def parameter_name(param)
        return nil unless ts_node?(param)
        return param.text if %w[identifier shorthand_property_identifier_pattern].include?(param.kind)

        name = named_field(param, "name") ||
               param.named_children.find do |child|
                 %w[identifier field_identifier property_identifier].include?(child.kind)
               end
        text = name&.text.to_s
        return nil if text.empty? || text == "_"

        text
      end

      def function_signature(document, node)
        if hidden_ruby_method_definition?(node)
          return normalize_text(hidden_ruby_method_signature(document, node))
        end
        if document.language == :ruby
          signature = preceding_ruby_signature(document, node)
          return signature unless signature.empty?
        end

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

      def line_text(document, node)
        document.lines[line(node) - 1].to_s
      end

      def control_context(node)
        return :iterates if %w[while until while_statement for for_statement for_in_statement
                               loop_expression do_block].include?(node.kind)
        return :conditional if branch_node?(node)

        nil
      end

      def record_decision_site(document, node, stack, out)
        if boolean_container?(node) && boolean_and?(node)
          record_conjunction_decision(document, node, stack, out)
          return
        end

        case node.kind
        when "case", "switch_statement", "expression_switch_statement", "switch_expression",
             "match_statement", "match_expression"
          return if ruby_predicate_less_case?(node)

          patterns = case_patterns(node)
          return if patterns.size < 2

          out << DecisionSite.new(
            kind: :case_dispatch,
            members: patterns,
            file: document.file,
            function: current_function(stack),
            line: line(node),
            span: span(node),
            predicate: decision_predicate(node)
          )
        when "body_statement", "block_body", "argument_list"
          return unless hidden_case?(node)
          return if node.named_children.any? { |child| child.kind == "case" }
          return if ruby_predicate_less_case?(node)

          patterns = case_patterns(node)
          return if patterns.size < 2

          out << DecisionSite.new(
            kind: :case_dispatch,
            members: patterns,
            file: document.file,
            function: current_function(stack),
            line: line(node),
            span: span(node),
            predicate: decision_predicate(node)
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
            predicate: decision_predicate(node)
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
          predicate: normalize_text(node.text)
        )
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
          visibility: visibility_for(node),
          params: function_params(node),
          signature: function_signature(document, node),
          kind: function_kind(node, stack)
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

        out << CallSite.new(
          receiver: target[:receiver],
          message: target[:message],
          file: document.file,
          function: current_function(stack),
          owner: current_owner(document, stack),
          line: line(node),
          span: span(node),
          conditional: conditional_context?(stack),
          arguments: target[:arguments],
          control: current_control(stack)
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
          ruby_when_pattern_texts(patterns)
        when "switch_case", "case_clause", "expression_case"
          return [] if child.text.to_s.lstrip.start_with?("else")

          value = named_field(child, "value") || child.named_children.first
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

      def ruby_when_pattern_texts(patterns)
        return [] if patterns.empty?

        texts = patterns.map { |pattern| normalize_text(pattern.text) }
        return texts unless texts.any? { |text| text.start_with?("*") }

        out = []
        pending_plain = []
        texts.each_with_index do |text, index|
          splat = text.start_with?("*")
          if splat
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

          if %w[when switch_case case_clause expression_case match_arm].include?(child.kind)
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
        normalize_text(target ? target.text : node.text)
      end

      def decision_subject(node)
        named_field(node, "value") || named_field(node, "subject") ||
          named_field(node, "condition") ||
          node.named_children.find do |child|
            !%w[when switch_case case_clause expression_case match_arm else then comment].include?(child.kind)
          end
      end

      def ruby_predicate_less_case?(node)
        return false unless node.kind == "case" || hidden_case?(node)

        !decision_subject(node)
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
        return true if %w[binary binary_expression boolean_operator].include?(node.kind)
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
        ts_node?(node) && %w[parenthesized_statements parenthesized_expression].include?(node.kind) &&
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

      def record_state_write(document, node, stack, out)
        return if document.language == :ruby && node.kind == "operator_assignment"
        return if document.language == :ruby && assignment_lhs?(node) && next_sibling(node)&.text.to_s != "=" &&
                  !instance_variable_node?(node)

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
        return if target[:field] == "[]"
        return if document.language == :ruby && target[:field].to_s.start_with?("$")

        source_node = document.language == :ruby && assignment_lhs?(node) ? (parent_node(node) || node) : node
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
        if if_node?(node)
          record_if_arms(document, node, stack, out)
          return
        end

        case node.kind
        when "while", "until", "while_statement", "for", "for_statement"
          record_loop_arm(document, node, stack, out)
        when "case", "body_statement", "switch_statement", "expression_switch_statement", "switch_expression",
             "match_statement", "match_expression"
          return if node.kind == "body_statement" && !hidden_case?(node)

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

      def first_token_kind(node)
        node.children.first&.kind.to_s
      end

      def collect_state_refs(node, refs, defn:, immutable_readers:, immutable_reader_types:, type_aliases:,
                             method_param_types:)
        if node.kind == "instance_variable" || node.kind == "global_variable"
          refs << node.text
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

      def method_param_types(lines)
        types_by_method = {}
        pending_sig = +""
        lines.each do |line|
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

        out << node.text if node.kind == "identifier"
        node.children.each { |child| collect_identifiers(child, out) }
      end

      def owner_for_node(document, node, stack: nil)
        receiver_owner = receiver_owner_name(node)
        return receiver_owner if receiver_owner

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

      def owner_name_from_declaration(document, node)
        if hidden_ruby_owner_declaration?(node)
          return hidden_ruby_owner_name(node)
        end

        case node.kind
        when "class", "class_definition", "class_declaration", "module"
          named_field(node, "name")&.text || first_named_text(node, %w[constant identifier type_identifier])
        when "impl_item", "impl_block"
          impl_owner_name(node)
        when "struct_item", "struct_spec", "type_spec", "type_declaration"
          named_field(node, "name")&.text || first_named_text(node, %w[type_identifier identifier])
        when "struct_declaration", "union_declaration", "enum_declaration"
          bound_container_name(node) || returned_container_owner(node) || anonymous_owner_name(document, node)
        end
      end

      def owner_kind(node)
        return hidden_ruby_owner_kind(node) if hidden_ruby_owner_declaration?(node)

        case node.kind
        when "class", "class_definition", "class_declaration" then :class
        when "module" then :module
        when "impl_item", "impl_block" then :impl
        when "struct_declaration", "struct_item", "struct_spec" then :struct
        when "union_declaration" then :union
        when "enum_declaration" then :enum
        else :owner
        end
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

      def function_receiver_name(node)
        receiver_param = method_receiver_param_node(node)
        receiver_param&.text
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

      def returned_container_owner(node)
        parent = parent_node(node)
        seen_nodes = Set.new
        while parent && !seen_nodes.include?(node_key(parent))
          seen_nodes << node_key(parent)
          return function_name(parent) if function_name(parent)
          parent = parent_node(parent)
        end
        nil
      end

      def node_key(node)
        [node.kind, node.start_byte, node.end_byte]
      rescue StandardError
        node.object_id
      end

      def anonymous_owner_name(document, node)
        return nil unless document

        "#{file_owner(document.file)}::anonymous@#{line(node)}"
      end

      def file_owner(file)
        base = File.basename(file.to_s, File.extname(file.to_s))
        base.empty? ? "(file)" : base
      end

      def call_target(document, node)
        case node.kind
        when "call"
          ruby_call_target(node)
        when "body_statement"
          ruby_bare_body_call_target(document, node)
        when "identifier"
          ruby_bare_call_target(document, node)
        when "call_expression", "method_invocation", "invocation_expression"
          generic_call_target(node)
        when "attribute", "selector_expression", "field", "member_expression",
             "field_expression", "expression_list"
          adjacent_argument_call_target(node)
        end
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
          arguments: ruby_argument_texts(node)
        }
      end

      def ruby_bare_call_target(document, node)
        return nil unless document.language == :ruby
        return nil unless ruby_bare_call_identifier?(node)

        {
          receiver: "self",
          message: node.text,
          arguments: []
        }
      end

      def ruby_bare_body_call_target(document, node)
        return nil unless document.language == :ruby
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
        receiver, message = node.named_children
        return nil unless receiver && message
        return nil unless %w[self constant identifier].include?(receiver.kind)
        return nil unless %w[identifier constant].include?(message.kind)

        {
          receiver: normalize_text(receiver.text),
          message: message.text,
          arguments: []
        }
      end

      def ruby_simple_call_text?(text)
        text.to_s.strip.match?(/\A[a-z_]\w*[!?=]?\z/)
      end

      def generic_call_target(node)
        callee = named_field(node, "function") || named_field(node, "callee") || node.named_children.first
        return nil unless callee
        return nil if callee.kind == "builtin_function" || callee.text.to_s.start_with?("@")

        target_from_callee(callee).merge(arguments: [])
      rescue NoMethodError
        nil
      end

      def adjacent_argument_call_target(node)
        return nil unless next_sibling(node)&.kind == "argument_list"

        target_from_callee(node).merge(arguments: [])
      rescue NoMethodError
        nil
      end

      def target_from_callee(callee)
        if field_like_node?(callee)
          object = named_field(callee, "object") || named_field(callee, "receiver") ||
                   named_field(callee, "operand") || named_field(callee, "value") ||
                   callee.named_children.first
          field = named_field(callee, "field") || named_field(callee, "property") ||
                  callee.named_children.last
          return nil unless object && field

          {
            receiver: normalize_text(object.text).sub(/\A\*/, ""),
            message: field.text
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

      def state_declaration(node)
        case node.kind
        when "assignment"
          ruby_t_let_state_declaration(node)
        when "container_field"
          zig_container_field_declaration(node)
        when "property_declaration", "public_field_definition", "field_definition", "field_declaration"
          generic_field_declaration(node)
        else
          nil
        end
      end

      def zig_container_field_declaration(node)
        name = node.named_children.find { |child| child.kind == "identifier" }
        return nil unless name

        { field: name.text, type: declared_type_text(node, name) }
      end

      def generic_field_declaration(node)
        name = named_field(node, "name") ||
               node.named_children.find { |child| %w[identifier field_identifier property_identifier].include?(child.kind) }
        return nil unless name

        { field: name.text, type: declared_type_text(node, name) }
      end

      def declared_type_text(node, name_node)
        text = node.text.to_s
        after_name = text[(name_node.end_byte - node.start_byte)..].to_s
        if (match = after_name.match(/\A\s*:\s*([^=,\n]+)/))
          normalize_text(match[1])
        elsif (match = text.match(/\A\s*(?:pub\s+)?(?:const|var)\s+\w+\s*:\s*([^=;\n]+)/))
          normalize_text(match[1])
        end
      rescue StandardError
        nil
      end

      def state_read_target(node)
        case node.kind
        when "call"
          receiver = named_field(node, "receiver")
          method = named_field(node, "method")
          return nil unless receiver && method
          return nil if namespace_receiver?(receiver.text)
          return nil if NOISE_MESSAGES.include?(method.text)
          return nil if named_field(node, "arguments")

          { receiver: normalize_text(receiver.text), field: method.text }
        when "field", "selector_expression", "member_expression", "attribute",
             "field_expression", "expression_list"
          return nil if node.kind == "expression_list" && !(named_field(node, "operand") && named_field(node, "field"))

          object = named_field(node, "object") || named_field(node, "receiver") ||
                   named_field(node, "operand") || named_field(node, "value")
          field = named_field(node, "field") || named_field(node, "property") || node.named_children.last
          if node.kind == "field_expression" && node.text.to_s.start_with?(".")
            field = node.named_children.find { |child| child.kind == "identifier" } || field
            return { receiver: ".literal", field: field.text } if field
          end
          return nil unless object && field
          return nil if namespace_receiver?(object.text)
          return nil if NOISE_MESSAGES.include?(field.text)

          { receiver: normalize_text(object.text), field: field.text }
        when "instance_variable", "global_variable"
          { receiver: "self", field: node.text }
        end
      end

      def state_target(lhs)
        return nil unless ts_node?(lhs)
        return nil if prev_sibling(lhs)&.text == ":"

        case lhs.kind
        when "call"
          receiver = named_field(lhs, "receiver")
          method = named_field(lhs, "method")
          return nil unless receiver && method

          { receiver: normalize_text(receiver.text), field: method.text.sub(/=\z/, "") }
        when "field", "selector_expression", "member_expression", "attribute",
             "field_expression", "expression_list"
          if lhs.kind == "expression_list" && !(named_field(lhs, "operand") && named_field(lhs, "field"))
            return state_target(lhs.named_children.first)
          end

          object = named_field(lhs, "object") || named_field(lhs, "receiver") ||
                   named_field(lhs, "operand") || named_field(lhs, "value")
          field = named_field(lhs, "field") || named_field(lhs, "property") || lhs.named_children.last
          if lhs.kind == "field_expression" && lhs.text.to_s.start_with?(".")
            field = lhs.named_children.find { |child| child.kind == "identifier" } || field
            return { receiver: ".literal", field: field.text.sub(/=\z/, "") } if field
          end
          return nil unless object && field

          { receiver: normalize_text(object.text), field: field.text.sub(/=\z/, "") }
        when "instance_variable", "global_variable"
          { receiver: "self", field: lhs.text }
        end
      end

      def hidden_match?(node)
        node.kind == "expression_statement" &&
          first_token_kind(node) == "match" &&
          node.named_children.any? { |child| child.kind == "match_block" }
      end

      def assignment_lhs?(node)
        return false if prev_sibling(node)&.text == ":"

        sibling = next_sibling(node)
        sibling && %w[= += -= *= /= %= &&= ||=].include?(sibling.text.to_s)
      end

      def instance_variable_node?(node)
        ts_node?(node) && node.kind == "instance_variable"
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
        %w[field selector_expression member_expression attribute field_expression
           expression_list scoped_identifier].include?(node.kind)
      end

      def normalize_type_owner(text)
        value = text.to_s.strip
        value = value.sub(/\A[&*]+/, "")
        value = value.gsub(/\b(?:const|mut|var)\b/, "").strip
        value.split(/[({<\s]/).first.to_s.split(".").last
      end

      def first_named_text(node, kinds)
        child = node.named_children.find { |c| kinds.include?(c.kind) }
        child&.text
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

      def ruby_inline_def_visibility(node)
        parent = parent_node(node)
        return nil unless parent&.kind == "call"

        target = ruby_call_target(parent)
        visibility = target && target[:receiver] == "self" && target[:message]&.to_sym
        %i[private protected public].include?(visibility) ? visibility : nil
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

        %w[body_statement then else elsif ensure rescue].include?(parent.kind) ||
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

      def normalize_target_receiver(target, stack)
        receiver = target[:receiver].to_s
        current_receiver = current_receiver_name(stack)
        return target unless current_receiver && receiver == current_receiver

        target.merge(receiver: "self")
      end

      def current_receiver_name(stack)
        entry = stack.reverse.find { |item| item.is_a?(Hash) && item[:receiver] }
        entry && entry[:receiver]
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

  end
end
