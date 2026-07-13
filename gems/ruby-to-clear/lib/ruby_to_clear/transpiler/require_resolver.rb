# frozen_string_literal: true

module RubyToClear
  class Transpiler
    module RequireResolver
    private

    def preload_required_metadata(program_node)
      return unless @source_path
      return unless program_node.respond_to?(:statements)

      require_relative_paths(program_node.statements).each do |relative|
        path = File.expand_path(relative.end_with?(".rb") ? relative : "#{relative}.rb", File.dirname(@source_path))
        collect_metadata_from_file(path)
      end
      constant_namespace_metadata_paths(program_node.statements).each do |path|
        collect_metadata_from_file(path)
      end
    end

    def require_relative_paths(statements_node)
      return [] unless statements_node

      paths = []
      walk = lambda do |node|
        return unless node.is_a?(Prism::Node)

        if node.is_a?(Prism::CallNode) && node.receiver.nil? && node.name.to_s == "require_relative"
          arg = node.arguments&.arguments&.first
          paths << arg.content if arg.is_a?(Prism::StringNode)
        end

        node.child_nodes.each { |child| walk.call(child) if child }
      end
      walk.call(statements_node)
      paths
    end

    def collect_local_requires_from_node(program_node)
      return unless program_node.respond_to?(:statements)

      top_level_require_relative_paths(program_node.statements).each do |relative|
        @required_files << clear_require_path(relative)
      end

      suppressed = suppressed_require_relative_files(program_node.statements)
      module_function_dependency_paths(program_node.statements).each do |path|
        next if suppressed.include?(path)
        next if @source_path && File.expand_path(path) == File.expand_path(@source_path)

        @required_files << clear_require_path_for_file(path)
      end
    end

    def top_level_require_relative_paths(statements_node)
      return [] unless statements_node

      statements_node.body.filter_map do |node|
        next unless node.is_a?(Prism::CallNode)
        next unless node.receiver.nil? && node.name.to_s == "require_relative"
        next if suppress_clear_require?(node)

        arg = node.arguments&.arguments&.first
        arg.content if arg.is_a?(Prism::StringNode)
      end
    end

    def suppress_clear_require?(node)
      arg = node.respond_to?(:arguments) ? node.arguments&.arguments&.first : nil
      start_offset =
        if arg&.location
          arg.location.start_offset
        elsif node.respond_to?(:message_loc) && node.message_loc
          node.message_loc.start_offset
        else
          node.location.start_offset
        end
      line_start = @source.rindex("\n", start_offset) || -1
      line_end = @source.index("\n", start_offset) || @source.length
      line = @source[(line_start + 1)...line_end]
      return true if line.include?("ruby-to-clear: no-require")

      if arg.is_a?(Prism::StringNode)
        return @source.each_line.any? do |source_line|
          source_line.include?("require_relative") &&
            source_line.include?(arg.content) &&
            source_line.include?("ruby-to-clear: no-require")
        end
      end

      false
    end

    def clear_require_path(relative)
      normalized = relative.sub(%r{\A\./}, "")
      normalized = normalized.sub(/\.rb\z/, "")
      "#{normalized}.clear"
    end

    def clear_require_path_for_file(path)
      return clear_require_path(path) unless @source_path

      base = Pathname.new(File.expand_path(File.dirname(@source_path)))
      relative = Pathname.new(File.expand_path(path)).relative_path_from(base).to_s
      clear_require_path(relative)
    end

    def suppressed_require_relative_files(statements_node)
      return Set.new unless statements_node && @source_path

      files = Set.new
      statements_node.body.each do |node|
        next unless node.is_a?(Prism::CallNode)
        next unless node.receiver.nil? && node.name.to_s == "require_relative"
        next unless suppress_clear_require?(node)

        arg = node.arguments&.arguments&.first
        next unless arg.is_a?(Prism::StringNode)

        relative = arg.content.end_with?(".rb") ? arg.content : "#{arg.content}.rb"
        files << File.expand_path(relative, File.dirname(@source_path))
      end
      files
    end

    def module_function_dependency_paths(statements_node)
      return [] unless statements_node && @source_path

      paths = Set.new
      walk = lambda do |node|
        return unless node.is_a?(Prism::Node)

        if node.is_a?(Prism::CallNode) &&
           (node.receiver.is_a?(Prism::ConstantReadNode) || node.receiver.is_a?(Prism::ConstantPathNode))
          receiver_name = node.receiver.location.slice.strip
          receiver_candidates = [receiver_name]
          receiver_candidates << receiver_name.split("::").last if receiver_name.include?("::")
          clear_name = clear_function_name(node.name.to_s)
          if receiver_candidates.any? { |name| @module_function_names[name].include?(clear_name) }
            constant_namespace_metadata_candidates(receiver_name, @source_path).each { |path| paths << path }
          end
        end

        node.child_nodes.each { |child| walk.call(child) if child }
      end
      walk.call(statements_node)
      paths.to_a
    end

    def collect_metadata_from_file(path)
      return if @loaded_metadata_files.include?(path)
      return if @source_path && File.expand_path(path) == File.expand_path(@source_path)
      return unless File.file?(path)

      @loaded_metadata_files << path
      File.read(path).scan(/#\s*ruby-to-clear:\s*data-api\s*\n\s*([A-Z][A-Z0-9_]*)\s*=/) do |match|
        @imported_data_constant_names << match.first
      end
      result = Prism.parse_file(path)
      return if result.failure?

      record_imported_prefixed_instance_methods(result.value)

      old_collecting_imported_metadata = @collecting_imported_metadata
      union_names_before = @union_types.keys.to_set
      @collecting_imported_metadata = true
      begin
        collect_type_aliases_from_node(result.value)
        require_relative_paths(result.value.statements).each do |relative|
          nested = File.expand_path(relative.end_with?(".rb") ? relative : "#{relative}.rb", File.dirname(path))
          collect_metadata_from_file(nested)
        end
        constant_namespace_metadata_paths(result.value.statements, source_path: path).each do |nested|
          collect_metadata_from_file(nested)
        end
        collect_struct_fields_from_node(result.value)
        collect_type_aliases_from_node(result.value)
        collect_ast_node_variants_from_node(result.value)
        collect_mixin_metadata(result.value)
        record_imported_prefixed_instance_methods(result.value)
        collect_method_signature_metadata_from_node(result.value)
        collect_method_params_from_node(result.value)
        collect_constant_storage_names_from_node(result.value)
        collect_imported_data_constant_names_from_node(result.value)
        preload_class_instance_metadata(result.value)
      ensure
        @imported_union_names.merge(@union_types.keys.to_set - union_names_before)
        @collecting_imported_metadata = old_collecting_imported_metadata
      end
    rescue StandardError
      nil
    end

    def record_imported_prefixed_instance_methods(program_node)
      duplicates = duplicate_instance_method_names(program_node)
      @mixin_methods.each_value do |methods|
        methods.each { |_sig, fn| duplicates << clear_function_name(fn.name.to_s) }
      end
      walk = lambda do |node|
        return unless node.is_a?(Prism::Node)

        if node.is_a?(Prism::ClassNode)
          class_name = node.constant_path.location.slice.strip.split("::").last
          collect_instance_method_names(node).each do |method_name|
            @imported_prefixed_instance_methods << [class_name, method_name] if duplicates.include?(method_name)
          end
        elsif node.is_a?(Prism::ConstantWriteNode) && struct_new_field_names(node.value)
          class_name = node.name.to_s
          body_nodes = node.value.block&.body&.body || []
          collect_instance_method_names_from_body_nodes(body_nodes).each do |method_name|
            @imported_prefixed_instance_methods << [class_name, method_name] if duplicates.include?(method_name)
          end
        end
        node.child_nodes.each { |child| walk.call(child) if child }
      end
      walk.call(program_node)
    end

    def constant_namespace_metadata_paths(statements_node, source_path: @source_path)
      return [] unless statements_node && source_path

      paths = Set.new
      walk = lambda do |node|
        return unless node.is_a?(Prism::Node)

        if node.is_a?(Prism::ConstantPathNode)
          raw = node.location.slice.strip
          constant_namespace_metadata_candidates(raw, source_path).each { |path| paths << path }
        end

        if node.is_a?(Prism::CallNode) &&
           (node.receiver.is_a?(Prism::ConstantReadNode) || node.receiver.is_a?(Prism::ConstantPathNode))
          raw = node.receiver.location.slice.strip
          constant_namespace_metadata_candidates(raw, source_path).each { |path| paths << path }
        end

        node.child_nodes.each { |child| walk.call(child) if child }
      end
      walk.call(statements_node)
      paths.to_a
    end

    def constant_namespace_metadata_candidates(path, source_path)
      segments = path.to_s.split("::")
      return [] if segments.empty?

      first = underscore_constant_name(segments.first)
      last = underscore_constant_name(segments.last)
      source_ancestor_dirs(File.dirname(source_path)).each do |dir|
        candidates = [
          File.join(dir, "#{first}.rb"),
          File.join(dir, first, "#{first}.rb"),
          File.join(dir, first, "#{last}.rb")
        ].uniq.select { |candidate| File.file?(candidate) }
        return candidates unless candidates.empty?
      end
      []
    end

    def source_ancestor_dirs(dir)
      dirs = []
      current = File.expand_path(dir)
      loop do
        dirs << current
        parent = File.dirname(current)
        break if parent == current

        current = parent
      end
      dirs
    end
    end
  end
end
