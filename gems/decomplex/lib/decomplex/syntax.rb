# frozen_string_literal: true

require "set"
require_relative "ast"

module Decomplex
  module Syntax
    FunctionDef = Struct.new(:file, :name, :owner, :line, :span, :body, :visibility, keyword_init: true)
    DecisionSite = Struct.new(:kind, :members, :file, :function, :line, :span, :predicate, keyword_init: true)
    StateRead = Struct.new(:field, :receiver, :file, :function, :line, :span, keyword_init: true)
    StateWrite = Struct.new(:field, :receiver, :file, :function, :line, :span, keyword_init: true)
    BranchDecision = Struct.new(:file, :function, :line, :span, :predicate, :state_refs, keyword_init: true)
    BranchArm = Struct.new(:file, :function, :kind, :line, :span,
                           :decision_line, :decision_span, :predicate,
                           :member, :body, keyword_init: true)

    module_function

    def parse(file, language: nil, parser: ENV.fetch("DECOMPLEX_PARSER", "rubyvm"))
      case parser.to_s.tr("-", "_")
      when "", "rubyvm", "ruby_vm"
        RubyVMAdapter.new.parse(file, language: language)
      when "tree_sitter", "treesitter"
        TreeSitterAdapter.new.parse(file, language: language)
      else
        raise ArgumentError, "unknown decomplex parser #{parser.inspect}"
      end
    end

    def parser
      ENV.fetch("DECOMPLEX_PARSER", "rubyvm").to_s.tr("-", "_")
    end

    def tree_sitter?
      %w[tree_sitter treesitter].include?(parser)
    end

    def language_for(file)
      case File.extname(file).downcase
      when ".rb" then :ruby
      when ".py" then :python
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
      when "tree_sitter", "treesitter"
        %w[.rb .py .js .jsx .mjs .cjs .ts .tsx .go .rs .zig]
      else
        %w[.rb]
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
        out = []
        walk(document.root, []) do |node, stack|
          record_state_write(document, node, stack, out)
        end
        out.uniq { |write| [write.file, write.function, write.line, write.receiver, write.field] }
      end

      def state_reads(document)
        out = []
        walk(document.root, []) do |node, stack|
          record_state_read(document, node, stack, out)
        end
        out
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
            type_aliases: type_aliases
          )
        end
        out
      end

      def function_defs(document)
        out = []
        walk(document.root, []) do |node, _stack|
          name = function_name(node)
          next unless name

          out << FunctionDef.new(
            file: document.file,
            name: name,
            owner: nil,
            line: line(node),
            span: span(node),
            body: node,
            visibility: nil
          )
        end
        out
      end

      def branch_arms(document)
        out = []
        walk(document.root, []) do |node, stack|
          record_branch_arm(document, node, stack, out)
        end
        out
      end

      def immutable_struct_readers(lines)
        RubyVMAdapter.new.immutable_struct_readers(lines)
      end

      def immutable_struct_reader_types(lines)
        RubyVMAdapter.new.immutable_struct_reader_types(lines)
      end

      def type_aliases(lines)
        RubyVMAdapter.new.type_aliases(lines)
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

        stack = push_function(stack, node)
        yield node, stack
        node.children.each { |child| walk(child, stack, &block) }
      end

      def push_function(stack, node)
        name = function_name(node)
        name ? stack + [name] : stack
      end

      def current_function(stack)
        stack.last || "(top-level)"
      end

      def function_name(node)
        case node.kind
        when "method", "function_definition", "function_declaration",
             "method_definition", "function_item"
          named_field(node, "name")&.text || first_named_text(node, %w[identifier constant property_identifier])
        when "method_declaration"
          named_field(node, "name")&.text || first_named_text(node, %w[field_identifier identifier])
        end
      end

      def record_decision_site(document, node, stack, out)
        case node.kind
        when "case", "switch_statement", "expression_switch_statement", "switch_expression",
             "match_statement", "match_expression"
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
        when "binary", "binary_expression", "boolean_operator"
          return unless boolean_and?(node)
          return if ts_node?(node.parent) &&
                    %w[binary binary_expression boolean_operator].include?(node.parent.kind) &&
                    boolean_and?(node.parent)

          members = flatten_boolean_and(node).map { |child| normalize_text(child.text) }.uniq.sort
          return if members.size < 2

          out << DecisionSite.new(
            kind: :conjunction,
            members: members,
            file: document.file,
            function: current_function(stack),
            line: line(node),
            span: span(node),
            predicate: normalize_text(node.text)
          )
        end
      end

      def case_patterns(node)
        case_arms(node).filter_map do |child|
          normalized = case_arm_pattern(child)
          normalized unless default_case_pattern?(normalized)
        end.uniq.sort
      end

      def case_arm_pattern(child)
        case child.kind
        when "when", "match_arm"
          pattern = named_field(child, "pattern") || child.named_children.first
          normalize_text(pattern.text) if pattern
        when "switch_case", "case_clause", "expression_case"
          return nil if child.text.to_s.lstrip.start_with?("else")

          value = named_field(child, "value") || child.named_children.first
          normalize_text(value.text) if value && value.kind !~ /statement|block/
        end
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
        target = named_field(node, "value") || named_field(node, "subject") ||
                 named_field(node, "condition") ||
                 node.named_children.find do |child|
                   !%w[when switch_case case_clause expression_case match_arm].include?(child.kind)
                 end
        normalize_text(target ? target.text : node.text)
      end

      def default_case_pattern?(text)
        text.nil? || %w[_ default].include?(text)
      end

      def boolean_and?(node)
        node.text.include?("&&") || node.text.match?(/\band\b/)
      end

      def flatten_boolean_and(node)
        return [node] unless ts_node?(node) &&
                             %w[binary binary_expression boolean_operator].include?(node.kind) &&
                             boolean_and?(node)

        node.named_children.flat_map { |child| flatten_boolean_and(child) }
      end

      def record_state_write(document, node, stack, out)
        lhs =
          if %w[assignment assignment_expression augmented_assignment assignment_statement].include?(node.kind)
            named_field(node, "left") || node.named_children.first
          elsif assignment_lhs?(node)
            node
          end
        return unless lhs

        target = state_target(lhs)
        return unless target
        return if target[:field] == "[]"

        out << StateWrite.new(
          field: target[:field],
          receiver: target[:receiver],
          file: document.file,
          function: current_function(stack),
          line: line(node),
          span: span(node)
        )
      end

      def record_state_read(document, node, stack, out)
        target = state_read_target(node)
        return unless target

        out << StateRead.new(
          field: target[:field],
          receiver: target[:receiver],
          file: document.file,
          function: current_function(stack),
          line: line(node),
          span: span(node)
        )
      end

      def record_branch_decision(document, node, stack, out, immutable_readers:, immutable_reader_types:, type_aliases:)
        return unless branch_node?(node)

        cond = named_field(node, "condition") || named_field(node, "value") ||
               named_field(node, "subject") || node.named_children.first
        return unless cond

        refs = []
        collect_state_refs(cond, refs)
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
        when "case", "switch_statement", "expression_switch_statement", "switch_expression",
             "match_statement", "match_expression"
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
        BRANCH_KINDS.include?(node.kind) || hidden_match?(node) || hidden_if?(node)
      end

      def if_node?(node)
        %w[if unless if_statement if_expression if_modifier unless_modifier].include?(node.kind) ||
          hidden_if?(node)
      end

      def hidden_if?(node)
        return false unless ts_node?(node)
        return false unless node.text.to_s.lstrip.start_with?("if ")

        first = node.children.find { |child| child.text.to_s.strip != "" }
        first&.kind == "if"
      end

      def collect_state_refs(node, refs)
        if node.kind == "instance_variable" || node.kind == "global_variable"
          refs << node.text
        elsif (target = state_read_target(node))
          unless namespace_receiver?(target[:receiver])
            refs << (target[:receiver] == "self" ? target[:field] : "#{target[:receiver]}.#{target[:field]}")
          end
        end
        node.children.each { |child| collect_state_refs(child, refs) if ts_node?(child) }
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
          return nil unless object && field

          { receiver: normalize_text(object.text), field: field.text.sub(/=\z/, "") }
        when "instance_variable", "global_variable"
          { receiver: "self", field: lhs.text }
        end
      end

      def hidden_match?(node)
        node.kind == "expression_statement" &&
          node.text.to_s.lstrip.start_with?("match ") &&
          node.named_children.any? { |child| child.kind == "match_block" }
      end

      def assignment_lhs?(node)
        return false if prev_sibling(node)&.text == ":"

        sibling = next_sibling(node)
        sibling && %w[= += -= *= /= %= &&= ||=].include?(sibling.text.to_s)
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

      def first_named_text(node, kinds)
        child = node.named_children.find { |c| kinds.include?(c.kind) }
        child&.text
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

    class RubyVMAdapter
      BRANCH_TYPES = %i[IF UNLESS WHILE UNTIL].freeze
      NOISE_MIDS = %i[! != == === < <= > >= [] []= to_s inspect class].freeze

      def parse(file, language: nil)
        source = File.read(file)
        root = RubyVM::AbstractSyntaxTree.parse(source, keep_script_lines: true)
        Document.new(
          file: file,
          language: language || :ruby,
          source: source,
          lines: source.lines,
          root: root,
          adapter: self
        )
      end

      def decision_sites(document)
        sites = []
        walk_decisions(document.root, [], nil, sites, document)
        sites
      end

      def state_writes(document)
        writes = []
        walk_state_writes(document.root, [], writes, document)
        writes
      end

      def state_reads(document)
        reads = []
        walk_state_reads(document.root, [], reads, document)
        reads
      end

      def branch_decisions(document, immutable_readers:, immutable_reader_types:, type_aliases:)
        scanner = BranchScanner.new(
          document,
          immutable_readers: immutable_readers,
          immutable_reader_types: immutable_reader_types,
          type_aliases: type_aliases
        )
        scanner.scan
      end

      def function_defs(_document)
        []
      end

      def branch_arms(_document)
        []
      end

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

      private

      def walk_decisions(node, defstack, parent_type, sites, document)
        return unless Ast.node?(node)

        case node.type
        when :DEFN then defstack = defstack + [node.children[0].to_s]
        when :DEFS then defstack = defstack + [node.children[1].to_s]
        when :CASE then record_case(node, defstack, sites, document)
        when :AND
          record_conjunction(node, defstack, sites, document) unless parent_type == :AND
        end

        node.children.each { |child| walk_decisions(child, defstack, node.type, sites, document) }
      end

      def record_case(node, defstack, sites, document)
        pred = node.children[0]
        return unless pred

        pats = []
        whenn = node.children[1]
        while Ast.node?(whenn) && whenn.type == :WHEN
          plist = whenn.children[0]
          if Ast.node?(plist)
            plist.children.each do |pattern|
              pats << Ast.slice(pattern, document.lines) if Ast.node?(pattern)
            end
          end
          whenn = whenn.children[2]
        end
        pats = pats.compact.uniq.sort
        return if pats.size < 2

        sites << DecisionSite.new(
          kind: :case_dispatch,
          members: pats,
          file: document.file,
          function: current_function(defstack),
          line: node.first_lineno,
          span: span(node),
          predicate: Ast.slice(pred, document.lines)
        )
      end

      def record_conjunction(node, defstack, sites, document)
        operands = Ast.flatten_and(node).map { |operand| Ast.slice(operand, document.lines) }.compact.uniq.sort
        return if operands.size < 2

        sites << DecisionSite.new(
          kind: :conjunction,
          members: operands,
          file: document.file,
          function: current_function(defstack),
          line: node.first_lineno,
          span: span(node),
          predicate: Ast.slice(node, document.lines)
        )
      end

      def walk_state_writes(node, defstack, writes, document)
        return unless Ast.node?(node)

        case node.type
        when :DEFN then defstack += [node.children[0].to_s]
        when :DEFS then defstack += [node.children[1].to_s]
        when :ATTRASGN
          recv, msg, = node.children
          if msg == :[]=
            node.children.each { |child| walk_state_writes(child, defstack, writes, document) }
            return
          end

          writes << StateWrite.new(
            field: msg.to_s.sub(/=$/, ""),
            receiver: receiver_slice(recv, document),
            file: document.file,
            function: current_function(defstack),
            line: node.first_lineno,
            span: span(node)
          )
        when :IASGN
          writes << StateWrite.new(
            field: node.children[0].to_s,
            receiver: "self",
            file: document.file,
            function: current_function(defstack),
            line: node.first_lineno,
            span: span(node)
          )
        end

        node.children.each { |child| walk_state_writes(child, defstack, writes, document) }
      end

      def walk_state_reads(node, defstack, reads, document)
        return unless Ast.node?(node)

        defstack = Ast.def_push(node, defstack)
        case node.type
        when :IVAR
          reads << StateRead.new(
            field: node.children[0].to_s,
            receiver: "self",
            file: document.file,
            function: current_function(defstack),
            line: node.first_lineno,
            span: span(node)
          )
        when :CALL, :QCALL, :OPCALL
          recv, mid, args = node.children
          if recv && !NOISE_MIDS.include?(mid) && (args.nil? || empty_arg_list?(args))
            reads << StateRead.new(
              field: mid.to_s,
              receiver: receiver_slice(recv, document),
              file: document.file,
              function: current_function(defstack),
              line: node.first_lineno,
              span: span(node)
            )
          end
        end

        node.children.each { |child| walk_state_reads(child, defstack, reads, document) }
      end

      def current_function(defstack)
        defstack.last || "(top-level)"
      end

      def receiver_slice(node, document)
        return "?" unless Ast.node?(node)

        Ast.slice(node, document.lines)
      end

      def span(node)
        [node.first_lineno, node.first_column, node.last_lineno, node.last_column]
      end

      def empty_arg_list?(args)
        Ast.node?(args) && args.type == :LIST && args.children.compact.empty?
      end

      class BranchScanner
        def initialize(document, immutable_readers:, immutable_reader_types:, type_aliases:)
          @document = document
          @immutable_readers = immutable_readers
          @immutable_reader_types = immutable_reader_types
          @type_aliases = type_aliases
          @method_param_types = method_param_types(document.lines)
        end

        def scan
          out = []
          walk(@document.root, [], out)
          out
        end

        private

        def walk(node, defstack, out)
          return unless Ast.node?(node)

          defstack = Ast.def_push(node, defstack)
          record_branch(node, defstack, out)
          node.children.each { |child| walk(child, defstack, out) }
        end

        def record_branch(node, defstack, out)
          cond =
            case node.type
            when *BRANCH_TYPES
              node.children[0]
            when :CASE
              node.children[0]
            end
          return unless Ast.node?(cond)

          refs = state_refs(cond, defstack.last || "(top-level)")
          return if refs.empty?

          out << BranchDecision.new(
            file: @document.file,
            function: defstack.last || "(top-level)",
            line: node.first_lineno,
            span: [node.first_lineno, node.first_column, node.last_lineno, node.last_column],
            predicate: Ast.slice(cond, @document.lines),
            state_refs: refs.uniq.sort
          )
        end

        def state_refs(node, defn)
          refs = []
          collect_state_refs(node, refs, defn)
          refs
        end

        def collect_state_refs(node, refs, defn)
          return unless Ast.node?(node)

          case node.type
          when :IVAR
            refs << node.children[0].to_s
          when :GVAR
            refs << node.children[0].to_s
          when :CALL, :QCALL, :OPCALL
            recv, mid, args = node.children
            refs << "#{Ast.slice(recv, @document.lines)}.#{mid}" if state_attr_read?(recv, mid, args, defn)
          end
          node.children.each { |child| collect_state_refs(child, refs, defn) }
        end

        def state_attr_read?(recv, mid, args, defn)
          return false unless recv
          return false if NOISE_MIDS.include?(mid)
          return false unless args.nil? || empty_arg_list?(args)
          return false if immutable_struct_const_read?(recv, mid, defn)

          true
        end

        def immutable_struct_const_read?(recv, mid, defn)
          owner_type = immutable_receiver_type(recv, defn)
          return false unless owner_type

          immutable_reader?(owner_type, mid)
        end

        def immutable_receiver_type(recv, defn)
          return false unless Ast.node?(recv)

          if %i[CALL QCALL OPCALL].include?(recv.type)
            recv_recv, recv_mid, recv_args = recv.children
            return immutable_reader_result_type(recv_recv, recv_mid, recv_args, defn)
          end
          return false unless recv.type == :LVAR

          param_types = @method_param_types[defn]
          return false unless param_types

          param_types[recv.children[0].to_s]
        end

        def immutable_reader?(type_name, mid)
          return false unless type_name

          resolved_type_name = resolve_type_alias(type_name)
          readers = if @immutable_readers.key?(resolved_type_name)
                      @immutable_readers[resolved_type_name]
                    else
                      @immutable_readers[resolved_type_name.split("::").last]
                    end
          readers&.include?(mid) || false
        end

        def immutable_reader_result_type(recv, mid, args, defn)
          return nil unless args.nil? || empty_arg_list?(args)

          owner_type = immutable_receiver_type(recv, defn)
          return nil unless owner_type

          resolved_type_name = resolve_type_alias(owner_type)
          reader_types = if @immutable_reader_types.key?(resolved_type_name)
                           @immutable_reader_types[resolved_type_name]
                         else
                           @immutable_reader_types[resolved_type_name.split("::").last]
                         end
          reader_types[mid]
        end

        def resolve_type_alias(type_name)
          seen = Set.new
          current = type_name
          loop do
            break current if seen.include?(current)

            seen.add(current)
            target = @type_aliases[current] || @type_aliases[current.split("::").last]
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

        def empty_arg_list?(args)
          Ast.node?(args) && args.type == :LIST && args.children.compact.empty?
        end
      end
    end
  end
end
