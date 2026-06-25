# typed: false
# frozen_string_literal: true

require "tempfile"
require "json"

begin
  require "espalier/static_evidence"
rescue LoadError
  $LOAD_PATH.unshift(File.expand_path("../../../espalier/lib", __dir__))
  require "espalier/static_evidence"
end


module NilKill
  class StaticEvidence
    def self.build(targets = nil, root: NilKill::ROOT, language: nil, vcs: nil, include_annotations: true)
      if defined?(NilKill::SourceIndex)
        ENV["FACT_MINE_NORETURN_METHODS"] = NilKill::SourceIndex.noreturn_methods.to_a.join(",")
      end
      tmp_shapes = nil
      if defined?(NilKill::SourceIndex) && (NilKill::SourceIndex.global_struct_field_hash_shapes&.any? || NilKill::SourceIndex.global_struct_field_array_shapes&.any?)
        tmp_shapes = Tempfile.new(["nil-kill-global-shapes", ".json"])
        tmp_shapes.write(JSON.pretty_generate({
          "struct_field_hash_shapes" => NilKill::SourceIndex.global_struct_field_hash_shapes || {},
          "struct_field_array_shapes" => NilKill::SourceIndex.global_struct_field_array_shapes || {}
        }))
        tmp_shapes.close
        ENV["FACT_MINE_GLOBAL_SHAPES_FILE"] = tmp_shapes.path
      end

      begin
        evidence = Espalier::StaticEvidence.build(
          targets,
          root: root,
          language: language,
          vcs: vcs,
          include_annotations: include_annotations
        )
        if evidence["facts"] && evidence["facts"]["type_definitions"]
          class_fields = Set.new(Array(evidence["fields"]).map { |f| [f["owner"], f["name"]] })
          evidence["facts"]["type_definitions"].each do |d|
            if d["kind"] == "state_field" && !d["name"].to_s.start_with?("@")
              lang = d["language"]
              if %w[ruby python javascript typescript].include?(lang.to_s)
                if class_fields.include?([d["owner"], d["name"]]) && d["owner"] != "Client"
                  old_name = d["name"]
                  new_name = "@#{old_name}"
                  d["name"] = new_name
                  if d["id"]
                    d["id"] = d["id"].gsub("\u0000#{old_name}\u0000", "\u0000#{new_name}\u0000")
                  end
                end
              end
            end
          end
        end
        overlay_nil_kill_language_capabilities!(evidence)
        append_ruby_struct_definitions!(evidence, root)
        evidence
      ensure
        if tmp_shapes
          tmp_shapes.unlink
          ENV.delete("FACT_MINE_GLOBAL_SHAPES_FILE")
        end
      end
    end

    def self.append_ruby_struct_definitions!(evidence, root)
      Array(evidence["files"]).each do |f|
        next unless f["language"] == "ruby"
        rel_path = f["path"]
        abs_path = File.expand_path(rel_path, root)
        next unless File.file?(abs_path)

        begin
          parsed = NilKill::Syntax.parse_file(abs_path)
          next unless parsed.success?

          definitions = []
          declared_classes = Set.new
          walker = RubyStructWalker.new(rel_path, declared_classes)
          walker.collect_declared_classes(parsed.value, [], declared_classes)
          walker.walk(parsed.value, [], definitions)

          evidence["facts"] ||= {}
          evidence["facts"]["type_definitions"] ||= []
          evidence["facts"]["type_definitions"].concat(definitions)
        rescue StandardError
          next
        end
      end
    end
    private_class_method :append_ruby_struct_definitions!

    class RubyStructWalker
      def initialize(rel_path, declared_classes)
        @rel_path = rel_path
        @declared_classes = declared_classes
      end

      def collect_declared_classes(node, namespace, declared, visited = Set.new)
        return unless node
        return if visited.include?(node.object_id)
        visited.add(node.object_id)

        case node
        when NilKill::Syntax::ClassNode, NilKill::Syntax::ModuleNode
          name = node.constant_path&.slice&.to_s
          if name
            full_name = (namespace + [name]).join("::")
            declared.add(full_name)
            collect_declared_classes(node.body, namespace + [name], declared, visited)
          end
        when NilKill::Syntax::ConstantWriteNode
          val = node.value
          if val.is_a?(NilKill::Syntax::CallNode) && val.receiver&.slice&.to_s == "Struct" && val.name == :new
            full_name = (namespace + [node.name.to_s]).join("::")
            declared.add(full_name)
            if val.block && val.block.body
              collect_declared_classes(val.block.body, namespace + [node.name.to_s], declared, visited)
            end
          end
        else
          if node.respond_to?(:child_nodes)
            node.child_nodes.each { |child| collect_declared_classes(child, namespace, declared, visited) }
          end
        end
      end

      def resolve_module_name(name, namespace)
        namespace.size.downto(0) do |i|
          prefix = namespace[0...i]
          candidate = (prefix + [name]).join("::")
          return candidate if @declared_classes.include?(candidate)
        end
        name
      end

      def walk(node, namespace, definitions, in_method = false, visited = Set.new)
        return unless node
        return if visited.include?(node.object_id)
        visited.add(node.object_id)

        case node
        when NilKill::Syntax::ClassNode, NilKill::Syntax::ModuleNode
          name = node.constant_path&.slice&.to_s
          if name
            walk(node.body, namespace + [name], definitions, in_method, visited)
          end
        when NilKill::Syntax::ConstantWriteNode
          val = node.value
          if val.is_a?(NilKill::Syntax::CallNode) && val.receiver&.slice&.to_s == "Struct" && val.name == :new
            class_name = (namespace + [node.name.to_s]).join("::")
            args = val.arguments&.arguments || []
            args.each do |arg|
              next unless arg.is_a?(NilKill::Syntax::SymbolNode)
              field_name = arg.slice.to_s.delete_prefix(":")
              definitions << {
                "id" => ["ruby", @rel_path, class_name, "state_field", field_name, node.location.start_line, "ruby-struct"].map(&:to_s).join("\u0000"),
                "language" => "ruby",
                "type_system" => "ruby-struct",
                "kind" => "state_field",
                "path" => @rel_path,
                "owner" => class_name,
                "name" => field_name,
                "line" => node.location.start_line,
                "declared_type" => nil
              }
            end

            if val.block && val.block.body
              walk(val.block.body, namespace + [node.name.to_s], definitions, in_method, visited)
            end
          end
        when NilKill::Syntax::CallNode
          if !in_method
            if node.name == :include && node.receiver.nil?
              args = node.arguments&.arguments || []
              args.each do |arg|
                module_name = arg.slice.to_s
                qualified_name = resolve_module_name(module_name, namespace)
                owner_name = namespace.join("::")
                definitions << {
                  "id" => ["ruby", @rel_path, owner_name, "included_module", qualified_name, node.location.start_line].map(&:to_s).join("\u0000"),
                  "language" => "ruby",
                  "kind" => "included_module",
                  "path" => @rel_path,
                  "owner" => owner_name,
                  "name" => qualified_name,
                  "line" => node.location.start_line
                }
              end
            elsif %i[const prop].include?(node.name) && node.receiver.nil?
              args = node.arguments&.arguments || []
              if args.size >= 2
                field_arg = args[0]
                type_arg = args[1]
                if field_arg.is_a?(NilKill::Syntax::SymbolNode)
                  field_name = field_arg.slice.to_s.delete_prefix(":")
                  class_name = namespace.join("::")
                  definitions << {
                    "id" => ["ruby", @rel_path, class_name, "state_field", field_name, node.location.start_line, "sorbet"].map(&:to_s).join("\u0000"),
                    "language" => "ruby",
                    "type_system" => "sorbet",
                    "kind" => "state_field",
                    "path" => @rel_path,
                    "owner" => class_name,
                    "name" => field_name,
                    "line" => node.location.start_line,
                    "declared_type" => type_arg.slice
                  }
                end
              end
            end
          end
        when NilKill::Syntax::InstanceVariableWriteNode
          val = node.value
          if val.is_a?(NilKill::Syntax::CallNode) && val.receiver&.slice&.to_s == "T" && val.name == :let
            args = val.arguments&.arguments || []
            if args.size >= 2
              type_arg = args[1]
              field_name = node.name.to_s
              class_name = namespace.join("::")
              definitions << {
                "id" => ["ruby", @rel_path, class_name, "state_field", field_name, node.location.start_line, "sorbet"].map(&:to_s).join("\u0000"),
                "language" => "ruby",
                "type_system" => "sorbet",
                "kind" => "state_field",
                "path" => @rel_path,
                "owner" => class_name,
                "name" => field_name,
                "line" => node.location.start_line,
                "declared_type" => type_arg.slice.to_s
              }
            end
          end
        end

        if node.class.name.to_s.end_with?("StatementsNode", "BodyStatementNode")
          stmts = node.child_nodes
          stmts.each_with_index do |child, idx|
            child_in_method = in_method
            if child.is_a?(NilKill::Syntax::DefNode)
              child_in_method = true
              prev_stmt = idx.positive? ? stmts[idx - 1] : nil
              if prev_stmt.is_a?(NilKill::Syntax::CallNode) && prev_stmt.name == :sig
                sig_info = extract_sig_from_node(prev_stmt)
                ret = sig_info[:return_type]
                params = sig_info[:params]
                class_name = namespace.join("::")
                method_name = child.name.to_s
                line = child.location.start_line
                definitions << {
                  "id" => ["ruby", @rel_path, class_name, "method_signature", method_name, line, "sorbet"].map(&:to_s).join("\u0000"),
                  "language" => "ruby",
                  "type_system" => "sorbet",
                  "kind" => "method_signature",
                  "path" => @rel_path,
                  "owner" => class_name,
                  "name" => method_name,
                  "line" => line,
                  "signature" => prev_stmt.slice.to_s,
                  "return_type" => ret,
                  "params" => params,
                  "declared_type" => nil
                }
              end
            end
            walk(child, namespace, definitions, child_in_method, visited)
          end
        elsif node.respond_to?(:child_nodes)
          node.child_nodes.each { |child| walk(child, namespace, definitions, in_method, visited) }
        end
      end

      def extract_sig_from_node(sig_node)
        info = { params: [], return_type: nil }
        block = sig_node.block
        if block && block.body
          stmts = block.body.respond_to?(:child_nodes) ? block.body.child_nodes : [block.body]
          stmts.each { |s| traverse_sig_chain(s, info) }
        end
        info
      end

      def traverse_sig_chain(node, info)
        return unless node.is_a?(NilKill::Syntax::CallNode)

        case node.name
        when :returns
          args = node.arguments&.arguments || []
          info[:return_type] = args[0]&.slice&.to_s if args[0]
        when :void
          info[:return_type] = "void"
        when :params
          args = node.arguments&.arguments || []
          args.each do |arg|
            if arg.is_a?(NilKill::Syntax::AssocNode)
              k = arg.key&.slice&.to_s&.delete_suffix(":")
              v = arg.value&.slice&.to_s
              info[:params] << { "name" => k, "type" => v }
            elsif arg.is_a?(NilKill::Syntax::HashNode) || arg.is_a?(NilKill::Syntax::KeywordHashNode)
              arg.elements.each do |pair|
                if pair.is_a?(NilKill::Syntax::AssocNode)
                  k = pair.key&.slice&.to_s&.delete_suffix(":")
                  v = pair.value&.slice&.to_s
                  info[:params] << { "name" => k, "type" => v }
                end
              end
            end
          end
        end

        if node.receiver
          traverse_sig_chain(node.receiver, info)
        end
      end
    end

    def self.overlay_nil_kill_language_capabilities!(evidence)
      return evidence unless defined?(NilKill::Languages)

      languages = Array(evidence.fetch("files", [])).map { |file| file["language"].to_s }
      languages.concat(Hash(evidence["language_capabilities"]).keys)
      evidence["language_capabilities"] = languages.reject(&:empty?).uniq.sort.to_h do |language|
        [language, NilKill::Languages.capability_for(language)]
      end
      evidence
    end
    private_class_method :overlay_nil_kill_language_capabilities!
  end
end
