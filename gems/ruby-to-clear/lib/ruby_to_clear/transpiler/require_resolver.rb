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
      signature_type_dependency_paths(program_node.statements).each do |path|
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
      signature_type_dependency_paths(program_node.statements).each do |path|
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

    def require_type_dependency(type_name)
      return unless @source_path

      raw = type_name.to_s.delete_prefix("?").sub(/<.*\z/, "").sub(/\[\](?:@set)?\z/, "")
      return if raw.empty? || %w[Any Auto Bool String Int64 Float64].include?(raw)

      constant_namespace_metadata_candidates(raw, @source_path).each do |path|
        next if File.expand_path(path) == File.expand_path(@source_path)

        @required_files << clear_require_path_for_file(path)
      end
    end

    def require_method_dependency(owner, method_name)
      return unless @source_path

      owner_names = [owner.to_s, owner.to_s.split("::").last].uniq
      paths = owner_names.flat_map do |owner_name|
        @method_source_paths[[owner_name, clear_function_name(method_name.to_s)]].to_a
      end.uniq
      paths.each do |path|
        next if File.expand_path(path) == File.expand_path(@source_path)

        @required_files << clear_require_path_for_file(path)
      end
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
        return if declaration_comment?(node, "ruby-to-clear: skip")

        if node.is_a?(Prism::CallNode) &&
           (node.receiver.is_a?(Prism::ConstantReadNode) || node.receiver.is_a?(Prism::ConstantPathNode))
          receiver_name = node.receiver.location.slice.strip
          receiver_candidates = [receiver_name]
          receiver_candidates << receiver_name.split("::").last if receiver_name.include?("::")
          clear_name = clear_function_name(node.name.to_s)
          if receiver_candidates.any? { |name| @module_function_names[name].include?(clear_name) }
            constant_namespace_metadata_candidates(receiver_name, @source_path, recursive: false).each { |path| paths << path }
          end
        end

        node.child_nodes.each { |child| walk.call(child) if child }
      end
      walk.call(statements_node)
      paths.to_a
    end

    def signature_type_dependency_paths(statements_node)
      return [] unless statements_node && @source_path

      constants = Set.new
      walk = lambda do |node, inside_type_surface = false|
        return unless node.is_a?(Prism::Node)
        return if declaration_comment?(node, "ruby-to-clear: skip")

        is_sig = node.is_a?(Prism::CallNode) && node.receiver.nil? && node.name.to_s == "sig"
        is_type_alias = node.is_a?(Prism::CallNode) && node.name.to_s == "type_alias" &&
          node.receiver.is_a?(Prism::ConstantReadNode) && node.receiver.name.to_s == "T"
        is_local_type_annotation = node.is_a?(Prism::CallNode) && %w[let cast].include?(node.name.to_s) &&
          node.receiver.is_a?(Prism::ConstantReadNode) && node.receiver.name.to_s == "T"
        if inside_type_surface && (node.is_a?(Prism::ConstantReadNode) || node.is_a?(Prism::ConstantPathNode))
          constants << node.location.slice.strip
        end
        node.child_nodes.each do |child|
          walk.call(child, inside_type_surface || is_sig || is_type_alias || is_local_type_annotation) if child
        end
      end
      walk.call(statements_node)

      constants.each_with_object(Set.new) do |constant, paths|
        constant_namespace_metadata_candidates(constant, @source_path).each { |path| paths << path }
      end.to_a
    end

    def collect_metadata_from_file(path)
      return if @loaded_metadata_files.include?(path)
      if @source_path && File.expand_path(path) == File.expand_path(@source_path)
        # The generated dependency graph can be cyclic even though metadata
        # loading must terminate. Record the root declarations at the cut edge
        # so imported files choose the same collision-free public type names
        # they choose when transpiled as roots themselves.
        unless @metadata_cycle_type_owners.any?
          result = Prism.parse_file(path)
          @metadata_cycle_type_owners.merge(declared_type_owner_names(result.value)) unless result.failure?
        end
        return
      end
      return unless File.file?(path)

      @loaded_metadata_files << path
      File.read(path).scan(/#\s*ruby-to-clear:\s*data-api\s*\n\s*([A-Z][A-Z0-9_]*)\s*=/) do |match|
        @imported_data_constant_names << match.first
      end
      result = Prism.parse_file(path)
      return if result.failure?
      record_method_source_paths(result.value, path)

      old_collecting_imported_metadata = @collecting_imported_metadata
      @collecting_imported_metadata = true
      old_metadata_source_lines = @current_metadata_source_lines
      @current_metadata_source_lines = File.readlines(path)
      union_names_before = @union_types.keys.to_set
      begin
        collect_public_class_visibility_metadata(result.value)
        # Collect type aliases in this file first so that they are known
        # when resolving recursive dependencies.
        collect_type_aliases_from_node(result.value)

        # Parse dependencies recursively.
        require_relative_paths(result.value.statements).each do |relative|
          nested = File.expand_path(relative.end_with?(".rb") ? relative : "#{relative}.rb", File.dirname(path))
          collect_metadata_from_file(nested)
        end
        constant_namespace_metadata_paths(result.value.statements, source_path: path).each do |nested|
          collect_metadata_from_file(nested)
        end

        configure_imported_emitted_type_names!(result.value)

        # Now collect signatures
        record_imported_prefixed_instance_methods(result.value)
        collect_method_signature_metadata_from_node(result.value)
        # Contribute this file's call-graph edges to the shared fallibility
        # set; the root's single fixpoint (transpile) resolves cross-file
        # chains once every imported file has been seen.
        collect_fallibility_edges!(result.value)
        collect_method_params_from_node(result.value)
        preload_class_instance_metadata(result.value)

        # Struct field expansion consumes mixin storage metadata, so imported
        # mixins must be indexed before their including structs are collected.
        collect_mixin_metadata(result.value)
        synthesize_closed_interface_union!(result.value, "Emittable")
        synthesize_closed_interface_union!(result.value, "Locatable")
        collect_struct_fields_from_node(result.value)
        collect_ast_node_variants_from_node(result.value)
        collect_enum_variant_names_from_node(result.value)
        collect_constant_storage_names_from_node(result.value)
        collect_imported_data_constant_names_from_node(result.value)
      ensure
        @imported_union_names.merge(@union_types.keys.to_set - union_names_before)
        @current_metadata_source_lines = old_metadata_source_lines
        @collecting_imported_metadata = old_collecting_imported_metadata
      end
    rescue StandardError
      nil
    end

    def collect_public_class_visibility_metadata(program_node)
      walk = lambda do |node, namespace = []|
        return unless node.is_a?(Prism::Node)

        if node.is_a?(Prism::ClassNode)
          raw_name = node.constant_path.location.slice.strip.delete_prefix("::")
          name = raw_name.include?("::") ? raw_name : (namespace + [raw_name]).join("::")
          if declaration_comment?(node, "ruby-to-clear: pub")
            @public_class_names << name
            @public_class_names << name.split("::").last
          end
          node.child_nodes.each { |child| walk.call(child, name.split("::")) if child }
          return
        end

        if node.is_a?(Prism::ModuleNode)
          raw_name = node.constant_path.location.slice.strip.delete_prefix("::")
          name = raw_name.include?("::") ? raw_name : (namespace + [raw_name]).join("::")
          node.child_nodes.each { |child| walk.call(child, name.split("::")) if child }
          return
        end

        node.child_nodes.each { |child| walk.call(child, namespace) if child }
      end
      walk.call(program_node)
    end

    def record_method_source_paths(program_node, path)
      walk = lambda do |node, namespace = []|
        return unless node.is_a?(Prism::Node)

        if node.is_a?(Prism::ClassNode) || node.is_a?(Prism::ModuleNode)
          raw_name = node.constant_path.location.slice.strip.delete_prefix("::")
          owner = raw_name.include?("::") ? raw_name : (namespace + [raw_name]).join("::")
          @declared_owner_source_paths[owner] << path
          @declared_owner_source_paths[owner.split("::").first.to_s] << path
          # A class nested inside another (`class ClearParser; class
          # ParsedVarForm < T::Struct`) is referenced by its BARE name from
          # code lexically inside the enclosing class - which is exactly how
          # the partial-class files spell it. Only the fully-qualified and
          # outermost spellings were registered, so constructor_parameter_
          # info's lazy owner lookup never found the defining file and the
          # call fell through to "Constructor call needs known field names".
          # The method table two lines below already registers the bare name;
          # this makes the owner table agree. Ambiguity is safe: the lazy
          # lookup only proceeds when exactly one file declares the name.
          @declared_owner_source_paths[owner.split("::").last.to_s] << path
          (node.body&.body || []).each do |statement|
            next unless statement.is_a?(Prism::DefNode)

            method = clear_function_name(statement.name.to_s)
            @method_source_paths[[owner, method]] << path
            @method_source_paths[[owner.split("::").last, method]] << path
          end
          node.child_nodes.each { |child| walk.call(child, owner.split("::")) if child }
          return
        end

        if node.is_a?(Prism::ConstantWriteNode) && struct_new_field_names(node.value)
          owner = (namespace + [node.name.to_s]).join("::")
          @declared_owner_source_paths[owner] << path
          @declared_owner_source_paths[owner.split("::").first.to_s] << path
          (node.value.block&.body&.body || []).each do |statement|
            next unless statement.is_a?(Prism::DefNode)

            method = clear_function_name(statement.name.to_s)
            @method_source_paths[[owner, method]] << path
            @method_source_paths[[node.name.to_s, method]] << path
          end
          return
        end

        node.child_nodes.each { |child| walk.call(child, namespace) if child }
      end
      walk.call(program_node)
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

    def constant_namespace_metadata_candidates(path, source_path, recursive: true)
      cache_key = [path.to_s, File.expand_path(source_path), recursive]
      cached = @constant_metadata_candidate_cache[cache_key]
      return cached if cached

      segments = path.to_s.split("::")
      return [] if segments.empty?

      # Content-based resolution first: the metadata walk records where each
      # class/module is DECLARED. The filename convention below stays as the
      # fallback, but a constant whose home file has a different basename
      # (e.g. `Schemas` living in type.rb — one strongly connected component
      # with Type, merged so CLEAR's acyclic module graph holds) resolves to
      # its true defining file instead of silently failing.
      [path.to_s, segments.first].uniq.each do |key|
        declared = @declared_owner_source_paths[key]
        # Only when the declaration site is UNIQUE: a class reopened across
        # files (FunctionSignature's forward stub) would otherwise import
        # every reopening — extra edges are how import cycles are born.
        next unless declared && declared.size == 1

        return @constant_metadata_candidate_cache[cache_key] = declared.to_a
      end

      first = underscore_constant_name(segments.first)
      last = underscore_constant_name(segments.last)
      metadata_source_ancestor_dirs(source_path).each do |dir|
        # A namespaced constant's defining file (its last segment) shadows the
        # namespace home: Widgets::Gadget lives in gadget.rb even when
        # widgets.rb exists. The namespace home stays as the fallback for
        # constants that really do live there.
        if segments.length > 1
          defining = File.join(dir, "#{last}.rb")
          return @constant_metadata_candidate_cache[cache_key] = [defining] if File.file?(defining)
        end
        candidates = [
          File.join(dir, "#{first}.rb"),
          File.join(dir, first, "#{first}.rb"),
          File.join(dir, first, "#{last}.rb")
        ].uniq.select { |candidate| File.file?(candidate) }
        return @constant_metadata_candidate_cache[cache_key] = candidates unless candidates.empty?

        # Ruby files in the compiler sometimes rely on an entrypoint's global
        # load order rather than declaring the direct require. Recover static
        # metadata from a uniquely named source file below the nearest common
        # source ancestor, but never guess when the basename is ambiguous.
        if recursive
          recursive_candidates = metadata_files_by_basename(dir).fetch("#{last}.rb", [])
          if recursive_candidates.length == 1
            return @constant_metadata_candidate_cache[cache_key] = recursive_candidates
          end
        end
      end
      @constant_metadata_candidate_cache[cache_key] = []
    end

    # Indexes a single ancestor dir's declared class/module names, so a
    # constructor call whose class lives in a file with a non-matching
    # basename (e.g. `Edit` in fixable_error.rb, discovered only via the
    # compiler entrypoint's global load order rather than a direct require)
    # can still be resolved. Deliberately NOT wired into the shared
    # constant_namespace_metadata_candidates path above - that function runs
    # for every constant referenced anywhere (types, method receivers, sig
    # surfaces), and a full per-file Prism parse of the ancestor tree on
    # every miss there is both far too broad (most misses are legitimately
    # unresolvable, e.g. builtin/stdlib names) and, for non-"ruby"-rooted
    # trees, unbounded (metadata_source_ancestor_dirs' fallback climbs to the
    # containing filesystem, not just the corpus). Callers must invoke this
    # only when actually resolving a constructor call, and only after the
    # cheap filename-convention tiers have already missed.
    def index_declared_owners_in_dir(dir)
      return if @declared_owner_dir_indexed.include?(dir)

      @declared_owner_dir_indexed << dir
      Dir[File.join(dir, "**", "*.rb")].each do |file|
        next unless File.file?(file)

        result = Prism.parse_file(file)
        next if result.failure?

        record_method_source_paths(result.value, file)
      end
    end

    def metadata_source_ancestor_dirs(source_path)
      dirs = source_ancestor_dirs(File.dirname(source_path))
      ruby_root = dirs.index { |dir| File.basename(dir) == "ruby" }
      # Namespace helpers commonly sit two directories below the source
      # root (annotator/helpers/*.rb referencing ast/), so the walk must
      # reach the grandparent even when no "ruby" root marker exists.
      ruby_root ? dirs[0..ruby_root] : dirs.first(3)
    end

    # Like metadata_source_ancestor_dirs, but for index_declared_owners_in_dir
    # callers only: a "ruby" root still bounds the walk to the corpus, but
    # with no such root (an isolated project, or a spec's Dir.mktmpdir) this
    # tries only the immediate source dir rather than metadata_source_
    # ancestor_dirs' first-3 fallback, which climbs out of the project into
    # its containing filesystem (/tmp, then /) - fine for the cheap filename-
    # only checks that fallback was designed for, but not for a full
    # recursive Prism parse of every directory it touches.
    def constructor_lookup_ancestor_dirs(source_path)
      dirs = source_ancestor_dirs(File.dirname(source_path))
      ruby_root = dirs.index { |dir| File.basename(dir) == "ruby" }
      ruby_root ? dirs[0..ruby_root] : dirs.first(1)
    end

    def metadata_files_by_basename(dir)
      @metadata_source_indexes[dir] ||= begin
        files = Dir[File.join(dir, "**", "*.rb")].select { |candidate| File.file?(candidate) }
        files.group_by { |candidate| File.basename(candidate) }
      end
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
