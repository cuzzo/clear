# typed: false
# frozen_string_literal: true

require "set"
require "pathname"
require "fact_mine/syntax"

module FactMine
  # Produces enriched static facts from raw structural facts.
  # Supports two profiles:
  #   :espalier  - core facts needed by Espalier (methods, fields,
  #                type definitions, hash shapes, state protocols, etc.)
  #   :nil_kill  - all facts including nil-kill-specific inference
  #                data (tlet_sites, dead_nil_checks, deterministic_guards,
  #                return_origins, etc.)
  module EspalierProfile
    module_function

    def build(document, structural_facts, root: Dir.pwd, profile: :nil_kill)
      Builder.new(document, structural_facts, root: root, profile: profile).build
    end

    class Builder
      def initialize(document, structural_facts, root: Dir.pwd, profile: :nil_kill)
        @document = document
        @facts = structural_facts
        @language = document.language.to_s
        @root = root
        @profile = profile
        @ts_node_cache = {}
      end

      def build
        state_declarations = normalized_state_declarations
        known_states = known_states_by_owner(state_declarations)
        nil_kill = (@profile == :nil_kill)

        {
          methods: methods,
          fields: fields(state_declarations, known_states),
          struct_declarations: struct_declarations,
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
          collection_index_lookups: nil_kill ? collection_index_lookups : [],
          hash_record_blockers: [],
          tlet_sites: nil_kill ? tlet_sites : [],
          dead_nil_checks: nil_kill ? dead_nil_checks : [],
          deterministic_guards: nil_kill ? deterministic_guards : [],
          return_origins: nil_kill ? return_origins : [],
          noreturn_methods: nil_kill ? noreturn_methods : [],
        }
      end

      private

      def fact_document?
        !@document.respond_to?(:adapter) || @document.adapter.nil?
      end

      def ruby_type_profile
        @ruby_type_profile ||= FactMine::Syntax.type_profile(:ruby, type_system: "sorbet")
      end

      def local_methods
        Array(@facts[:local_methods])
      end

      def call_sites_for_method(fn)
        Array(@facts[:call_sites]).select do |call|
          call.function.to_s == fn.name.to_s && call.owner.to_s == method_owner(fn).to_s
        end
      end

      def comparisons_for_method(fn)
        Array(@facts[:comparison_sites]).select do |comparison|
          comparison.function.to_s == fn.name.to_s && span_contains_line?(fn.span, comparison.line)
        end
      end

      def statement_for_line(line)
        statements_by_line[line.to_i]
      end

      def statement_source_for_line(line)
        statement_for_line(line)&.source.to_s
      end

      def assignment_name_for_line(line)
        statement_source_for_line(line).strip[/\A(@?[A-Za-z_]\w*)\s*=/, 1]
      end

      def statements_by_line
        @statements_by_line ||= local_methods.each_with_object({}) do |method, index|
          Array(method.statements).each do |statement|
            (statement.line.to_i..statement.end_line.to_i).each { |line| index[line] ||= statement }
          end
        end
      end

      def methods
        Array(@facts[:function_defs]).map do |fn|
          signature = method_signature(fn)
          owner = method_owner(fn)
          kind = method_kind(fn, owner)
          {
            "key" => [owner, fn.name.to_s, kind],
            "owner" => owner,
            "name" => fn.name.to_s,
            "kind" => kind,
            "path" => rel(fn.file),
            "line" => fn.line,
            "span" => fn.span,
            "language" => @language,
            "signature" => signature,
            "params" => Array(fn.params).map(&:to_s),
            "untraceable_params" => method_untraceable_params(fn),
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
          "type_references" => state.respond_to?(:type_references) ? Array(state.type_references) : [],
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
            "type_references" => state.respond_to?(:type_references) ? Array(state.type_references) : [],
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
        ruby_ivar_protocol_records(known_states).each do |record|
          out[record["key"]].add(record["protocol"].to_s)
        end
        stringify_set_map(out)
      end

      def state_protocol_records(known_states)
        records = Array(@facts[:call_sites]).filter_map do |call|
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
        end
        (records + ruby_ivar_protocol_records(known_states)).uniq do |record|
          [record["language"], record["path"], record["owner"], record["function"],
            record["field"], record["protocol"], record["line"]]
        end
      end

      def all_state_param_origins
        @all_state_param_origins ||= begin
          records = Array(@facts[:state_param_origins]) + derived_state_param_origins
          records.uniq do |origin|
            [origin.file.to_s, origin.owner.to_s, origin.function.to_s,
              origin.field.to_s, origin.receiver.to_s, origin.param.to_s, origin.line.to_i]
          end
        end
      end

      def derived_state_param_origins
        params_by_method = Array(@facts[:function_defs]).each_with_object({}) do |fn, index|
          index[[method_owner(fn), fn.name.to_s]] = Array(fn.params).map(&:to_s).to_set
        end

        Array(@facts[:local_methods]).flat_map do |method|
          params = params_by_method.fetch([method.owner.to_s, method.name.to_s], Set.new)
          next [] if params.empty?

          Array(method.statements).filter_map do |statement|
            source = statement.source.to_s.strip
            match = source.match(/\A(?:(@[A-Za-z_]\w*)|(?:self|this)\.([A-Za-z_]\w*))\s*=\s*(.+)\z/)
            next unless match

            rhs = match[3].to_s.strip
            param = rhs[/\AT\.let\(\s*([A-Za-z_]\w*)\s*,/m, 1]
            param ||= rhs if rhs.match?(/\A[A-Za-z_]\w*\z/)
            next unless param && params.include?(param)

            FactMine::Syntax::StateParamOrigin.new(
              field: match[1] || match[2],
              receiver: "self",
              owner: method.owner.to_s,
              param: param,
              file: method.file,
              function: method.name.to_s,
              line: statement.line,
              span: statement.span
            )
          end
        end
      end

      def state_param_origins(known_states)
        out = Hash.new { |hash, key| hash[key] = Set.new }
        all_state_param_origins.each do |origin|
          next unless owned_state?(origin, known_states[origin.owner.to_s])
          next if self_receiver_names.include?(origin.param.to_s)

          field = canonical_state_field(origin.field, receiver: origin.receiver)
          out[state_key(origin.owner, field)].add(origin.param.to_s)
        end
        stringify_set_map(out)
      end

      def state_param_origin_records(known_states)
        all_state_param_origins.filter_map do |origin|
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
        mined = mined_type_definitions
        return mined unless mined.empty?

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

      def mined_type_definitions
        @mined_type_definitions ||= begin
          rows = Array(@facts[:type_definitions])
          rows = @document.type_definitions if rows.empty? && @document.respond_to?(:type_definitions)
          rows.map { |row| normalize_mined_type_definition(row) }
              .uniq { |row| [row["language"], row["path"], row["owner"], row["kind"], row["name"], row["line"], row["type_system"]] }
        end
      end

      def normalize_mined_type_definition(value)
        row = value.respond_to?(:to_h) ? value.to_h : value
        row = row.transform_keys(&:to_s)
        source_path = row["file"].to_s.empty? ? row["path"].to_s : row["file"].to_s
        report_path = source_path.empty? ? row["path"].to_s : rel(source_path)
        normalized = row.merge("path" => report_path)
        normalized["id"] = [
          normalized["language"],
          normalized["path"],
          normalized["owner"],
          normalized["kind"],
          normalized["name"],
          normalized["line"],
          normalized["type_system"]
        ].map(&:to_s).join("\u0000")
        normalized
      end

      def literal_shapes(kind)
        shapes = []
        walk_tree(@document.root) do |node|
          shape = kind == :hash ? hash_shape(node) : array_shape(node)
          shapes << shape if shape
        end
        shapes.uniq { |shape| [shape["path"], shape["line"], shape["code"]] }
      end

      def collection_index_lookups
        Array(@facts[:call_sites]).filter_map do |call|
          index = hash_lookup_index(call)
          next unless index

          receiver = call.receiver.to_s
          origin = local_hash_origins[[call.owner.to_s, call.function.to_s, receiver]]
          next unless origin

          lookup_type = hash_lookup_type(origin.fetch(:types).fetch(hash_lookup_key(index), "T.untyped"))
          {
            "path" => rel(call.file),
            "line" => call.line,
            "span" => call.span,
            "code" => hash_lookup_code(call, index),
            "receiver" => receiver,
            "index" => index,
            "lookup_type" => lookup_type,
            "status" => useful_lookup_type?(lookup_type) ? "typed lookup" : "weak lookup",
            "enclosing_scope" => call.owner.to_s,
            "origin" => {
              "kind" => "hash literal",
              "path" => origin.fetch(:shape).fetch("path"),
              "line" => origin.fetch(:shape).fetch("line"),
              "name" => receiver,
              "code" => origin.fetch(:shape).fetch("code"),
              "keys" => origin.fetch(:shape).fetch("keys")
            }
          }
        end.uniq { |lookup| [lookup["path"], lookup["line"], lookup["code"], lookup.dig("origin", "line")] }
      end

      def normalized_state_declarations
        declarations = Array(@facts[:state_declarations]).dup
        declarations.concat(extra_typed_state_declarations) if mined_type_definitions.empty?
        declarations.uniq { |state| [state.file, state.owner, declared_state_field(state.field), state.line, state.type] }
      end

      def known_states_by_owner(state_declarations)
        out = declared_states_by_owner(state_declarations)
        Array(@facts[:state_writes]).each do |write|
          out[write.owner.to_s].add(canonical_state_field(write.field, receiver: write.receiver))
        end
        Array(@facts[:state_reads]).each do |read|
          out[read.owner.to_s].add(canonical_state_field(read.field, receiver: read.receiver))
        end
        all_state_param_origins.each do |origin|
          out[origin.owner.to_s].add(canonical_state_field(origin.field, receiver: origin.receiver))
        end
        out
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

          out << FactMine::Syntax::StateDeclaration.new(
            field: target.fetch(:field),
            owner: owner_for_line(node_line(node)),
            type: type,
            file: @document.file,
            line: node_line(node),
            span: node_span(node)
          )
        end
        out.concat(source_typed_state_declarations)
        out.concat(tlet_state_declarations)
        out.concat(ruby_t_struct_state_declarations)
        out
      end

      def source_typed_state_declarations
        case @language
        when "python" then python_source_typed_state_declarations
        when "typescript", "javascript" then typescript_source_typed_state_declarations
        else []
        end
      end

      def python_source_typed_state_declarations
        @document.lines.each_with_index.filter_map do |line, idx|
          line_no = idx + 1
          stripped = line.strip
          match = stripped.match(/\A(?:self|cls)\.([A-Za-z_]\w*)\s*:\s*([^=#]+?)(?:\s*=.*)?(?:#.*)?\z/)
          next unless match

          owner = owner_record_for_line(line_no)&.name.to_s
          next if owner.empty?

          typed_state_declaration(match[1], owner, match[2], line, line_no)
        end
      end

      def typescript_source_typed_state_declarations
        @document.lines.each_with_index.filter_map do |line, idx|
          line_no = idx + 1
          owner = owner_record_for_line(line_no)&.name.to_s
          next if owner.empty?

          stripped = line.strip
          next if stripped.empty? || stripped.start_with?("//")
          next if stripped.include?("(")

          match = stripped.match(
            /\A(?:(?:public|private|protected|readonly|static|declare|override|abstract)\s+)*(?:accessor\s+)?([A-Za-z_$]\w*)[?!]?\s*:\s*([^=;{]+)/
          )
          next unless match

          typed_state_declaration(match[1], owner, match[2], line, line_no)
        end
      end

      def typed_state_declaration(field, owner, type, line, line_no)
        type = type.to_s.split("#", 2).first.to_s.split("//", 2).first.to_s.delete_suffix(";")
        type = normalize_text(type)
        return nil if type.empty?

        FactMine::Syntax::StateDeclaration.new(
          field: field.to_s,
          owner: owner.to_s,
          type: type,
          file: @document.file,
          line: line_no,
          span: source_line_span(line, line_no)
        )
      end

      def tlet_state_declarations
        return [] unless @language == "ruby"

        local_methods.flat_map do |method|
          Array(method.statements).filter_map do |statement|
            source = statement.source.to_s.strip
            match = source.match(/\A(?:(@[A-Za-z_]\w*)|(?:self|this)\.([A-Za-z_]\w*))\s*=\s*T\.let\((.*)\)\z/m)
            next unless match

            args = FactMine::Syntax.type_profile(:generic).split_top_level(match[3])
            type = args[1].to_s.strip
            next if type.empty?

            FactMine::Syntax::StateDeclaration.new(
              field: match[1] || match[2],
              owner: method.owner.to_s,
              type: normalize_text(type),
              file: method.file,
              line: statement.line,
              span: statement.span
            )
          end
        end
      end

      def declared_states_by_owner(state_declarations)
        state_declarations.each_with_object(Hash.new { |hash, key| hash[key] = Set.new }) do |state, out|
          out[state.owner.to_s].add(declared_state_field(state.field))
        end
      end

      def method_signature(fn)
        signature = fn.respond_to?(:signature) ? fn.signature.to_s : ""
        signature = source_signature_for(fn) if signature.empty?
        return signature if @language != "ruby"

        signature = ruby_signature_before_line(fn.line) if signature.empty?
        signature.strip.start_with?("sig ") ? signature : ""
      end

      def source_signature_for(fn)
        case @language
        when "python", "typescript", "javascript"
          line = method_header_text(fn).strip
          line.empty? ? "" : line
        else
          ""
        end
      end

      def ruby_signature_before_line(line)
        idx = line.to_i - 2
        idx -= 1 while idx >= 0 && @document.lines[idx].to_s.strip.empty?
        return "" if idx.negative?

        start = idx
        until start.zero? || @document.lines[start].to_s.strip.start_with?("sig")
          text = @document.lines[start].to_s.strip
          return "" if text.start_with?("def ", "class ", "module ")

          start -= 1
        end
        return "" unless @document.lines[start].to_s.strip.start_with?("sig")

        @document.lines[start..idx].join(" ").split.join(" ")
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
          "return_type" => ruby_type_profile.extract_return_type(signature),
          "params" => ruby_type_profile.extract_param_entries(signature).map { |name, type| { "name" => name, "type" => type } },
        }
      end

      def python_method_type_definition(fn)
        signature = method_signature(fn)
        typed = python_signature_types(signature)
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
          "signature" => signature,
          "return_type" => typed[:return_type],
          "params" => typed[:params],
        }
      end

      def typescript_method_type_definition(fn)
        signature = method_signature(fn)
        typed = typescript_signature_types(signature)
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
          "signature" => signature,
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
          "type_references" => state.respond_to?(:type_references) ? Array(state.type_references) : [],
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
            params = FactMine::Syntax.type_profile(:generic).split_top_level(match[2]).filter_map do |entry|
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

      def local_hash_origins
        @local_hash_origins ||= begin
          origins = {}
          walk_tree(@document.root) do |node|
            name, hash = local_hash_assignment(node)
            next unless name && hash

            function = function_for_line(node_line(node))
            next unless function

            shape = hash_shape(hash)
            next unless shape

            owner = method_owner(function)
            origins[[owner, function.name.to_s, name]] = {
              shape: shape,
              types: Hash[Array(shape["keys"]).zip(Array(shape["value_types"]))]
            }
          end
          origins
        end
      end

      def local_hash_assignment(node)
        return [nil, nil] unless %w[assignment assignment_expression assignment_statement LASGN].include?(node.kind.to_s)

        children = node_named_children(node)
        target = named_child(node, "left") || children.first
        value = named_child(node, "right") || children[1]
        value ||= children.find { |child| ts_node?(child) && hash_literal_node?(child) }
        name = local_assignment_name(target)
        return [nil, nil] unless name && value && hash_literal_node?(value)

        [name, value]
      end

      def local_assignment_name(node)
        return node.to_s if node.is_a?(String) || node.is_a?(Symbol)

        text = node_text(node)
        text.match?(/\A[A-Za-z_]\w*\z/) ? text : nil
      end

      def function_for_line(line)
        Array(@facts[:function_defs]).select { |fn| span_contains_line?(fn.span, line) }
                                    .max_by { |fn| span_sort_key(fn.span) }
      end

      def hash_lookup_index(call)
        message = call.message.to_s
        return nil unless %w[[] fetch].include?(message)

        index = Array(call.arguments).first.to_s
        hash_lookup_key(index) ? index : nil
      end

      def hash_lookup_key(index)
        case index.to_s
        when /\A:([A-Za-z_]\w*[!?=]?)\z/
          Regexp.last_match(1)
        when /\A["']([^"']+)["']\z/
          Regexp.last_match(1)
        end
      end

      def hash_lookup_type(value_type)
        type = value_type.to_s
        return "T.untyped" if type.empty? || type == "T.untyped"
        return type if type.start_with?("T.nilable(")

        "T.nilable(#{type})"
      end

      def useful_lookup_type?(type)
        ruby_type_profile.useful_type?(type)
      end

      def hash_lookup_code(call, index)
        receiver = call.receiver.to_s
        case call.message.to_s
        when "[]" then "#{receiver}[#{index}]"
        when "fetch" then "#{receiver}.fetch(#{index})"
        else fact_call_text(call)
        end
      end

      def tlet_sites
        return [] unless @language == "ruby"

        if fact_document?
          return Array(@facts[:call_sites]).filter_map do |call|
            next unless call.receiver.to_s == "T" && call.message.to_s == "let"

            {
              "path" => rel(call.file),
              "line" => call.line,
              "span" => call.span,
              "name" => assignment_name_for_line(call.line),
              "tlet" => true,
              "type" => Array(call.arguments)[1].to_s.strip,
            }
          end
        end

        sites = []
        walk_tree(@document.root) do |node|
          next unless node.kind.to_s == "call"

          text = node_text(node)
          match = text.match(/\AT\.let\((.*)\)\z/m)
          next unless match

          args = FactMine::Syntax.type_profile(:generic).split_top_level(match[1])
          sites << {
            "path" => rel(@document.file),
            "line" => node_line(node),
            "tlet" => true,
            "type" => args[1].to_s.strip,
          }
        end
        sites
      end

      def struct_declarations
        return [] unless @language == "ruby"

        ruby_struct_definitions.map do |struct|
          {
            "path" => rel(@document.file),
            "line" => struct.fetch(:line),
            "class" => struct.fetch(:owner),
            "fields" => struct.fetch(:fields),
          }
        end
      end

      def dead_nil_checks
        return [] unless @language == "ruby"

        typed_ruby_methods.flat_map do |fn, context|
          next [] if context.fetch(:non_nil_params).empty?

          walk_method_calls(fn).filter_map do |node|
            text = node_text(node)
            receiver = ruby_nil_check_receiver(text)
            if receiver && context.fetch(:non_nil_params).include?(receiver)
              next({
                "path" => rel(fn.file),
                "line" => node_line(node),
                "kind" => "nil_check",
                "code" => text,
                "reason" => "#{receiver} is provably non-nil; .nil? is always false",
              })
            end

            receiver = ruby_safe_nav_receiver(text)
            next unless receiver && context.fetch(:non_nil_params).include?(receiver)

            {
              "path" => rel(fn.file),
              "line" => node_line(node),
              "kind" => "safe_nav",
              "code" => text,
              "reason" => "#{receiver} is provably non-nil",
            }
          end
        end.uniq { |finding| [finding["path"], finding["line"], finding["kind"], finding["code"]] }
      end

      def deterministic_guards
        return [] unless @language == "ruby"

        nil_guards = dead_nil_checks.select { |finding| finding["kind"] == "nil_check" }.map do |finding|
          {
            "path" => finding["path"],
            "line" => finding["line"],
            "class" => owner_for_line(finding["line"]),
            "method" => method_for_line(finding["line"]),
            "code" => finding["code"],
            "branch_kind" => "if",
            "truth_value" => false,
            "taken_branch" => "else",
            "proof_tier" => "static_proven",
            "predicate_kind" => "nil_check",
            "reason" => finding["reason"],
            "origin_kind" => "param",
            "origin_name" => ruby_nil_check_receiver(finding["code"]),
          }
        end

        static_guards = typed_ruby_methods.flat_map do |fn, context|
          walk_method_guard_nodes(fn).filter_map do |node|
            text = node_text(node)
            result = deterministic_class_guard(text, context.fetch(:param_types)) ||
              deterministic_literal_comparison(text)
            next unless result

            branch = branch_context_for(node)
            truth = result.fetch("truth_value")
            {
              "path" => rel(fn.file),
              "line" => node_line(node),
              "class" => method_owner(fn),
              "method" => normalized_method_name(fn.name),
              "code" => text,
              "branch_kind" => branch.fetch(:kind),
              "truth_value" => truth,
              "taken_branch" => branch.fetch(:inverted) ? (truth ? "else" : "body") : (truth ? "body" : "else"),
              "proof_tier" => "static_proven",
              "predicate_kind" => result.fetch("predicate_kind"),
              "reason" => result.fetch("reason"),
              "origin_kind" => result["origin_kind"],
              "origin_name" => result["origin_name"],
            }
          end
        end

        (nil_guards + static_guards).uniq { |guard| [guard["path"], guard["line"], guard["code"], guard["predicate_kind"]] }
      end

      def noreturn_methods
        return [] unless @language == "ruby"

        Array(@facts[:function_defs]).filter_map do |fn|
          signature = method_signature(fn)
          return_type = ruby_type_profile.extract_return_type(signature).to_s
          reason =
            if return_type == "T.noreturn"
              "declared T.noreturn"
            elsif ruby_always_noreturn_body?(fn.respond_to?(:body) ? fn.body : fn)
              "body cannot return normally"
            end
          next unless reason

          {
            "language" => "ruby",
            "path" => rel(fn.file),
            "owner" => method_owner(fn),
            "name" => normalized_method_name(fn.name),
            "line" => fn.line,
            "reason" => reason,
          }
        end.uniq { |record| [record["path"], record["owner"], record["name"], record["line"]] }
      end

      def return_origins
        return [] unless @language == "ruby"

        Array(@facts[:function_defs]).filter_map do |fn|
          signature = method_signature(fn)
          next if signature.empty?

          return_type = ruby_type_profile.extract_return_type(signature).to_s
          next unless return_type == "T.untyped"

          origin = ruby_return_origin(fn, signature)
          next unless origin

          origin
        end
      end

      def python_signature_types(signature)
        source = signature.to_s.strip
        match = source.match(/\A(?:async\s+)?def\s+\w+\s*\((.*)\)\s*(?:->\s*([^:]+))?:/)
        return { params: [], return_type: nil } unless match

        params = FactMine::Syntax.type_profile(:generic).split_top_level(match[1]).filter_map do |entry|
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

        params = FactMine::Syntax.type_profile(:generic).split_top_level(params_source).filter_map do |entry|
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

      def typed_ruby_methods
        Array(@facts[:function_defs]).filter_map do |fn|
          signature = method_signature(fn)
          next if signature.empty?

          param_types = ruby_type_profile.extract_param_entries(signature).to_h
          non_nil = param_types.filter_map do |name, type|
            next if nullable_or_untyped?(type)

            name.to_s
          end.to_set
          [fn, { param_types: param_types, non_nil_params: non_nil }]
        end
      end

      def method_untraceable_params(fn)
        return [] unless @language == "ruby"

        header = method_header_text(fn)
        header.scan(/(?:\*\*|\*|&)([a-z_]\w*)/).flatten.uniq
      end

      def nullable_or_untyped?(type)
        ruby_type_profile.nullable_or_untyped?(type)
      end

      def walk_method_calls(fn)
        return call_sites_for_method(fn) if fact_document?

        calls = []
        walk_tree(fn.body) do |node|
          calls << node if node.kind.to_s == "call"
        end
        calls
      end

      def walk_method_guard_nodes(fn)
        return call_sites_for_method(fn) + comparisons_for_method(fn) if fact_document?

        nodes = []
        walk_tree(fn.body) do |node|
          nodes << node if %w[call binary].include?(node.kind.to_s)
        end
        nodes
      end

      def ruby_nil_check_receiver(text)
        ruby_type_profile.nil_check_receiver(text)
      end

      def ruby_safe_nav_receiver(text)
        ruby_type_profile.safe_nav_receiver(text)
      end

      def ruby_always_noreturn_body?(node)
        ruby_type_profile.always_noreturn_body_text?(node_text(node))
      end

      def ruby_return_origin(fn, signature)
        param_types = ruby_type_profile.extract_param_entries(signature).to_h
        sources = ruby_return_sources(fn, param_types)
        return nil if sources.empty?

        types = sources.map { |source| source["type"].to_s }.reject(&:empty?)
        candidate = ruby_type_profile.static_type(types)
        blockers = sources.select { |source| source["kind"] == "unknown" }.map do |source|
          "unknown return expression #{source["code"]} at #{rel(fn.file)}:#{source["line"]}"
        end
        {
          "path" => rel(fn.file),
          "line" => fn.line,
          "class" => method_owner(fn),
          "method" => normalized_method_name(fn.name),
          "kind" => fn.name.to_s.start_with?("self.") ? "class" : "instance",
          "candidate_type" => candidate,
          "confidence" => blockers.empty? && ruby_type_profile.useful_type?(candidate) ? "strong" : "blocked",
          "sources" => sources,
          "blockers" => blockers,
          "return_syntax" => ruby_return_syntax(sources),
          "control_shape" => sources.any? { |source| source["conditional"] } ? "branching" : "branchless",
        }
      end

      def ruby_return_sources(fn, param_types)
        lines = method_body_lines(fn)
        return [] if lines.empty?

        sources = []
        lines.each do |line_no, raw|
          stripped = raw.strip
          next if stripped.empty? || stripped == "end"

          if (match = stripped.match(/\Areturn\s+(.+?)\s+unless\s+(.+)\z/))
            sources << ruby_return_source(fn, line_no, match[1], explicit: true, conditional: true, param_types: param_types)
            next
          elsif (match = stripped.match(/\Areturn\s+(.+?)\s+if\s+(.+)\z/))
            sources << ruby_return_source(fn, line_no, match[1], explicit: true, conditional: true, param_types: param_types)
            next
          elsif (match = stripped.match(/\Areturn(?:\s+(.+))?\z/))
            sources << ruby_return_source(fn, line_no, match[1].to_s.empty? ? "nil" : match[1], explicit: true, conditional: false, param_types: param_types)
            next
          end

          next if stripped.start_with?("if ", "unless ", "else", "elsif ")

          sources << ruby_return_source(fn, line_no, stripped, explicit: false, conditional: false, param_types: param_types)
        end
        sources
      end

      def ruby_return_source(fn, line_no, expr, explicit:, conditional:, param_types:)
        code = expr.to_s.strip
        type, kind, callee, stdlib = ruby_return_expression_type(code, param_types)
        {
          "kind" => kind,
          "type" => type,
          "line" => line_no,
          "code" => code,
          "callee" => callee,
          "stdlib" => stdlib,
          "explicit" => explicit,
          "conditional" => conditional,
        }.compact
      end

      def ruby_return_expression_type(code, param_types)
        ruby_type_profile.return_expression_type(code, param_types)
      end

      def ruby_return_syntax(sources)
        explicit = sources.any? { |source| source["explicit"] }
        implicit = sources.any? { |source| !source["explicit"] }
        return "mixed" if explicit && implicit
        return "explicit" if explicit

        "implicit"
      end

      def method_body_lines(fn)
        span = Array(fn.span)
        first = fn.line.to_i
        last = span[2].to_i
        return [] if first <= 0 || last <= first

        ((first + 1)...last).map { |line_no| [line_no, @document.lines[line_no - 1].to_s] }
      end

      def method_header_text(fn)
        @document.lines[fn.line.to_i - 1].to_s
      end

      def deterministic_class_guard(text, param_types)
        match = text.to_s.strip.match(/\A([a-z_]\w*)\.(is_a\?|kind_of\?|instance_of\?)\(([^)]+)\)\z/)
        return nil unless match

        receiver, predicate, wanted = match[1], match[2], match[3].to_s.strip
        receiver_type = param_types[receiver].to_s
        truth = ruby_type_profile.class_guard_truth(receiver_type, wanted, exact: predicate == "instance_of?")
        return nil if truth.nil?

        {
          "truth_value" => truth,
          "predicate_kind" => "class_guard",
          "reason" => "#{receiver} has static type #{receiver_type}; #{predicate}(#{wanted}) is always #{truth}",
          "origin_kind" => "param",
          "origin_name" => receiver,
        }
      end

      def deterministic_literal_comparison(text)
        match = text.to_s.strip.match(/\A([-+]?\d+(?:\.\d+)?)\s*(==|!=|>=|>|<=|<)\s*([-+]?\d+(?:\.\d+)?)\z/)
        return nil unless match

        left = numeric_literal(match[1])
        right = numeric_literal(match[3])
        truth = left.public_send(match[2], right)
        {
          "truth_value" => truth,
          "predicate_kind" => "literal_comparison",
          "reason" => "#{match[1]} #{match[2]} #{match[3]} is always #{truth}",
        }
      end

      def numeric_literal(text)
        text.to_s.include?(".") ? text.to_f : text.to_i
      end

      def branch_context_for(node)
        source = statement_source_for_line(node_line(node)).strip
        text = node_text(node)
        if source.start_with?("unless ") || source.include?(" unless #{text}")
          return { kind: "unless", inverted: true }
        end
        if source.start_with?("if ") || source.include?(" if #{text}")
          return { kind: "if", inverted: false }
        end

        parent = parent_node(node)
        while parent
          parent_text = node_text(parent)
          kind = parent.kind.to_s
          if kind == "unless" || parent_text.start_with?("unless ")
            return { kind: "unless", inverted: true }
          end
          if kind == "if" || parent_text.start_with?("if ")
            return { kind: "if", inverted: false }
          end
          parent = parent_node(parent)
        end
        { kind: "if", inverted: false }
      end

      def method_for_line(line)
        Array(@facts[:function_defs]).select do |fn|
          span = Array(fn.span)
          span[0].to_i <= line.to_i && span[2].to_i >= line.to_i
        end.max_by { |fn| Array(fn.span)[0].to_i }&.name.to_s.sub(/\Aself\./, "")
      end

      def normalized_method_name(name)
        name.to_s.sub(/\Aself\./, "")
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
        when "typescript", "javascript" then %w[self this]
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

      def method_kind(fn, owner = method_owner(fn))
        raw = fn.respond_to?(:kind) ? fn.kind.to_s : ""
        return raw unless raw.empty?

        owner.to_s.empty? || owner.to_s == "(top-level)" ? "function" : "method"
      end

      def ruby_struct_definitions
        @ruby_struct_definitions ||= begin
          if fact_document?
            ruby_struct_definitions_from_facts
          else
            definitions = []
            walk_tree(@document.root) do |node|
              next unless %w[assignment assignment_expression assignment_statement].include?(node.kind.to_s)

              match = node_text(node).match(/\A([A-Z]\w*)\s*=\s*Struct\.new\((.*?)\)/m)
              next unless match

              parent = lexical_owner_for_line(node_line(node)).to_s
              owner = qualified_owner(parent, match[1])
              fields = FactMine::Syntax.type_profile(:generic).split_top_level(match[2]).filter_map do |arg|
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
      end

      def ruby_struct_definitions_from_facts
        Array(@facts[:call_sites]).filter_map do |call|
          next unless call.receiver.to_s == "Struct" && call.message.to_s == "new"

          line = @document.lines[call.line.to_i - 1].to_s
          match = line.match(/([A-Z]\w*)\s*=\s*Struct\.new\((.*?)\)/m)
          next unless match

          fields = Array(call.arguments).filter_map { |arg| arg.to_s.strip[/\A:([A-Za-z_]\w*)\z/, 1] }
          next if fields.empty?

          parent = lexical_owner_for_line(call.line).to_s
          {
            owner: qualified_owner(parent, match[1]),
            line: call.line,
            span: call.span,
            fields: fields,
          }
        end.uniq { |entry| [entry.fetch(:owner), entry.fetch(:line), entry.fetch(:fields)] }
      end

      def ruby_struct_owner_for_line(line)
        deepest_owner_for_line(ruby_struct_definitions, line)
      end

      def ruby_t_struct_state_declarations
        ruby_t_struct_fields.map do |field|
          FactMine::Syntax::StateDeclaration.new(
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
          if fact_document?
            Array(@facts[:call_sites]).filter_map do |call|
              next unless %w[const prop].include?(call.message.to_s)
              next unless call.receiver.to_s == "self"

              name = Array(call.arguments)[0].to_s.strip[/\A:([A-Za-z_]\w*)\z/, 1]
              type = Array(call.arguments)[1].to_s.strip
              next if name.to_s.empty? || type.empty?

              owner = ruby_t_struct_owner_for_line(call.line)
              next if owner.to_s.empty?

              {
                owner: owner,
                name: name,
                type: normalize_text(type),
                line: call.line,
                span: call.span,
              }
            end.uniq { |field| [field.fetch(:owner), field.fetch(:name), field.fetch(:line)] }
          else
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
      end

      def ruby_t_struct_containers
        return [] unless @language == "ruby"

        @ruby_t_struct_containers ||= begin
          if fact_document?
            Array(@facts[:owner_defs]).filter_map do |owner|
              line = @document.lines[owner.line.to_i - 1].to_s
              next unless line.match?(/<\s*T::Struct\b/)

              {
                owner: owner.name.to_s,
                line: owner.line,
                span: owner.span,
              }
            end.uniq { |entry| [entry.fetch(:owner), entry.fetch(:line)] }
          else
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
      end

      def ruby_ivar_protocol_records(known_states)
        return [] unless @language == "ruby"

        records = []
        walk_tree(@document.root) do |node|
          next unless %w[body_statement call].include?(node.kind.to_s)

          text = node_text(node)
          text.scan(/(@[a-z_]\w*)\.([a-z_]\w*[!?=]?)/) do |field, protocol|
            line = node_line(node)
            owner = lexical_owner_for_line(line).to_s
            next if owner.empty?
            next unless Set.new(Array(known_states[owner]).map { |known| canonical_state_field(known) }).include?(field)

            records << {
              "language" => @language,
              "path" => rel(@document.file),
              "owner" => owner,
              "function" => method_for_line(line),
              "field" => field,
              "protocol" => protocol,
              "line" => line,
              "span" => node_span(node),
              "key" => state_key(owner, field),
            }
          end
        end
        records
      end

      def lexical_owner_for_line(line)
        Array(@facts[:owner_defs]).select do |owner|
          span = Array(owner.span)
          span[0].to_i <= line.to_i && span[2].to_i >= line.to_i
        end.max_by { |owner| Array(owner.span)[0].to_i }&.name
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
        ruby_type_profile.literal_text_type(text, constant_types)
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

        owner_record_for_line(line)&.name || file_owner
      end

      def owner_record_for_line(line)
        Array(@facts[:owner_defs]).select do |owner|
          span = Array(owner.span)
          span[0].to_i <= line.to_i && span[2].to_i >= line.to_i
        end.max_by { |owner| Array(owner.span)[0].to_i }
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

      def parent_node(node)
        node_cache(node).fetch(:parent) do
          node_cache(node)[:parent] = node.parent
        end
      rescue StandardError
        nil
      end

      def node_line(node)
        return node.line.to_i if node.respond_to?(:line)

        node_cache(node).fetch(:line) do
          node_cache(node)[:line] = node.start_point.row + 1
        end
      rescue StandardError
        1
      end

      def node_span(node)
        return node.span if node.respond_to?(:span)

        node_cache(node).fetch(:span) do
          node_cache(node)[:span] = [node.start_point.row + 1, node.start_point.column, node.end_point.row + 1, node.end_point.column]
        end
      rescue StandardError
        nil
      end

      def node_text(node)
        return "" unless node
        return node.source.to_s.strip if node.respond_to?(:source) && !node.source.to_s.empty?
        return node.canon_source.to_s.strip if node.respond_to?(:canon_source) && !node.canon_source.to_s.empty?
        return fact_call_text(node) if node.respond_to?(:message) && node.respond_to?(:receiver)
        return method_body_text(node) if node.respond_to?(:name) && node.respond_to?(:span) && !node.respond_to?(:text)
        return node.text.to_s.strip if node.respond_to?(:text)
        return node.raw.to_s.strip if node.respond_to?(:raw) && !node.raw.to_s.empty?

        node_cache(node).fetch(:text) do
          node_cache(node)[:text] = node&.text.to_s.strip
        end
      rescue StandardError
        ""
      end

      def fact_call_text(call)
        receiver = call.receiver.to_s
        message = call.message.to_s
        sep = call.respond_to?(:safe_navigation) && call.safe_navigation ? "&." : "."
        args = Array(call.arguments).map(&:to_s)
        suffix = args.empty? ? "" : "(#{args.join(", ")})"
        receiver.empty? || receiver == "self" ? "#{message}#{suffix}" : "#{receiver}#{sep}#{message}#{suffix}"
      end

      def method_body_text(fn)
        method_body_lines(fn).map { |_line_no, raw| raw }.join("\n")
      end

      def normalize_text(text)
        text.to_s.strip.gsub(/\s+/, " ")
      end

      def source_line_span(line, line_no)
        text = line.to_s.chomp
        start_column = line.to_s.index(line.to_s.strip) || 0
        [line_no, start_column, line_no, text.length]
      end

      def line_indent(line)
        line[/\A\s*/].to_s.length
      end
    end
  end

end
