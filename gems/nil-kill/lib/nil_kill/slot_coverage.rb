# typed: false
# frozen_string_literal: true

module NilKill
  class SlotCoverage
    STRUCTURAL_CATEGORIES = %w[params returns ivars struct_fields].freeze
    COLLECTION_CATEGORIES = %w[arrays hashes].freeze
    COUNT_KEYS = %w[total strong weak untyped nilable weak_collection].freeze

    class << self
      def files_for(inputs)
        roots = inputs.empty? ? ["src"] : inputs
        roots.flat_map do |input|
          path = File.expand_path(input, ROOT)
          if File.directory?(path)
            Dir.glob(File.join(path, "**", "*.rb"))
          elsif File.file?(path) && path.end_with?(".rb")
            [path]
          else
            []
          end
        end.uniq.sort
      end

      def scan(inputs = ["src"])
        new(files_for(inputs)).summaries
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

    def initialize(files)
      @files = files
    end

    def summaries
      SourceIndex.reset_global_shape_indexes
      @files.map { |path| scan_file(path) }
    end

    private

    def scan_file(path)
      summary = self.class.empty_summary(NilKill.rel(path))
      index = SourceIndex.new(path)
      add_method_slots!(summary, index.methods)
      add_ivar_slots!(summary, path)
      add_struct_field_slots!(summary, index.struct_declarations, path)
      self.class.finalize_summary!(summary)
    end

    def add_method_slots!(summary, methods)
      methods.each do |method|
        Array(method["params"]).each do |param|
          add_slot!(summary, "params", param["type"])
        end
        add_slot!(summary, "returns", return_type_for(method))
      end
    end

    def return_type_for(method)
      sig = method["sig"].to_s
      return nil if sig.empty?
      NilKill.extract_return_type(sig) || (signature_void?(sig) ? "NilClass" : nil)
    end

    def signature_void?(sig)
      parsed = Prism.parse(sig)
      return sig.include?(".void") unless parsed.success?

      contains_call_named?(parsed.value, :void)
    end

    def contains_call_named?(node, name)
      return false unless node.is_a?(Prism::Node)
      return true if node.is_a?(Prism::CallNode) && node.name == name

      node.compact_child_nodes.any? { |child| contains_call_named?(child, name) }
    end

    def add_ivar_slots!(summary, path)
      parsed = SourceIndex.parsed_file(path)
      return unless parsed.success?

      typed = {}
      untyped = Set.new
      collect_ivar_slots(parsed.value, [], typed, untyped)
      typed.each_value { |types| add_slot!(summary, "ivars", union_slot_type(types)) }
      (untyped - typed.keys.to_set).each { add_slot!(summary, "ivars", nil) }
    end

    def collect_ivar_slots(node, scope, typed, untyped)
      case node
      when Prism::ClassNode, Prism::ModuleNode
        next_scope = scope + [const_name(node.constant_path)]
        node.compact_child_nodes.each { |child| collect_ivar_slots(child, next_scope, typed, untyped) }
        return
      when Prism::InstanceVariableWriteNode, Prism::ClassVariableWriteNode
        key = [scope.join("::"), node.name.to_s]
        if (type = tlet_type(node.value))
          typed[key] ||= []
          typed[key] << type
        else
          untyped << key
        end
      end
      node.compact_child_nodes.each { |child| collect_ivar_slots(child, scope, typed, untyped) } if node.respond_to?(:compact_child_nodes)
    end

    def add_struct_field_slots!(summary, struct_declarations, path)
      Array(struct_declarations).each do |decl|
        Array(decl["fields"]).each { add_slot!(summary, "struct_fields", rbi_field_type(decl["class"], _1)) }
      end

      parsed = SourceIndex.parsed_file(path)
      return unless parsed.success?

      collect_t_struct_fields(parsed.value, [], false).each do |field|
        add_slot!(summary, "struct_fields", field.fetch("type"))
      end
    end

    def collect_t_struct_fields(node, scope, in_t_struct)
      case node
      when Prism::ClassNode
        next_scope = scope + [const_name(node.constant_path)]
        next_in_t_struct = t_struct_superclass?(node.superclass)
        return node.compact_child_nodes.flat_map { |child| collect_t_struct_fields(child, next_scope, next_in_t_struct) }
      when Prism::ModuleNode
        next_scope = scope + [const_name(node.constant_path)]
        return node.compact_child_nodes.flat_map { |child| collect_t_struct_fields(child, next_scope, false) }
      when Prism::CallNode
        fields = []
        if in_t_struct && t_struct_field_call?(node)
          args = node.arguments&.arguments || []
          fields << { "class" => scope.join("::"), "name" => symbol_name(args[0]), "type" => args[1]&.slice }
        end
        fields + node.compact_child_nodes.flat_map { |child| collect_t_struct_fields(child, scope, in_t_struct) }
      else
        return [] unless node.respond_to?(:compact_child_nodes)
        node.compact_child_nodes.flat_map { |child| collect_t_struct_fields(child, scope, in_t_struct) }
      end
    end

    def t_struct_superclass?(node)
      node&.slice == "T::Struct"
    end

    def t_struct_field_call?(node)
      node.receiver.nil? && %i[const prop].include?(node.name) && symbol_name((node.arguments&.arguments || [])[0])
    end

    def symbol_name(node)
      node.unescaped if node.is_a?(Prism::SymbolNode)
    end

    def tlet_type(node)
      return nil unless node.is_a?(Prism::CallNode)
      return nil unless node.name == :let && node.receiver&.slice == "T"

      (node.arguments&.arguments || [])[1]&.slice
    end

    def rbi_field_type(klass, field)
      SourceIndex.rbi_field_types[[klass, field]]
    end

    def union_slot_type(types)
      unique = Array(types).compact.uniq
      return nil if unique.empty?
      return unique.first if unique.size == 1

      "T.any(#{unique.sort.join(", ")})"
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

      inner = normalize_slot_type(NilKill.strip_nilable_type(type))
      return "untyped" if inner == "T.untyped"
      return "weak" if inner.include?("T.any(") || NilKill.weak_type?(inner)

      "strong"
    end

    def nilable_slot_type?(type)
      type.to_s.include?("T.nilable(") || type == "NilClass"
    end

    def weak_collection_slot_type?(type)
      inner = normalize_slot_type(NilKill.strip_nilable_type(type))
      ["T::Array[", "T::Hash[", "T::Set[", "T::Enumerable["].any? { |prefix| inner.start_with?(prefix) } &&
        inner.include?("T.untyped")
    end

    def collection_kind(type)
      inner = normalize_slot_type(NilKill.strip_nilable_type(type))
      return "array" if inner == "Array" || inner.start_with?("Array[", "T::Array[")
      return "hash" if inner == "Hash" || inner.start_with?("Hash[", "T::Hash[")

      nil
    end

    def normalize_slot_type(type)
      NilKill.normalize_static_sorbet_type(type.to_s.strip)
    end

    def const_name(node)
      return "" unless node

      node.respond_to?(:full_name) ? (node.full_name rescue node.slice) : node.slice
    end
  end
end
