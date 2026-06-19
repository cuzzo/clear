# typed: false
# frozen_string_literal: true

require "set"
require "pathname"

module Decomplex
  module NilKillStaticFacts
    module_function

    def build(document, structural_facts, root: NilKill::ROOT)
      Builder.new(document, structural_facts, root: root).build
    end

    class Builder
      def initialize(document, structural_facts, root: NilKill::ROOT)
        @document = document
        @facts = structural_facts
        @language = document.language.to_s
        @root = root
        @ts_node_cache = {}
      end

      def build
        state_declarations = normalized_state_declarations
        known_states = declared_states_by_owner(state_declarations)

        {
          methods: methods,
          fields: fields(state_declarations, known_states),
          state_types: state_types(state_declarations),
          state_type_records: state_type_records(state_declarations),
          state_protocols: state_protocols(known_states),
          state_param_origins: state_param_origins(known_states),
          state_protocol_records: state_protocol_records(known_states),
          state_param_origin_records: state_param_origin_records(known_states),
          signatures: signatures,
          type_definitions: type_definitions(state_declarations),
          hash_shapes: literal_shapes(:hash),
          array_shapes: literal_shapes(:array),
        }
      end

      private

      def methods
        Array(@facts[:function_defs]).map do |fn|
          signature = method_signature(fn)
          owner = method_owner(fn)
          {
            "key" => [owner, fn.name.to_s, fn.kind.to_s],
            "owner" => owner,
            "name" => fn.name.to_s,
            "kind" => fn.kind.to_s,
            "path" => rel(fn.file),
            "line" => fn.line,
            "span" => fn.span,
            "language" => @language,
            "signature" => signature,
            "params" => Array(fn.params).map(&:to_s),
            "source" => method_source(signature),
          }
        end
      end

      def fields(state_declarations, known_states)
        out = []
        seen = Set.new
        state_declarations.each do |state|
          field = declared_state_field(state.field)
          out << field_record(state, field, "state_declaration")
          seen.add(state_key(state.owner, field))
        end

        Array(@facts[:state_writes]).each do |write|
          next unless owned_state?(write, known_states[write.owner.to_s])

          field = canonical_state_field(write.field, receiver: write.receiver)
          key = state_key(write.owner, field)
          next if seen.include?(key)

          out << field_record(write, field, "state_write")
          seen.add(key)
        end
        out
      end

      def field_record(state, field, origin)
        {
          "id" => [@language, rel(state.file), state.owner, "field", field].map(&:to_s).join("\u0000"),
          "language" => @language,
          "path" => rel(state.file),
          "owner" => state.owner.to_s,
          "name" => field.to_s,
          "line" => state.line,
          "span" => state.span,
          "declared_type" => state.respond_to?(:type) && !state.type.to_s.empty? ? state.type.to_s : nil,
          "static_origin" => origin,
          "source" => "syntax",
        }
      end

      def state_types(state_declarations)
        state_declarations.each_with_object({}) do |state, out|
          type = state.type.to_s
          next if type.empty?

          out[state_key(state.owner, declared_state_field(state.field))] = type
        end
      end

      def state_type_records(state_declarations)
        state_declarations.filter_map do |state|
          type = state.type.to_s
          next if type.empty?

          field = declared_state_field(state.field)
          {
            "language" => @language,
            "path" => rel(state.file),
            "owner" => state.owner.to_s,
            "field" => field.to_s,
            "declared_type" => type,
            "line" => state.line,
            "span" => state.span,
            "key" => state_key(state.owner, field),
          }
        end.uniq do |record|
          [record["language"], record["path"], record["owner"],
            record["field"], record["declared_type"], record["line"]]
        end
      end

      def state_protocols(known_states)
        out = Hash.new { |hash, key| hash[key] = Set.new }
        Array(@facts[:call_sites]).each do |call|
          state = receiver_state_field(call.receiver, known_states[call.owner.to_s])
          next unless state

          out[state_key(call.owner, state)].add(call.message.to_s)
        end
        stringify_set_map(out)
      end

      def state_protocol_records(known_states)
        Array(@facts[:call_sites]).filter_map do |call|
          state = receiver_state_field(call.receiver, known_states[call.owner.to_s])
          next unless state

          {
            "language" => @language,
            "path" => rel(call.file),
            "owner" => call.owner.to_s,
            "function" => call.function.to_s,
            "field" => state.to_s,
            "protocol" => call.message.to_s,
            "line" => call.line,
            "span" => call.span,
            "key" => state_key(call.owner, state),
          }
        end.uniq do |record|
          [record["language"], record["path"], record["owner"], record["function"],
            record["field"], record["protocol"], record["line"]]
        end
      end

      def state_param_origins(known_states)
        out = Hash.new { |hash, key| hash[key] = Set.new }
        Array(@facts[:state_param_origins]).each do |origin|
          next unless owned_state?(origin, known_states[origin.owner.to_s])
          next if self_receiver_names.include?(origin.param.to_s)

          field = canonical_state_field(origin.field, receiver: origin.receiver)
          out[state_key(origin.owner, field)].add(origin.param.to_s)
        end
        stringify_set_map(out)
      end

      def state_param_origin_records(known_states)
        Array(@facts[:state_param_origins]).filter_map do |origin|
          next unless owned_state?(origin, known_states[origin.owner.to_s])
          next if self_receiver_names.include?(origin.param.to_s)

          field = canonical_state_field(origin.field, receiver: origin.receiver)
          {
            "language" => @language,
            "path" => rel(origin.file),
            "owner" => origin.owner.to_s,
            "function" => origin.function.to_s,
            "field" => field.to_s,
            "param" => origin.param.to_s,
            "line" => origin.line,
            "span" => origin.span,
            "key" => state_key(origin.owner, field),
          }
        end.uniq do |record|
          [record["language"], record["path"], record["owner"], record["function"],
            record["field"], record["param"], record["line"]]
        end
      end

      def signatures
        Array(@facts[:function_defs]).each_with_object({}) do |fn, out|
          signature = method_signature(fn)
          out[[method_owner(fn), fn.name.to_s].join("\u0000")] = signature unless signature.empty?
        end
      end

      def type_definitions(state_declarations)
        definitions = []
        Array(@facts[:function_defs]).each do |fn|
          definition = method_type_definition(fn)
          definitions << definition if definition
        end
        state_declarations.each do |state|
          definition = state_field_type_definition(state)
          definitions << definition if definition
        end
        definitions.concat(ruby_struct_new_type_definitions)
        definitions.concat(ruby_include_type_definitions)
        definitions.concat(ruby_type_alias_definitions)
        definitions.concat(python_stub_type_definitions)
        definitions.concat(python_type_alias_definitions)
        definitions.concat(typescript_interface_type_definitions)
        definitions.concat(typescript_type_alias_definitions)
        definitions
      end

      def literal_shapes(kind)
        shapes = []
        walk_tree(@document.root) do |node|
          shape = kind == :hash ? hash_shape(node) : array_shape(node)
          shapes << shape if shape
        end
        shapes.uniq { |shape| [shape["path"], shape["line"], shape["code"]] }
      end

      def normalized_state_declarations
        declarations = Array(@facts[:state_declarations]).dup
        declarations.concat(extra_typed_state_declarations)
        declarations.uniq { |state| [state.file, state.owner, declared_state_field(state.field), state.line, state.type] }
      end

      def extra_typed_state_declarations
        out = []
        walk_tree(@document.root) do |node|
          next unless %w[assignment assignment_expression assignment_statement].include?(node.kind.to_s)

          lhs = named_child(node, "left") || node_named_children(node).first
          target = state_target(lhs)
          next unless target

          type = declared_type_text(node, lhs)
          next if type.to_s.empty?

          out << Decomplex::Syntax::StateDeclaration.new(
            field: target.fetch(:field),
            owner: owner_for_line(node_line(node)),
            type: type,
            file: @document.file,
            line: node_line(node),
            span: node_span(node)
          )
        end
        out.concat(ruby_t_struct_state_declarations)
        out
      end

      def declared_states_by_owner(state_declarations)
        state_declarations.each_with_object(Hash.new { |hash, key| hash[key] = Set.new }) do |state, out|
          out[state.owner.to_s].add(declared_state_field(state.field))
        end
      end

      def method_signature(fn)
        signature = fn.signature.to_s
        return signature if @language != "ruby"

        signature.strip.start_with?("sig ") ? signature : ""
      end

      def method_source(signature)
        return {} if signature.to_s.empty?
        return { "sig" => signature, "signature" => signature, "type_system" => "sorbet", "source" => "annotation" } if @language == "ruby"

        { "signature" => signature, "source" => "syntax" }
      end

      def method_type_definition(fn)
        case @language
        when "ruby"
          ruby_method_type_definition(fn)
        when "python"
          python_method_type_definition(fn)
        when "typescript"
          typescript_method_type_definition(fn)
        end
      end

      def ruby_method_type_definition(fn)
        signature = method_signature(fn)
        return nil if signature.empty?

        owner = method_owner(fn)
        {
          "id" => ["ruby", rel(fn.file), owner, "method_signature", fn.name, fn.line, "sorbet"].map(&:to_s).join("\u0000"),
          "language" => "ruby",
          "type_system" => "sorbet",
          "kind" => "method_signature",
          "path" => rel(fn.file),
          "owner" => owner,
          "name" => fn.name.to_s,
          "line" => fn.line,
          "signature" => signature,
          "return_type" => NilKill.extract_return_type(signature),
          "params" => NilKill.extract_param_entries(signature).map { |name, type| { "name" => name, "type" => type } },
        }
      end

      def python_method_type_definition(fn)
        typed = python_signature_types(fn.signature)
        return nil if typed[:params].empty? && typed[:return_type].to_s.empty?

        {
          "id" => ["python", rel(fn.file), fn.owner, "method_signature", fn.name, fn.line, "python-typing"].map(&:to_s).join("\u0000"),
          "language" => "python",
          "type_system" => "python-typing",
          "kind" => "method_signature",
          "path" => rel(fn.file),
          "owner" => fn.owner.to_s,
          "name" => fn.name.to_s,
          "line" => fn.line,
          "signature" => fn.signature.to_s,
          "return_type" => typed[:return_type],
          "params" => typed[:params],
        }
      end

      def typescript_method_type_definition(fn)
        typed = typescript_signature_types(fn.signature)
        return nil if typed[:params].empty? && typed[:return_type].to_s.empty?

        {
          "id" => ["typescript", rel(fn.file), fn.owner, "method_signature", fn.name, fn.line, "typescript"].map(&:to_s).join("\u0000"),
          "language" => "typescript",
          "type_system" => "typescript",
          "kind" => "method_signature",
          "path" => rel(fn.file),
          "owner" => fn.owner.to_s,
          "name" => fn.name.to_s,
          "line" => fn.line,
          "signature" => fn.signature.to_s,
          "return_type" => typed[:return_type],
          "params" => typed[:params],
        }
      end

      def state_field_type_definition(state)
        type = state.type.to_s
        system = annotation_type_system
        return nil if type.empty? || system.empty?

        field = declared_state_field(state.field)
        {
          "id" => [@language, rel(state.file), state.owner, "state_field", field, state.line, system].map(&:to_s).join("\u0000"),
          "language" => @language,
          "type_system" => system,
          "kind" => "state_field",
          "path" => rel(state.file),
          "owner" => state.owner.to_s,
          "name" => field,
          "line" => state.line,
          "declared_type" => type,
        }
      end

      def annotation_type_system
        case @language
        when "ruby" then "sorbet"
        when "python" then "python-typing"
        when "typescript" then "typescript"
        else ""
        end
      end

      def ruby_struct_new_type_definitions
        return [] unless @language == "ruby"

        ruby_struct_definitions.flat_map do |struct|
          struct.fetch(:fields).map do |name|
            {
              "id" => ["ruby", rel(@document.file), struct.fetch(:owner), "state_field", name, struct.fetch(:line), "ruby-struct"].map(&:to_s).join("\u0000"),
              "language" => "ruby",
              "type_system" => "ruby-struct",
              "kind" => "state_field",
              "path" => rel(@document.file),
              "owner" => struct.fetch(:owner),
              "name" => name,
              "line" => struct.fetch(:line),
              "declared_type" => nil,
            }
          end
        end
      end

      def ruby_include_type_definitions
        return [] unless @language == "ruby"

        out = []
        walk_tree(@document.root) do |node|
          match = node_text(node).match(/\Ainclude\s+([A-Z]\w*(?:::[A-Z]\w*)*)\b/)
          next unless match

          owner = owner_for_line(node_line(node), include_struct: true).to_s
          next if owner.empty?

          included_name = resolved_include_name(owner, match[1])
          out << {
            "id" => ["ruby", rel(@document.file), owner, "included_module", included_name, node_line(node), "ruby-include"].map(&:to_s).join("\u0000"),
            "language" => "ruby",
            "type_system" => "ruby-include",
            "kind" => "included_module",
            "path" => rel(@document.file),
            "owner" => owner,
            "name" => included_name,
            "line" => node_line(node),
          }
        end
        out
      end

      def ruby_type_alias_definitions
        return [] unless @language == "ruby"

        type_alias_definitions("ruby", "sorbet", /\A([A-Z]\w*)\s*=\s*T\.type_alias\s*\{\s*(.+)\s*\}\s*(?:#.*)?\z/)
      end

      def python_stub_type_definitions
        return [] unless @language == "python" && File.extname(@document.file).downcase == ".pyi"

        definitions = []
        owner = nil
        owner_indent = nil
        @document.lines.each_with_index do |line, idx|
          line_no = idx + 1
          stripped = line.strip
          next if stripped.empty? || stripped.start_with?("#")

          indent = line[/\A\s*/].to_s.length
          if owner && indent <= owner_indent.to_i && !stripped.start_with?("def ")
            owner = nil
            owner_indent = nil
          end

          if (match = stripped.match(/\Aclass\s+([A-Za-z_]\w*)\b/))
            owner = match[1]
            owner_indent = indent
            next
          end

          if (match = stripped.match(/\A(?:async\s+)?def\s+([A-Za-z_]\w*)\s*\((.*)\)\s*(?:->\s*([^:]+))?:/))
            signature = stripped.sub(/\s*\.\.\.\s*\z/, "")
            typed = python_signature_types(signature)
            definitions << {
              "id" => ["python", rel(@document.file), owner, "method_signature", match[1], line_no, "python-typing-stub"].map(&:to_s).join("\u0000"),
              "language" => "python",
              "type_system" => "python-typing",
              "kind" => "method_signature",
              "path" => rel(@document.file),
              "owner" => owner.to_s,
              "name" => match[1],
              "line" => line_no,
              "signature" => signature,
              "return_type" => typed[:return_type],
              "params" => typed[:params],
            }
          elsif owner && (match = stripped.match(/\A([A-Za-z_]\w*)\s*:\s*([^=#]+)(?:\s*=.*)?\z/))
            definitions << {
              "id" => ["python", rel(@document.file), owner, "state_field", match[1], line_no, "python-typing-stub"].map(&:to_s).join("\u0000"),
              "language" => "python",
              "type_system" => "python-typing",
              "kind" => "state_field",
              "path" => rel(@document.file),
              "owner" => owner.to_s,
              "name" => match[1],
              "line" => line_no,
              "declared_type" => match[2].strip,
            }
          end
        end
        definitions
      end

      def python_type_alias_definitions
        return [] unless @language == "python"

        @document.lines.each_with_index.filter_map do |line, idx|
          stripped = line.strip
          next if stripped.empty? || stripped.start_with?("#")

          if (match = stripped.match(/\A([A-Z]\w*)\s*:\s*TypeAlias\s*=\s*(.+?)\s*(?:#.*)?\z/))
            alias_definition("python", "python-typing", "", match[1], match[2].strip, idx + 1)
          elsif (match = stripped.match(/\Atype\s+([A-Z]\w*)\s*=\s*(.+?)\s*(?:#.*)?\z/))
            alias_definition("python", "python-typing", "", match[1], match[2].strip, idx + 1)
          end
        end
      end

      def typescript_interface_type_definitions
        return [] unless @language == "typescript"

        definitions = []
        owner = nil
        @document.lines.each_with_index do |line, idx|
          line_no = idx + 1
          stripped = line.strip
          if (match = stripped.match(/\A(?:export\s+)?interface\s+([A-Za-z_$]\w*)\b/))
            owner = match[1]
            next
          end

          if owner && stripped.start_with?("}")
            owner = nil
            next
          end
          next unless owner

          if (match = stripped.match(/\A([A-Za-z_$]\w*)\??\s*\((.*)\)\s*:\s*([^;{]+)/))
            params = NilKill.split_top_level(match[2]).filter_map do |entry|
              name, type = typescript_param_entry(entry)
              next unless name && type

              { "name" => name, "type" => type }
            end
            definitions << {
              "id" => ["typescript", rel(@document.file), owner, "method_signature", match[1], line_no, "typescript-interface"].map(&:to_s).join("\u0000"),
              "language" => "typescript",
              "type_system" => "typescript",
              "kind" => "method_signature",
              "path" => rel(@document.file),
              "owner" => owner,
              "name" => match[1],
              "line" => line_no,
              "signature" => stripped.delete_suffix(";"),
              "return_type" => match[3].strip,
              "params" => params,
            }
          elsif (match = stripped.match(/\A([A-Za-z_$]\w*)\??\s*:\s*([^;{]+)/))
            definitions << {
              "id" => ["typescript", rel(@document.file), owner, "state_field", match[1], line_no, "typescript-interface"].map(&:to_s).join("\u0000"),
              "language" => "typescript",
              "type_system" => "typescript",
              "kind" => "state_field",
              "path" => rel(@document.file),
              "owner" => owner,
              "name" => match[1],
              "line" => line_no,
              "declared_type" => match[2].strip,
            }
          end
        end
        definitions
      end

      def typescript_type_alias_definitions
        return [] unless @language == "typescript"

        @document.lines.each_with_index.filter_map do |line, idx|
          match = line.strip.match(/\A(?:export\s+)?type\s+([A-Za-z_$]\w*)\s*=\s*(.+?)\s*;?\s*\z/)
          next unless match

          alias_definition("typescript", "typescript", "", match[1], match[2].strip, idx + 1)
        end
      end

      def type_alias_definitions(language, type_system, pattern)
        owner_stack = []
        pending = nil
        definitions = []
        @document.lines.each_with_index do |line, idx|
          line_no = idx + 1
          stripped = line.strip
          next if stripped.empty? || stripped.start_with?("#")

          if pending
            if stripped == "end" && line_indent(line) <= pending[:indent]
              target = pending[:body].join(" ").gsub(/\s+/, " ").strip.sub(/,\z/, "")
              definitions << alias_definition(language, type_system, pending[:owner], pending[:name], target, pending[:line]) unless target.empty?
              pending = nil
            else
              pending[:body] << stripped
            end
            next
          end

          if (match = stripped.match(/\A(?:class|module)\s+([A-Z]\w*(?:::[A-Z]\w*)*)\b/))
            owner_stack << qualified_owner(owner_stack.last, match[1])
            next
          end

          if stripped == "end"
            owner_stack.pop
            next
          end

          if (match = stripped.match(pattern))
            definitions << alias_definition(language, type_system, owner_stack.last.to_s, match[1], match[2].strip, line_no)
          elsif (match = stripped.match(/\A([A-Z]\w*)\s*=\s*T\.type_alias\s+do\b/))
            pending = { owner: owner_stack.last.to_s, name: match[1], line: line_no, indent: line_indent(line), body: [] }
          end
        end
        definitions
      end

      def alias_definition(language, type_system, owner, name, target, line)
        {
          "id" => [language, rel(@document.file), owner, "type_alias", name, line, type_system].map(&:to_s).join("\u0000"),
          "language" => language,
          "type_system" => type_system,
          "kind" => "type_alias",
          "path" => rel(@document.file),
          "owner" => owner.to_s,
          "name" => name.to_s,
          "line" => line,
          "target" => target.to_s,
        }
      end

      def hash_shape(node)
        return nil unless hash_literal_node?(node)

        pairs = hash_pair_nodes(node)
        return nil if pairs.empty?

        keys = []
        value_types = []
        constants = constant_literal_types
        pairs.each do |pair|
          key = hash_key_name(hash_pair_key(pair))
          next unless key

          keys << key
          value_types << literal_value_type(hash_pair_value(pair), constants)
        end
        return nil if keys.empty?

        {
          "path" => rel(@document.file),
          "line" => node_line(node),
          "span" => node_span(node),
          "keys" => keys,
          "value_types" => value_types,
          "code" => node_text(node),
          "source" => "syntax",
        }
      end

      def array_shape(node)
        return nil unless array_literal_node?(node)

        elements = array_elements(node)
        constants = constant_literal_types
        types = elements.map { |child| literal_value_type(child, constants) }
        {
          "path" => rel(@document.file),
          "line" => node_line(node),
          "span" => node_span(node),
          "element_types" => types.uniq,
          "tuple_types" => types,
          "size" => elements.size,
          "homogeneous" => types.uniq.size <= 1,
          "code" => node_text(node),
          "source" => "syntax",
        }
      end

      def python_signature_types(signature)
        source = signature.to_s.strip
        match = source.match(/\A(?:async\s+)?def\s+\w+\s*\((.*)\)\s*(?:->\s*([^:]+))?:/)
        return { params: [], return_type: nil } unless match

        params = NilKill.split_top_level(match[1]).filter_map do |entry|
          entry = entry.sub(/\A\*\*?/, "").strip
          name, rest = entry.split(/:\s*/, 2)
          next unless name && rest

          name = name.sub(/=.*/, "").strip
          next if self_receiver_names.include?(name)

          type = rest.sub(/=.*/, "").strip
          next if type.empty?

          { "name" => name, "type" => type }
        end
        { params: params, return_type: match[2]&.strip }
      end

      def typescript_signature_types(signature)
        source = signature.to_s.strip
        params_source, close_idx = extract_parenthesized(source)
        return { params: [], return_type: nil } unless params_source

        params = NilKill.split_top_level(params_source).filter_map do |entry|
          name, type = typescript_param_entry(entry)
          next unless name && type

          { "name" => name, "type" => type }
        end
        tail = source[(close_idx + 1)..].to_s
        { params: params, return_type: tail[/\A\s*:\s*([^={;]+)/, 1]&.strip }
      end

      def typescript_param_entry(entry)
        text = entry.to_s.strip
        return [nil, nil] if text.empty?

        text = text.sub(/\A(?:public|private|protected|readonly|override|declare)\s+/, "")
        text = text.sub(/\A(?:public|private|protected)\s+readonly\s+/, "")
        text = text.sub(/\A\.\.\./, "")
        name, type = text.split(/:\s*/, 2)
        return [nil, nil] unless name && type

        name = name.sub(/=.*/, "").sub(/\?\z/, "").strip
        type = type.sub(/=.*/, "").strip
        return [nil, nil] if name.empty? || type.empty?

        [name, type]
      end

      def extract_parenthesized(source)
        start = source.index("(")
        return [nil, nil] unless start

        depth = 0
        i = start
        while i < source.length
          case source[i]
          when "("
            depth += 1
          when ")"
            depth -= 1
            return [source[(start + 1)...i], i] if depth.zero?
          end
          i += 1
        end
        [nil, nil]
      end

      def canonical_state_field(field, receiver: nil)
        text = field.to_s
        return text if text.empty? || text.start_with?("@")
        return "@#{text}" if %w[python typescript javascript].include?(@language) && owned_receiver_name?(receiver)

        text
      end

      def declared_state_field(field)
        text = field.to_s
        return text if text.empty? || text.start_with?("@")
        return "@#{text}" if %w[python typescript javascript].include?(@language)

        text
      end

      def receiver_state_field(receiver, known_states)
        known = Set.new(Array(known_states).map { |field| canonical_state_field(field) })
        text = receiver.to_s.sub(/\A\*/, "")
        return nil if text.empty? || self_receiver_names.include?(text)
        return canonical_state_field(text.split(".").first, receiver: text) if text.start_with?("@")

        self_receiver_names.each do |name|
          prefix = "#{name}."
          return canonical_state_field(text.split(".")[1], receiver: text) if text.start_with?(prefix)
        end

        first = canonical_state_field(text.split(".").first, receiver: text)
        known.include?(first) ? first : nil
      end

      def owned_state?(record, known_states)
        known = Set.new(Array(known_states).map { |field| canonical_state_field(field) })
        field = canonical_state_field(record.field, receiver: record.receiver)
        return true if known.include?(field)

        receiver = record.receiver.to_s
        return false if receiver == ".literal"

        owned_receiver_name?(receiver)
      end

      def owned_receiver_name?(receiver)
        text = receiver.to_s.sub(/\A\*/, "")
        return true if text.start_with?("@")

        self_receiver_names.any? { |name| text == name || text.start_with?("#{name}.") }
      end

      def self_receiver_names
        case @language
        when "python" then %w[self cls]
        when "typescript", "javascript" then %w[this]
        else %w[self this]
        end
      end

      def state_key(owner, field)
        [owner.to_s, field.to_s].join("\u0000")
      end

      def stringify_set_map(map)
        Hash[map.sort.map { |key, values| [key, values.to_a.map(&:to_s).sort.uniq] }]
      end

      def state_target(node)
        return nil unless ts_node?(node)

        case node.kind.to_s
        when "call"
          receiver = named_child(node, "receiver")
          method = named_child(node, "method")
          return nil unless receiver && method

          { receiver: node_text(receiver), field: node_text(method).sub(/=\z/, "") }
        when "field", "selector_expression", "member_expression", "attribute", "field_expression", "expression_list"
          object = named_child(node, "object") || named_child(node, "receiver") ||
            named_child(node, "operand") || named_child(node, "value") ||
            node_named_children(node).first
          field = named_child(node, "field") || named_child(node, "property") || node_named_children(node).last
          return nil unless object && field

          { receiver: node_text(object), field: node_text(field).sub(/=\z/, "") }
        when "instance_variable"
          { receiver: "self", field: node_text(node) }
        end
      end

      def declared_type_text(node, name_node)
        text = node_text(node)
        after_name = text[(name_node.end_byte - node.start_byte)..].to_s
        return normalize_text(Regexp.last_match(1)) if after_name.match(/\A\s*:\s*([^=,\n]+)/)
        return normalize_text(Regexp.last_match(1)) if text.match(/\A\s*(?:pub\s+)?(?:const|var)\s+\w+\s*:\s*([^=;\n]+)/)

        nil
      rescue StandardError
        nil
      end

      def hash_literal_node?(node)
        %w[hash dictionary object map literal_value table_constructor].include?(node.kind.to_s) ||
          (node_text(node).start_with?("{") && node_text(node).end_with?("}") && hash_pair_nodes(node).any?)
      end

      def hash_pair_nodes(node)
        node_named_children(node).select do |child|
          %w[pair hash_pair pair_pattern keyed_element field field_initializer].include?(child.kind.to_s) ||
            named_child(child, "key")
        end
      end

      def hash_pair_key(pair)
        named_child(pair, "key") || node_named_children(pair).first
      end

      def hash_pair_value(pair)
        named_child(pair, "value") || named_child(pair, "field") || node_named_children(pair)[1]
      end

      def hash_key_name(node)
        text = node_text(node)
        return nil if text.empty?
        return Regexp.last_match(1) if text.match?(/\A:([A-Za-z_]\w*[!?=]?)\z/)
        return Regexp.last_match(1) if text.match?(/\A([A-Za-z_]\w*)\s*:\z/)
        return Regexp.last_match(1) if text.match?(/\A["']([^"']+)["']\z/)
        return text if text.match?(/\A[A-Za-z_]\w*[!?=]?\z/)

        nil
      end

      def array_literal_node?(node)
        %w[array list array_literal list_literal].include?(node.kind.to_s)
      end

      def array_elements(node)
        node_named_children(node).reject { |child| %w[comment].include?(child.kind.to_s) }
      end

      def method_owner(fn)
        ruby_struct_owner_for_line(fn.line) || fn.owner.to_s
      end

      def ruby_struct_definitions
        @ruby_struct_definitions ||= begin
          definitions = []
          walk_tree(@document.root) do |node|
            match = node_text(node).match(/\A([A-Z]\w*)\s*=\s*Struct\.new\((.*?)\)/m)
            next unless match

            parent = owner_for_line(node_line(node), include_struct: false)
            owner = qualified_owner(parent, match[1])
            fields = NilKill.split_top_level(match[2]).filter_map do |arg|
              arg.strip[/\A:([A-Za-z_]\w*)\z/, 1]
            end
            next if fields.empty?

            definitions << {
              owner: owner,
              line: node_line(node),
              span: node_span(node),
              fields: fields,
            }
          end
          definitions.uniq { |entry| [entry.fetch(:owner), entry.fetch(:line), entry.fetch(:fields)] }
        end
      end

      def ruby_struct_owner_for_line(line)
        deepest_owner_for_line(ruby_struct_definitions, line)
      end

      def ruby_t_struct_state_declarations
        ruby_t_struct_fields.map do |field|
          Decomplex::Syntax::StateDeclaration.new(
            field: field.fetch(:name),
            owner: field.fetch(:owner),
            type: field.fetch(:type),
            file: @document.file,
            line: field.fetch(:line),
            span: field.fetch(:span)
          )
        end
      end

      def ruby_t_struct_fields
        return [] unless @language == "ruby"

        @ruby_t_struct_fields ||= begin
          fields = []
          walk_tree(@document.root) do |node|
            next unless node.kind.to_s == "call"

            match = node_text(node).match(/\A(?:const|prop)\s+:([A-Za-z_]\w*)\s*,\s*(.+?)\s*(?:do\b.*)?\z/m)
            next unless match

            owner = ruby_t_struct_owner_for_line(node_line(node))
            next if owner.to_s.empty?

            fields << {
              owner: owner,
              name: match[1],
              type: normalize_text(match[2]),
              line: node_line(node),
              span: node_span(node),
            }
          end
          fields.uniq { |field| [field.fetch(:owner), field.fetch(:name), field.fetch(:line)] }
        end
      end

      def ruby_t_struct_containers
        return [] unless @language == "ruby"

        @ruby_t_struct_containers ||= begin
          containers = []
          walk_tree(@document.root) do |node|
            match = node_text(node).match(/\Aclass\s+([A-Z]\w*(?:::[A-Z]\w*)*)\s*<\s*T::Struct\b/m)
            next unless match

            owner = declaration_owner_for_line(match[1], node_line(node))
            containers << {
              owner: owner,
              line: node_line(node),
              span: node_span(node),
            }
          end
          containers.uniq { |entry| [entry.fetch(:owner), entry.fetch(:line)] }
        end
      end

      def ruby_t_struct_owner_for_line(line)
        deepest_owner_for_line(ruby_t_struct_containers, line)
      end

      def deepest_owner_for_line(records, line)
        Array(records).select { |record| span_contains_line?(record.fetch(:span), line) }
                      .max_by { |record| span_sort_key(record.fetch(:span)) }
                      &.fetch(:owner, nil)
      end

      def span_contains_line?(span, line)
        range = Array(span)
        range[0].to_i <= line.to_i && range[2].to_i >= line.to_i
      end

      def span_sort_key(span)
        range = Array(span)
        [range[0].to_i, -((range[2].to_i - range[0].to_i).abs)]
      end

      def declaration_owner_for_line(name, line)
        owner = owner_for_line(line, include_struct: false).to_s
        return owner if owner == name.to_s || owner.end_with?("::#{name}")

        qualified_owner(owner, name)
      end

      def resolved_include_name(owner, name)
        return name.to_s if name.to_s.include?("::")

        namespace = owner.to_s.split("::")[0...-1].join("::")
        qualified = qualified_owner(namespace, name)
        owner_names.include?(qualified) ? qualified : name.to_s
      end

      def owner_names
        @owner_names ||= Set.new(Array(@facts[:owner_defs]).map { |owner| owner.name.to_s })
      end

      def constant_literal_types
        @constant_literal_types ||= begin
          types = {}
          walk_tree(@document.root) do |node|
            name, value = constant_assignment(node)
            next if name.to_s.empty?

            type = if value
                     literal_value_type(value, types)
                   else
                     literal_text_type(node_text(node).split("=", 2)[1].to_s, types)
                   end
            types[name] = type unless type == "T.untyped"
          end
          types
        end
      end

      def constant_assignment(node)
        if %w[assignment assignment_expression assignment_statement].include?(node.kind.to_s)
          target = named_child(node, "left") || node_named_children(node).first
          return [nil, nil] unless target && target.kind.to_s == "constant"

          return [node_text(target), named_child(node, "right") || node_named_children(node)[1]]
        end

        match = node_text(node).match(/\A([A-Z]\w*)\s*=\s*(.+)\z/m)
        return [nil, nil] unless match

        value = node_named_children(node).drop(1).find { |child| node_text(child) == match[2].strip } ||
          node_named_children(node)[1]
        [match[1], value]
      end

      def literal_value_type(node, constant_types = constant_literal_types)
        return "T.untyped" unless node

        kind = node.kind.to_s
        text = node_text(node)
        case kind
        when "string", "string_literal", "interpreted_string_literal", "raw_string_literal" then "String"
        when "number" then "number"
        when "integer", "integer_literal" then "Integer"
        when "float", "float_literal" then "Float"
        when "true", "false", "true_literal", "false_literal", "boolean" then "T::Boolean"
        when "nil", "none", "null", "nil_literal", "none_literal", "null_literal" then "NilClass"
        when "symbol", "simple_symbol", "hash_key_symbol" then "Symbol"
        when "symbol_array" then "T::Array[Symbol]"
        when "string_array" then "T::Array[String]"
        when "constant" then constant_types[text] || "T.untyped"
        else
          text_type = literal_text_type(text, constant_types)
          return text_type unless text_type == "T.untyped"

          return array_literal_type(node, constant_types) if array_literal_node?(node)
          return "T::Hash[T.untyped, T.untyped]" if hash_literal_node?(node)

          "T.untyped"
        end
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

      def array_literal_type(node, constant_types)
        types = array_elements(node).map { |child| literal_value_type(child, constant_types) }
        return "T::Array[T.untyped]" if types.empty? || types.include?("T.untyped")

        unique = types.uniq
        unique.size == 1 ? "T::Array[#{unique.first}]" : "T::Array[T.any(#{unique.join(", ")})]"
      end

      def owner_for_line(line, include_struct: false)
        if include_struct
          owner = ruby_struct_owner_for_line(line)
          return owner if owner
        end

        Array(@facts[:owner_defs]).select do |owner|
          span = Array(owner.span)
          span[0].to_i <= line.to_i && span[2].to_i >= line.to_i
        end.max_by { |owner| Array(owner.span)[0].to_i }&.name || file_owner
      end

      def qualified_owner(parent, name)
        return name.to_s if name.to_s.include?("::")

        parent.to_s.empty? ? name.to_s : "#{parent}::#{name}"
      end

      def file_owner
        File.basename(@document.file.to_s, File.extname(@document.file.to_s))
      end

      def rel(path)
        Pathname.new(path).relative_path_from(Pathname.new(@root)).to_s
      rescue StandardError
        path.to_s
      end

      def walk_tree(node, &block)
        pending = [node]
        seen = Set.new
        until pending.empty?
          current = pending.pop
          next unless ts_node?(current)
          key = current.object_id
          next if seen.include?(key)

          seen << key
          yield current
          node_children(current).reverse_each { |child| pending << child }
        end
      end

      def ts_node?(node)
        node && node.respond_to?(:kind) && node.respond_to?(:children)
      end

      def node_cache(node)
        @ts_node_cache[node.object_id] ||= {}
      end

      def node_children(node)
        node_cache(node).fetch(:children) do
          node_cache(node)[:children] = Array(node.children)
        end
      rescue StandardError
        []
      end

      def node_named_children(node)
        node_cache(node).fetch(:named_children) do
          node_cache(node)[:named_children] = Array(node.named_children)
        end
      rescue StandardError
        []
      end

      def named_child(node, name)
        fields = (node_cache(node)[:fields] ||= {})
        fields.fetch(name) do
          fields[name] = node.child_by_field_name(name)
        end
      rescue StandardError
        nil
      end

      def node_line(node)
        node_cache(node).fetch(:line) do
          node_cache(node)[:line] = node.start_point.row + 1
        end
      rescue StandardError
        1
      end

      def node_span(node)
        node_cache(node).fetch(:span) do
          node_cache(node)[:span] = [node.start_point.row + 1, node.start_point.column, node.end_point.row + 1, node.end_point.column]
        end
      rescue StandardError
        nil
      end

      def node_text(node)
        node_cache(node).fetch(:text) do
          node_cache(node)[:text] = node&.text.to_s.strip
        end
      rescue StandardError
        ""
      end

      def normalize_text(text)
        text.to_s.strip.gsub(/\s+/, " ")
      end

      def line_indent(line)
        line[/\A\s*/].to_s.length
      end
    end
  end

  module Ast
    class TreeSitterNormalizer
      def nil_kill_static_facts(structural_facts, root: NilKill::ROOT)
        Decomplex::NilKillStaticFacts.build(@document, structural_facts, root: root)
      end
    end
  end

  module Syntax
    class Document
      def static_facts(root: NilKill::ROOT)
        @static_facts ||= {}
        @static_facts[root] ||= adapter.static_facts(self, root: root)
      end
    end

    class TreeSitterAdapter
      def static_facts(document, root: NilKill::ROOT)
        Decomplex::Ast::TreeSitterNormalizer.new(document).nil_kill_static_facts(structural_facts(document), root: root)
      end
    end
  end
end
