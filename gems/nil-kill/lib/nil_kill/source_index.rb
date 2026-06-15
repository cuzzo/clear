# typed: false
# frozen_string_literal: true

module NilKill
  class SourceIndex
    # Cross-file shape/type symbol table; class-level readers delegate
    # here so existing call sites are unchanged.
    class ShapeSymbolTable
      attr_reader :attribute_hash_shapes, :attribute_array_element_shapes,
        :struct_field_hash_shapes, :struct_field_array_element_shapes,
        :struct_field_static_types, :struct_fields_by_name, :struct_full_by_name

      def initialize
        @attribute_hash_shapes = {}
        @attribute_array_element_shapes = {}
        @struct_field_hash_shapes = {}
        @struct_field_array_element_shapes = {}
        @struct_field_static_types = {}
        @struct_fields_by_name = {}
        @struct_full_by_name = {}
      end
    end

    @shape_table = ShapeSymbolTable.new

    class << self
      attr_reader :noreturn_methods, :shape_table

      %i[attribute_hash_shapes attribute_array_element_shapes
         struct_field_hash_shapes struct_field_array_element_shapes
         struct_field_static_types struct_fields_by_name struct_full_by_name].each do |idx|
        define_method(idx) { @shape_table.public_send(idx) }
      end

      def reset_global_shape_indexes
        @shape_table = ShapeSymbolTable.new
        @rbi_field_types = nil
        @noreturn_methods = Set.new
        @source_lines = {}
        @parsed_files = {}
      end

      def rbi_field_types
        @rbi_field_types ||= load_rbi_field_types
      end

      def noreturn_methods
        @noreturn_methods ||= Set.new
      end

      def register_noreturn_method(name)
        return unless name && !name.to_s.empty?
        @noreturn_methods ||= Set.new
        @noreturn_methods << name.to_s
      end

      def source_lines(path)
        @source_lines ||= {}
        @source_lines[path] ||= File.readlines(path)
      end

      def parsed_file(path)
        @parsed_files ||= {}
        @parsed_files[path] ||= NilKill.cached_parse_file(path)
      end

      def load_rbi_field_types
        provider = NilKill::Languages.provider_for("ruby") if defined?(NilKill::Languages)
        indexed = provider&.field_type_index(root: NilKill::ROOT)
        return indexed if indexed && !indexed.empty?

        types = {}
        Dir.glob(File.join(NilKill::ROOT, "sorbet", "rbi", "**", "*.rbi")).each do |path|
          klass = nil
          pending_type = nil
          File.readlines(path).each do |line|
            if line =~ /^\s*class\s+([A-Z]\S*)/
              klass = $1
            elsif klass && line =~ /^\s*sig\s*\{\s*returns\((.+)\)\s*\}/
              pending_type = $1.strip
            elsif klass && line =~ /^\s*def\s+([a-zA-Z_]\w*)\b/
              types[[klass, $1]] = pending_type || "T.untyped"
              pending_type = nil
            elsif line =~ /^\s*end\s*$/
              klass = nil
              pending_type = nil
            end
          end
        end
        types
      end
    end

    attr_reader :methods, :tlet_sites, :dead_nil_checks, :struct_declarations, :struct_field_static, :tuple_arrays, :hash_shapes,
      :collection_index_lookups, :hash_record_blockers, :hash_record_member_calls,
      :type_normalizers, :deterministic_guards, :dispatcher_inferences, :return_origins, :param_origins,
      :ivar_protocols, :ivar_param_origins

    # Hash that bumps a shared epoch cell on every mutation so the
    # expression_type memo can detect staleness. `wrap` keeps the cell
    # bound across a non-mutating Hash#merge that returns an EpochHash.
    class EpochHash < Hash
      def self.wrap(src, cell)
        if src.is_a?(EpochHash)
          src.instance_variable_set(:@ec, cell)
          return src
        end
        h = new
        h.instance_variable_set(:@ec, cell)
        src&.each { |k, v| h[k] = v }
        h
      end

      def []=(k, v); @ec[0] += 1 if @ec; super; end
      def store(k, v); @ec[0] += 1 if @ec; super; end
      def delete(*a, &b); @ec[0] += 1 if @ec; super; end
      def clear; @ec[0] += 1 if @ec; super; end
      def merge!(*a, &b); @ec[0] += 1 if @ec; super; end
      def update(*a, &b); @ec[0] += 1 if @ec; super; end
      def replace(o); @ec[0] += 1 if @ec; super; end
      def delete_if(&b); @ec[0] += 1 if @ec; super; end
      def reject!(&b); @ec[0] += 1 if @ec; super; end
      def select!(&b); @ec[0] += 1 if @ec; super; end
      def keep_if(&b); @ec[0] += 1 if @ec; super; end
    end

    # The 5 @current_* maps expression_type reads. The writer re-wraps
    # so a reassignment and later in-place writes both bump the epoch.
    %i[current_param_types current_local_types current_collection_builders
       current_hash_shapes current_array_element_shapes].each do |n|
      define_method(n) { instance_variable_get("@#{n}") }
      define_method("#{n}=") { |v| instance_variable_set("@#{n}", EpochHash.wrap(v, @ep)) }
    end

    def initialize(path, warm_only: false)
      @path = path
      @rel = NilKill.rel(path)
      @lines = self.class.source_lines(path)
      @warm_only = warm_only
      @ep = [0]
      @expr_memo = {}
      @expr_use_memo = ENV["NIL_KILL_EXPR_MEMO"] != "0"
      @expr_shadow = ENV["NIL_KILL_EXPR_SHADOW"] == "1"
      @expr_shadow_bad = 0
      @methods = []
      @tlet_sites = []
      @dead_nil_checks = []
      @struct_declarations = []
      @struct_field_static = []
      @tuple_arrays = []
      @hash_shapes = []
      @collection_index_lookups = []
      @hash_record_blockers = []
      @hash_record_member_calls = []
      @type_normalizers = []
      @deterministic_guards = []
      @dispatcher_inferences = []
      @return_origins = []
      @param_origins = []
      @ivar_protocols = Hash.new { |hash, key| hash[key] = Set.new }
      @ivar_param_origins = Hash.new { |hash, key| hash[key] = Set.new }
      @struct_fields_by_name = {}
      @struct_full_by_name = {}
      @non_nil_locals = Set.new
      @maybe_nil_locals = Set.new
      @non_nil_method_returns = Set.new
      @method_return_types = Hash.new { |hash, key| hash[key] = [] }
      @static_return_types = {}
      @static_hash_return_shapes = {}
      @static_array_element_return_shapes = {}
      @inferred_param_hash_shapes = {}
      @inferred_param_array_element_shapes = {}
      @method_nodes = []
      # Pure function of the type string -> memoize by type.
      @rcfs_memo = {}
      # Symbol -> String memo: node.name.to_s on hot AST walks otherwise
      # allocates a fresh String per visit for repeated method names.
      @sym_str = {}
      self.current_param_types = {}
      self.current_local_types = {}
      self.current_collection_builders = {}
      self.current_hash_shapes = {}
      @current_hash_shape_sources = {}
      self.current_array_element_shapes = {}
      @current_method_name = nil
      @local_container_origins = {}
      @ivar_container_origins = {}
      @ivar_tlet_names = Set.new
      @ivar_tlet_types = {}
      @current_class_name = nil
      @class_like_constants = Set.new
      parsed = self.class.parsed_file(path)
      if parsed.success?
        collect_prescan(parsed.value, [], [])
        walk(parsed.value, [])
        recompute_return_origins_with_inferred_shapes unless @warm_only
        recompute_collection_index_lookups_with_inferred_shapes unless @warm_only
        recompute_struct_field_static_with_inferred_locals unless @warm_only
      end
      @method_nodes.each { |def_node, record| collect_type_normalizers!(def_node, record) } unless @warm_only
    end

    def summary
      { "methods" => @methods.size, "unsigned_methods" => @methods.count { |m| !m["has_sig"] },
        "tlet_sites" => @tlet_sites.count { |s| s["tlet"] }, "candidate_tlet_sites" => @tlet_sites.count { |s| !s["tlet"] },
        "dead_nil_checks" => @dead_nil_checks.size, "structs" => @struct_declarations.size,
        "tuple_arrays" => @tuple_arrays.size, "hash_shapes" => @hash_shapes.size,
        "collection_index_lookups" => @collection_index_lookups.size,
        "type_normalizers" => @type_normalizers.size, "deterministic_guards" => @deterministic_guards.size,
        "return_origins" => @return_origins.size,
        "param_origins" => @param_origins.size }
    end

    def collect_type_normalizers!(def_node, record)
      body = def_node.respond_to?(:body) ? def_node.body : nil
      return unless body
      param_names = Array(record["params"]).map { |p| p["name"].to_s }
      assigns = {}
      each_ast(body) do |n|
        assigns[n.name.to_s] ||= n.value if n.is_a?(Syntax::LocalVariableWriteNode)
      end
      each_ast(body) do |n|
        next unless n.is_a?(Syntax::CallNode) && %i[is_a? kind_of?].include?(n.name) && n.receiver
        args = (n.arguments && n.arguments.arguments) || []
        next unless args.size == 1 && args.first.slice == "Type"
        kind, name = classify_origin(n.receiver, param_names, assigns, 0)
        @type_normalizers << {
          "path" => @rel, "line" => n.location.start_line,
          "class" => record["class"], "method" => record["method"],
          "code" => n.slice.split("\n").first.to_s.strip[0, 120],
          "origin_kind" => kind, "origin_name" => name,
        }
      end
    end

    def each_ast(node, &blk)
      return unless node.is_a?(Syntax::Node)
      yield node
      node.compact_child_nodes.each { |c| each_ast(c, &blk) }
    end

    # A local receiver is resolved through its in-method assignment
    # exactly once (depth 1) so `ti = node.type_info; ti.is_a?(Type)`
    # keys to `.type_info`.
    def classify_origin(node, param_names, assigns, depth)
      case node
      when Syntax::InstanceVariableReadNode
        ["ivar", node.slice]
      when Syntax::LocalVariableReadNode
        nm = node.name.to_s
        return ["param", nm] if param_names.include?(nm)
        if depth.zero? && (rhs = assigns[nm])
          return classify_origin(rhs, param_names, assigns, depth + 1)
        end
        ["local", nil]
      when Syntax::CallNode
        if node.name == :[]
          key = node.arguments && node.arguments.arguments && node.arguments.arguments.first
          k = case key
              when Syntax::SymbolNode then ":#{key.value}"
              when Syntax::StringNode then ":#{key.unescaped}"
              end
          ["hashkey", k]
        elsif ((node.arguments && node.arguments.arguments) || []).any?
          ["call", node.name.to_s]
        elsif node.receiver
          ["attr", node.name.to_s]
        else
          ["call", node.name.to_s]
        end
      else
        ["local", nil]
      end
    end

    def walk(node, scope)
      case node
      when Syntax::ClassNode, Syntax::ModuleNode
        new_scope = scope + [node.constant_path.slice]
        old_class = @current_class_name
        @current_class_name = new_scope.join("::")
        begin
          child_walk(node.body, new_scope)
        ensure
          @current_class_name = old_class
        end
      when Syntax::DefNode
        record = method_record(node, scope)
        record["return_origin"] = analyze_return_origin(node, record)
        @methods << record unless @warm_only
        @return_origins << record["return_origin"] if record["return_origin"] && !@warm_only
        if record["return_origin"] && record["return_origin"]["confidence"] == "strong"
          type = record["return_origin"]["candidate_type"]
          (@static_return_types[record["method"]] = type; @ep[0] += 1) if NilKill.useful_type?(type)
        end
        if record["return_origin"] && record["return_origin"]["hash_shape"] && !record["return_origin"]["hash_shape"]["poisoned"]
          @static_hash_return_shapes[record["method"]] = record["return_origin"]["hash_shape"]
        end
        if record["return_origin"] && record["return_origin"]["array_element_shape"] && !record["return_origin"]["array_element_shape"]["poisoned"]
          @static_array_element_return_shapes[record["method"]] = record["return_origin"]["array_element_shape"]
        end
        @method_nodes << [node, record] unless @warm_only
        inspect_dispatcher(node, record) unless @warm_only
        scoped_facts(record) { child_walk(node.body, scope) }
      when Syntax::IfNode
        inspect_branch_guard(node, inverted: false) unless @warm_only
        child_walk(node, scope)
      when Syntax::UnlessNode
        inspect_branch_guard(node, inverted: true) unless @warm_only
        child_walk(node, scope)
      when Syntax::CallNode
        inspect_param_origins(node, scope) unless @warm_only
        update_collection_builder_call(node)
        inspect_call(node) unless @warm_only
        inspect_index_lookup(node, scope) unless @warm_only
        inspect_hash_record_blocker(node, scope) unless @warm_only
        inspect_hash_record_member_call(node, scope) unless @warm_only
        inspect_struct_constructor(node)
        inspect_class_constructor_fields(node)
        inspect_attribute_shape_write(node)
        walk_call_children(node, scope)
      when Syntax::ArrayNode
        inspect_array_literal(node) unless @warm_only
        child_walk(node, scope)
      when Syntax::HashNode
        inspect_hash_literal(node) unless @warm_only
        child_walk(node, scope)
      when Syntax::LocalVariableWriteNode
        update_local_fact(node)
        inspect_local_container_origin(node) unless @warm_only
        child_walk(node, scope)
      when Syntax::InstanceVariableWriteNode, Syntax::ClassVariableWriteNode, Syntax::GlobalVariableWriteNode
        inspect_variable_write(node) unless @warm_only
        inspect_ivar_container_origin(node) unless @warm_only
        child_walk(node, scope)
      else
        child_walk(node, scope)
      end
    end

    def child_walk(node, scope)
      return unless node&.respond_to?(:child_nodes)
      node.compact_child_nodes.each { |child| walk(child, scope) }
    end

    def walk_call_children(node, scope)
      block = node.block
      unless block && block.respond_to?(:body)
        child_walk(node, scope)
        return
      end

      old_hash_shapes = @current_hash_shapes
      self.current_hash_shapes = dup_hash_shapes(@current_hash_shapes)
      block_param_names(block).each_with_index do |name, idx|
        shape = block_param_shapes_for_call(node)[idx]
        @current_hash_shapes[name] = dup_hash_shape(shape) if name && shape
      end
      child_walk(node, scope)
    ensure
      self.current_hash_shapes = old_hash_shapes if old_hash_shapes
    end

    def recompute_return_origins_with_inferred_shapes
      return if @method_nodes.empty?
      latest_origins = []
      2.times do
        latest_origins = []
        @method_nodes.each do |node, record|
          origin = analyze_return_origin(node, record)
          record["return_origin"] = origin
          latest_origins << origin if origin
          if origin && origin["confidence"] == "strong"
            type = origin["candidate_type"]
            (@static_return_types[record["method"]] = type; @ep[0] += 1) if NilKill.useful_type?(type)
          end
          if origin && origin["hash_shape"] && !origin["hash_shape"]["poisoned"]
            @static_hash_return_shapes[record["method"]] = origin["hash_shape"]
          end
          if origin && origin["array_element_shape"] && !origin["array_element_shape"]["poisoned"]
            @static_array_element_return_shapes[record["method"]] = origin["array_element_shape"]
          end
        end
      end
      @return_origins = latest_origins
    end

    def recompute_collection_index_lookups_with_inferred_shapes
      return if @method_nodes.empty?
      @collection_index_lookups = []
      @hash_record_blockers = []
      @method_nodes.each do |node, record|
        scoped_facts(record) do
          collect_collection_index_facts(node.body, Array(record["scope"]))
        end
      end
    end

    # The main walk leaves a `Struct.new(local, ...)` arg untyped
    # (@current_local_types is only populated by the return-origin
    # pass). Re-resolve with local-type facts so the field slot isn't
    # needlessly skipped; a still-unresolvable arg keeps its empty type.
    def recompute_struct_field_static_with_inferred_locals
      return if @method_nodes.empty? || @struct_field_static.empty?
      index = Hash.new { |h, k| h[k] = [] }
      @struct_field_static.each do |entry|
        index[[entry["path"], entry["line"], entry["class"], entry["field"], entry["expression"]]] << entry
      end
      @method_nodes.each do |node, record|
        scoped_facts(record) do
          collect_local_type_facts(node.body)
          refill_struct_constructor_types(node.body, index)
        end
      end
    end

    def refill_struct_constructor_types(node, index)
      return unless node
      return if nested_scope_node?(node)
      if node.is_a?(Syntax::CallNode) && node.name == :new && node.receiver
        klass = const_name(node.receiver)
        fields = @struct_fields_by_name[klass] || @struct_fields_by_name[klass.split("::").last] ||
          self.class.struct_fields_by_name[klass] || self.class.struct_fields_by_name[klass.split("::").last]
        if fields
          full_class = @struct_full_by_name[klass] || @struct_full_by_name[klass.split("::").last] ||
            self.class.struct_full_by_name[klass] || self.class.struct_full_by_name[klass.split("::").last] || klass
          (node.arguments&.arguments || []).each_with_index do |arg, idx|
            next if idx >= fields.size || arg.is_a?(Syntax::KeywordHashNode)
            entries = index[[@rel, node.location.start_line, full_class, fields[idx], arg.slice]]
            next if entries.empty?
            next if entries.all? { |e| NilKill.useful_type?(e["type"].to_s) }
            resolved = expression_type(arg)
            next unless NilKill.useful_type?(resolved)
            entries.each { |e| e["type"] = resolved unless NilKill.useful_type?(e["type"].to_s) }
            merge_struct_field_static_type(full_class, fields[idx], resolved)
          end
        end
      end
      node.compact_child_nodes.each { |child| refill_struct_constructor_types(child, index) } if node.respond_to?(:child_nodes)
    end

    def collect_local_container_origins(node)
      return unless node
      return if nested_scope_node?(node)
      case node
      when Syntax::LocalVariableWriteNode
        inspect_local_container_origin(node)
      when Syntax::InstanceVariableWriteNode, Syntax::ClassVariableWriteNode, Syntax::GlobalVariableWriteNode
        inspect_ivar_container_origin(node)
      end
      node.compact_child_nodes.each { |child| collect_local_container_origins(child) } if node.respond_to?(:child_nodes)
    end

    def collect_collection_index_facts(node, scope)
      return unless node
      return if nested_scope_node?(node)
      case node
      when Syntax::CallNode
        update_collection_builder_call(node)
        inspect_index_lookup(node, scope)
        inspect_hash_record_blocker(node, scope)
        inspect_hash_record_member_call(node, scope)
        collect_call_collection_index_facts(node, scope)
      when Syntax::LocalVariableWriteNode
        update_local_fact(node)
        inspect_local_container_origin(node)
        node.compact_child_nodes.each { |child| collect_collection_index_facts(child, scope) } if node.respond_to?(:child_nodes)
      else
        node.compact_child_nodes.each { |child| collect_collection_index_facts(child, scope) } if node.respond_to?(:child_nodes)
      end
    end

    def collect_call_collection_index_facts(node, scope)
      block = node.block
      unless block && block.respond_to?(:body)
        node.compact_child_nodes.each { |child| collect_collection_index_facts(child, scope) }
        return
      end
      old_hash_shapes = @current_hash_shapes
      self.current_hash_shapes = dup_hash_shapes(@current_hash_shapes)
      block_param_names(block).each_with_index do |name, idx|
        shape = block_param_shapes_for_call(node)[idx]
        @current_hash_shapes[name] = dup_hash_shape(shape) if name && shape
      end
      node.compact_child_nodes.each { |child| collect_collection_index_facts(child, scope) }
    ensure
      self.current_hash_shapes = old_hash_shapes if old_hash_shapes
    end

    # Fused single-traversal replacement for the four pure pre-walk
    # collectors (struct_declarations / class_like_constants /
    # non_nil_method_returns / ivar_tlet_names). They each independently
    # DFS'd the whole file; this performs the union of their per-node
    # work in one DFS. cscope is the const_name-derived scope used by
    # the struct + class-constant logic; iscope is the constant_path
    # .slice-derived scope used by the ivar T.let logic (the two scope
    # strings can differ, so both are threaded). non_nil ignores scope.
    # Accumulators are disjoint and the single DFS order matches each
    # original collector's DFS order, so output is byte-identical.
    def collect_prescan(node, cscope, iscope)
      case node
      when Syntax::ClassNode, Syntax::ModuleNode
        name = const_name(node.constant_path)
        full_name = (cscope + [name]).join("::")
        @class_like_constants.add(full_name)
        @class_like_constants.add(name)
        child_c = cscope + [name]
        child_i = iscope + [node.constant_path.slice]
        node.compact_child_nodes.each { |child| collect_prescan(child, child_c, child_i) }
        return
      when Syntax::ConstantWriteNode
        if struct_new_call?(node.value) || data_define_call?(node.value)
          klass = (cscope + [node.name.to_s]).join("::")
          fields = struct_fields(node.value)
          if fields.any?
            rec = { "path" => @rel, "line" => node.location.start_line, "class" => klass, "fields" => fields }
            @struct_declarations << rec unless @warm_only
            @struct_fields_by_name[klass] = fields
            self.class.struct_fields_by_name[klass] = fields
            @struct_full_by_name[klass] = klass
            self.class.struct_full_by_name[klass] = klass
            short = klass.split("::").last
            unless @struct_fields_by_name.key?(short)
              @struct_fields_by_name[short] = fields
              @struct_full_by_name[short] = klass
            end
            unless self.class.struct_fields_by_name.key?(short)
              self.class.struct_fields_by_name[short] = fields
              self.class.struct_full_by_name[short] = klass
            end
          end
          name = node.name.to_s
          full_name = (cscope + [name]).join("::")
          @class_like_constants.add(full_name)
          @class_like_constants.add(name)
        end
      when Syntax::InstanceVariableWriteNode
        val = node.value
        if val.is_a?(Syntax::CallNode) && val.name == :let && val.receiver&.slice == "T"
          name = node.name.to_s
          @ivar_tlet_names.add(name)
          type_node = (val.arguments&.arguments || [])[1]
          if type_node && !iscope.empty?
            type_str = type_node.slice
            (@ivar_tlet_types[[iscope.join("::"), name]] = type_str; @ep[0] += 1) if NilKill.useful_type?(type_str)
          end
        end
      when Syntax::DefNode
        sig = sig_above(node.location.start_line)
        if sig
          ret = NilKill.extract_return_type(sig)
          (@method_return_types[node.name.to_s] << ret; @ep[0] += 1) if ret
          @non_nil_method_returns << node.name.to_s if non_nil_return_sig?(sig)
        end
      end
      node.compact_child_nodes.each { |child| collect_prescan(child, cscope, iscope) } if node.respond_to?(:compact_child_nodes)
    end

    def struct_new_call?(node)
      node.is_a?(Syntax::CallNode) &&
        node.name == :new &&
        node.receiver.is_a?(Syntax::ConstantReadNode) &&
        node.receiver.name == :Struct
    end

    def data_define_call?(node)
      node.is_a?(Syntax::CallNode) &&
        node.name == :define &&
        node.receiver.is_a?(Syntax::ConstantReadNode) &&
        node.receiver.name == :Data
    end

    def struct_fields(node)
      (node.arguments&.arguments || []).filter_map do |arg|
        arg.value.to_s if arg.is_a?(Syntax::SymbolNode)
      end
    end

    def const_name(node)
      return "" unless node
      node.respond_to?(:full_name) ? (node.full_name rescue node.slice) : node.slice
    end

    def inspect_struct_constructor(node)
      return unless node.name == :new && node.receiver
      klass = const_name(node.receiver)
      fields = @struct_fields_by_name[klass] || @struct_fields_by_name[klass.split("::").last] ||
        self.class.struct_fields_by_name[klass] || self.class.struct_fields_by_name[klass.split("::").last]
      full_class = @struct_full_by_name[klass] || @struct_full_by_name[klass.split("::").last] ||
        self.class.struct_full_by_name[klass] || self.class.struct_full_by_name[klass.split("::").last] || klass
      return unless fields
      args = node.arguments&.arguments || []
      args.each_with_index do |arg, idx|
        next if idx >= fields.size || arg.is_a?(Syntax::KeywordHashNode)
        unless @warm_only
          @struct_field_static << { "path" => @rel, "line" => node.location.start_line, "class" => full_class,
            "field" => fields[idx], "type" => expression_type(arg), "expression" => arg.slice }
        end
        merge_struct_field_static_type(full_class, fields[idx], expression_type(arg))
        merge_struct_field_hash_shape(full_class, fields[idx], hash_shape_for_value(arg))
        merge_struct_field_array_element_shape(full_class, fields[idx], array_element_shape_for_value(arg))
      end
    end

    def inspect_class_constructor_fields(node)
      return unless node.name == :new && node.receiver
      klass = const_name(node.receiver)
      return if klass.empty? || klass == "Struct"
      keyword_args = (node.arguments&.arguments || []).grep(Syntax::KeywordHashNode)
      keyword_args.each do |keywords|
        keywords.elements.each do |assoc|
          next unless assoc.respond_to?(:key) && assoc.respond_to?(:value)
          field = hash_key_name(assoc.key)
          next unless field
          merge_struct_field_static_type(klass, field, expression_type(assoc.value))
          merge_struct_field_hash_shape(klass, field, hash_shape_for_value(assoc.value))
          merge_struct_field_array_element_shape(klass, field, array_element_shape_for_value(assoc.value))
        end
      end
    end

    def inspect_array_literal(node)
      elements = node.elements || []
      return if elements.size < 2 || elements.any? { |elem| elem.is_a?(Syntax::SplatNode) }
      types = elements.map { |elem| expression_type(elem) }
      known = types.compact
      return if known.size != elements.size || known.uniq.size < 2
      @tuple_arrays << { "path" => @rel, "line" => node.location.start_line, "size" => elements.size,
        "types" => types, "confidence" => tuple_confidence(types), "code" => node.slice }
    end

    def inspect_hash_literal(node)
      elements = node.elements || []
      return if elements.empty?
      keys = []
      values = []
      value_hash_shapes = {}
      value_array_element_shapes = {}
      elements.each do |assoc|
        next unless assoc.respond_to?(:key) && assoc.respond_to?(:value)
        key = hash_key_name(assoc.key)
        next unless key
        keys << key
        values << expression_type(assoc.value)
        value_hash_shapes[key] = hash_shape_for_value(assoc.value) if hash_shape_for_value(assoc.value)
        value_array_element_shapes[key] = array_element_shape_for_value(assoc.value) if array_element_shape_for_value(assoc.value)
      end
      return if keys.size < 2 || keys.size != elements.size
      @hash_shapes << { "path" => @rel, "line" => node.location.start_line, "keys" => keys,
        "value_types" => values, "value_hash_shapes" => value_hash_shapes,
        "value_array_element_shapes" => value_array_element_shapes, "code" => node.slice }
    end

    def inspect_local_container_origin(node)
      origin = container_origin_for_value(node.value, name: node.name.to_s)
      if origin
        @local_container_origins[node.name.to_s] = origin
      else
        @local_container_origins.delete(node.name.to_s)
      end
    end

    def inspect_ivar_container_origin(node)
      origin = container_origin_for_value(node.value, name: node.name.to_s)
      @ivar_container_origins[node.name.to_s] = origin if origin
    end

    def container_origin_for_value(value, name:)
      return nil unless value
      case value
      when Syntax::ArrayNode
        types = Array(value.elements).map { |elem| expression_type(elem) }
        { "kind" => "array literal", "name" => name, "path" => @rel, "line" => value.location.start_line,
          "code" => value.slice, "array_element_types" => types.compact.uniq.sort }
      when Syntax::HashNode
        key_types = []
        value_types = []
        Array(value.elements).each do |assoc|
          next unless assoc.respond_to?(:key) && assoc.respond_to?(:value)
          key_types << expression_type(assoc.key)
          value_types << expression_type(assoc.value)
        end
        { "kind" => "hash literal", "name" => name, "path" => @rel, "line" => value.location.start_line,
          "code" => value.slice, "hash_key_types" => key_types.compact.uniq.sort,
          "hash_value_types" => value_types.compact.uniq.sort }
      when Syntax::LocalVariableReadNode
        @local_container_origins[value.name.to_s]&.merge("name" => name, "alias_of" => value.name.to_s)
      when Syntax::InstanceVariableReadNode, Syntax::ClassVariableReadNode, Syntax::GlobalVariableReadNode
        @ivar_container_origins[value.name.to_s]&.merge("name" => name, "alias_of" => value.name.to_s)
      when Syntax::CallNode
        { "kind" => "forwarded return", "name" => name, "path" => @rel, "line" => value.location.start_line,
          "code" => value.slice, "callee" => value.name.to_s }
      end
    end

    def inspect_index_lookup(node, scope)
      return unless %i[[] fetch].include?(node.name) && node.receiver
      return if sorbet_type_index_syntax?(node.receiver)
      args = node.arguments&.arguments || []
      return unless args.size >= 1
      return if node.name == :fetch && args.size > 1
      receiver_type = expression_type(node.receiver)
      lookup_type = collection_index_return_type(node, receiver_type)
      index_type = expression_type(args.first)
      @collection_index_lookups << { "path" => @rel, "line" => node.location.start_line,
        "enclosing_scope" => scope.join("::"), "code" => node.slice, "receiver" => node.receiver.slice,
        "index" => args.first.slice, "receiver_type" => receiver_type, "index_type" => index_type,
        "lookup_type" => lookup_type, "status" => collection_index_status(receiver_type, lookup_type),
        "origin" => receiver_collection_origin(node.receiver) }
    end

    def inspect_hash_record_blocker(node, scope)
      return unless node.receiver
      name = node.name.to_s
      args = node.arguments&.arguments || []
      if %w[[] fetch].include?(name)
        return if name == "fetch" && args.size > 1
        return if args.empty? || hash_key_name(args.first)
        origin = hash_record_blocker_origin_for_receiver(node.receiver)
        return unless hash_record_blocker_origin?(origin)
        @hash_record_blockers << { "path" => @rel, "line" => node.location.start_line,
          "enclosing_scope" => scope.join("::"), "kind" => "dynamic_key", "code" => node.slice,
          "receiver" => node.receiver.slice, "index" => args.first&.slice, "origin" => origin,
          "message" => "dynamic hash-record key prevents struct accessor rewrite" }
      elsif %w[[]= merge! update delete clear shift].include?(name)
        origin = hash_record_blocker_origin_for_receiver(node.receiver)
        return unless hash_record_blocker_origin?(origin)
        @hash_record_blockers << { "path" => @rel, "line" => node.location.start_line,
          "enclosing_scope" => scope.join("::"), "kind" => "mutation", "code" => node.slice,
          "receiver" => node.receiver.slice, "origin" => origin,
          "message" => "shape-changing hash-record mutation prevents broad struct rewrite" }
      end
    end

    def inspect_hash_record_member_call(node, scope)
      receiver = node.receiver
      return unless receiver.is_a?(Syntax::CallNode)
      return unless %i[[] fetch].include?(receiver.name)
      return if receiver.name == :fetch && (receiver.arguments&.arguments || []).size > 1
      args = receiver.arguments&.arguments || []
      key = hash_key_name(args.first)
      return unless key
      origin = receiver_collection_origin(receiver.receiver)
      return unless hash_record_blocker_origin?(origin) || origin["kind"] == "local hash shape"
      @hash_record_member_calls << { "path" => @rel, "line" => node.location.start_line,
        "enclosing_scope" => scope.join("::"), "field" => key, "member" => node.name.to_s,
        "code" => node.slice, "lookup_code" => receiver.slice, "receiver" => receiver.receiver&.slice,
        "origin" => origin }
    end

    def hash_record_blocker_origin?(origin)
      ["hash literal", "method parameter", "forwarded return", "instance variable", "local hash shape"].include?(origin&.fetch("kind", nil).to_s)
    end

    def hash_record_blocker_origin_for_receiver(receiver)
      origin = receiver_collection_origin(receiver)
      return origin if hash_record_blocker_origin?(origin)
      if receiver.is_a?(Syntax::LocalVariableReadNode) && @current_hash_shapes[receiver.name.to_s]
        { "kind" => "local hash shape", "name" => receiver.name.to_s, "path" => @rel,
          "line" => receiver.location.start_line, "shape" => @current_hash_shapes[receiver.name.to_s] }
      else
        origin
      end
    end

    def sorbet_type_index_syntax?(receiver)
      text = receiver.slice.to_s
      text.match?(/\A(?:T::)?(?:Array|Hash|Set|Enumerable)\z/) || text.start_with?("T::")
    end

    def collection_index_status(type, lookup_type = nil)
      return "typed lookup" if NilKill.useful_type?(lookup_type) && !NilKill.weak_type?(lookup_type)
      text = type.to_s
      return "unknown receiver type" if text.empty?
      return "weak collection receiver" if text.include?("T.untyped")
      return "typed collection receiver" if text.match?(/\A(?:Array|Hash|T::Array|T::Hash)\b/)
      "non-collection or unresolved receiver"
    end

    def receiver_collection_origin(node)
      case node
      when Syntax::LocalVariableReadNode
        name = node.name.to_s
        origin = @local_container_origins[name]
        if origin && origin["kind"] == "method parameter" && @current_hash_shapes[name]
          origin.merge("shape" => @current_hash_shapes[name])
        elsif origin
          origin
        elsif @current_hash_shape_sources[name]
          @current_hash_shape_sources[name].merge("receiver" => name, "shape" => @current_hash_shapes[name])
        elsif @current_hash_shapes[name]
          { "kind" => "local hash shape", "name" => name, "path" => @rel,
            "line" => node.location.start_line, "shape" => @current_hash_shapes[name] }
        else
          { "kind" => "local variable", "name" => name }
        end
      when Syntax::InstanceVariableReadNode, Syntax::ClassVariableReadNode, Syntax::GlobalVariableReadNode
        @ivar_container_origins[node.name.to_s] || { "kind" => "instance variable", "name" => node.name.to_s }
      when Syntax::ArrayNode
        container_origin_for_value(node, name: "literal")
      when Syntax::HashNode
        container_origin_for_value(node, name: "literal")
      when Syntax::CallNode
        if (shape = hash_shape_for_receiver(node))
          { "kind" => "local hash shape", "name" => node.slice, "path" => @rel,
            "line" => node.location.start_line, "shape" => shape }
        else
          { "kind" => "forwarded return", "callee" => node.name.to_s, "path" => @rel,
            "line" => node.location.start_line, "code" => node.slice }
        end
      else
        { "kind" => node.class.name.split("::").last, "code" => node.slice }
      end
    end

    def inspect_dispatcher(node, record)
      param = record["params"].first
      return unless param
      arms = []
      collect_dispatch_arms(node.body, param["name"], arms)
      arms.group_by { |arm| arm["helper"] }.each do |helper, helper_arms|
        classes = helper_arms.flat_map { |arm| arm["classes"] }.uniq.sort
        next if classes.empty?
        type = classes.size == 1 ? classes.first : "T.any(#{classes.join(", ")})"
        @dispatcher_inferences << { "path" => @rel, "line" => record["line"], "class" => record["class"],
          "kind" => record["kind"], "dispatcher" => record["method"], "helper" => helper, "type" => type,
          "classes" => classes }
      end
    end

    def collect_dispatch_arms(node, param_name, arms)
      return unless node
      if node.is_a?(Syntax::CaseNode)
        node.conditions.each do |condition|
          next unless condition.is_a?(Syntax::WhenNode)
          helper = dispatch_helper_call(condition.statements, param_name)
          next unless helper
          classes = condition.conditions.filter_map { |cond| const_name(cond) }
          arms << { "helper" => helper, "classes" => classes } unless classes.empty?
        end
      end
      node.compact_child_nodes.each { |child| collect_dispatch_arms(child, param_name, arms) } if node.respond_to?(:child_nodes)
    end

    def dispatch_helper_call(statements, param_name)
      body = statements&.body || []
      return nil unless body.size == 1
      call = body.first
      return nil unless call.is_a?(Syntax::CallNode)
      return nil if call.receiver
      args = call.arguments&.arguments || []
      return nil unless args.size == 1
      arg = args.first
      return nil unless arg.is_a?(Syntax::LocalVariableReadNode) && arg.name.to_s == param_name
      call.name.to_s
    end

    def hash_key_name(node)
      case node
      when Syntax::SymbolNode
        node.respond_to?(:value) ? node.value.to_s : node.slice.delete_prefix(":")
      when Syntax::StringNode
        node.respond_to?(:unescaped) ? node.unescaped : node.slice.delete_prefix("\"").delete_prefix("'").delete_suffix("\"").delete_suffix("'")
      else
        nil
      end
    end

    def tuple_confidence(types)
      constants = types.grep(/\A[A-Z]\w*(?:::[A-Z]\w*)*/)
      namespaces = constants.filter_map { |type| type.include?("::") ? type.split("::").first : nil }.uniq
      return "review" if namespaces.size == 1 && constants.size == types.size
      types.uniq.size == types.size ? "high" : "review"
    end

    def non_nil_return_sig?(sig)
      match = sig.match(/\.returns\((.+?)\)/)
      return false unless match
      type = match[1]
      !type.include?("T.nilable") && type != "T.untyped" && type != "NilClass"
    end

    def scoped_facts(method_record)
      old = @non_nil_locals
      old_maybe_nil = @maybe_nil_locals
      old_param_types = @current_param_types
      old_local_types = @current_local_types
      old_collection_builders = @current_collection_builders
      old_hash_shapes = @current_hash_shapes
      old_array_element_shapes = @current_array_element_shapes
      old_local_origins = @local_container_origins
      old_method_name = @current_method_name
      @non_nil_locals = Set.new(method_record["non_nil_params"])
      @maybe_nil_locals = Set.new
      self.current_param_types = method_record["params"].each_with_object({}) do |param, types|
        types[param["name"]] = param["type"] if NilKill.useful_type?(param["type"])
      end
      self.current_local_types = {}
      self.current_collection_builders = seed_param_collection_builders(method_record)
      self.current_hash_shapes = seed_param_hash_shapes(method_record)
      self.current_array_element_shapes = seed_param_array_element_shapes(method_record)
      @current_method_name = method_record["method"]
      @local_container_origins = method_record["params"].each_with_object({}) do |param, origins|
        origins[param["name"]] = { "kind" => "method parameter", "name" => param["name"], "type" => param["type"],
          "path" => method_record["path"], "line" => method_record["line"] }
      end
      yield
    ensure
      @non_nil_locals = old
      @maybe_nil_locals = old_maybe_nil
      self.current_param_types = old_param_types
      self.current_local_types = old_local_types
      self.current_collection_builders = old_collection_builders
      self.current_hash_shapes = old_hash_shapes
      self.current_array_element_shapes = old_array_element_shapes
      @local_container_origins = old_local_origins
      @current_method_name = old_method_name
    end

    def method_record(node, scope)
      sig = sig_above(node.location.start_line)
      method_params = params(node, sig)
      noreturn_candidate = !contains_explicit_return?(node.body) && noreturn_body?(node.body)
      SourceIndex.register_noreturn_method(node.name) if noreturn_candidate
      SourceIndex.register_noreturn_method(node.name) if sig && /returns\(\s*T\.noreturn\s*\)/.match?(sig)
      { "path" => @rel, "line" => node.location.start_line, "end_line" => node.location.end_line, "class" => scope.join("::"),
        "method" => node.name.to_s, "kind" => node.receiver.is_a?(Syntax::SelfNode) ? "class" : "instance",
        "has_sig" => !sig.nil?, "sig" => sig, "params" => method_params, "scope" => scope,
        "non_nil_params" => non_nil_sig_params(sig), "uses_yield" => @warm_only ? false : uses_yield?(node.body),
        "untraceable_params" => @warm_only ? [] : untraceable_param_names(node),
        "protocols" => @warm_only ? {} : param_protocols(node), "noreturn_candidate" => noreturn_candidate }
    end

    def contains_explicit_return?(node)
      return false unless node
      return false if nested_scope_node?(node)
      return true if return_node?(node)
      node.respond_to?(:child_nodes) && node.compact_child_nodes.any? { |child| contains_explicit_return?(child) }
    end

    def noreturn_body?(node)
      case node
      when nil
        false
      when Syntax::StatementsNode
        body = node.body || []
        return false if body.empty?
        noreturn_body?(body.last)
      when Syntax::BeginNode
        noreturn_body?(node.statements)
      when Syntax::IfNode
        noreturn_body?(node.statements) && noreturn_body?(node.subsequent)
      when Syntax::ElseNode
        noreturn_body?(node.statements)
      when Syntax::CaseNode
        conditions = node.conditions || []
        return false if conditions.empty?
        conditions.all? { |condition| noreturn_body?(condition.respond_to?(:statements) ? condition.statements : nil) } &&
          noreturn_body?(node.else_clause)
      when Syntax::RescueNode
        noreturn_body?(node.statements) && noreturn_body?(node.subsequent)
      when Syntax::EnsureNode
        noreturn_body?(node.statements)
      when Syntax::CallNode
        noreturn_call?(node)
      else
        false
      end
    end

    def noreturn_call?(node)
      return true if %i[raise fail exit abort].include?(node.name)
      # T.absurd marks unreachable exhaustiveness arms (Sorbet idiom). It
      # raises at runtime, so any branch ending in T.absurd is noreturn.
      return true if node.name == :absurd && node.receiver&.slice == "T"
      return true if SourceIndex.noreturn_methods.include?(node.name.to_s)
      known_return_type(node.name.to_s, node: node, allow_rbi: false) == "T.noreturn"
    end

    def analyze_return_origin(node, record)
      old_param_types = @current_param_types
      old_local_types = @current_local_types
      old_collection_builders = @current_collection_builders
      old_hash_shapes = @current_hash_shapes
      old_array_element_shapes = @current_array_element_shapes
      old_method_name = @current_method_name
      old_class_name = @current_class_name
      self.current_param_types = record["params"].each_with_object({}) do |param, types|
        types[param["name"]] = param["type"] if NilKill.useful_type?(param["type"])
      end
      self.current_local_types = {}
      self.current_collection_builders = seed_param_collection_builders(record)
      self.current_hash_shapes = seed_param_hash_shapes(record)
      self.current_array_element_shapes = seed_param_array_element_shapes(record)
      @current_method_name = record["method"]
      @current_class_name = record["class"] if record["class"] && !record["class"].empty?
      collect_local_type_facts(node.body)
      explicit_expressions = explicit_return_expressions(node.body)
      implicit_expr = implicit_return_expression(node.body)
      implicit_present = !return_node?(implicit_expr)
      expressions = explicit_expressions.dup
      expressions << implicit_expr if implicit_present
      sources = []
      blockers = []
      expressions.compact.each do |expr|
        sources.concat(return_sources_for(expr, blockers))
      end
      hash_shape = hash_shape_for_return_expressions(expressions)
      array_element_shape = array_element_shape_for_return_expressions(expressions)
      if expressions.empty? || sources.empty?
        blockers << "no return expression found"
      end
      type_sources = sources.filter_map { |source| source["type"] }
      candidate = NilKill.static_sorbet_type(type_sources)
      candidate = "T.untyped" if candidate == "NilClass" && sources.any? { |source| source["kind"] == "call_untyped" || source["kind"] == "unknown" }
      useful = NilKill.useful_type?(candidate)
      confidence =
        if useful && !NilKill.weak_type?(candidate) && blockers.empty? && sources.none? { |source| source["kind"] == "call_untyped" }
          "strong"
        elsif useful
          "weak"
        else
          "blocked"
      end
      { "path" => record["path"], "line" => record["line"], "end_line" => record["end_line"],
        "class" => record["class"], "method" => record["method"], "kind" => record["kind"],
        "implicit" => explicit_expressions.empty?, "return_syntax" => return_syntax(explicit_expressions, implicit_present),
        "control_shape" => return_control_shape(explicit_expressions, implicit_expr, implicit_present),
        "candidate_type" => useful ? candidate : "T.untyped",
        "confidence" => confidence, "sources" => sources, "blockers" => blockers.uniq,
        "hash_shape" => hash_shape, "array_element_shape" => array_element_shape }
    ensure
      self.current_param_types = old_param_types
      self.current_local_types = old_local_types
      self.current_collection_builders = old_collection_builders
      self.current_hash_shapes = old_hash_shapes
      self.current_array_element_shapes = old_array_element_shapes
      @current_method_name = old_method_name
      @current_class_name = old_class_name
    end

    def collect_local_type_facts(node)
      return unless node
      return if nested_scope_node?(node)
      if node.is_a?(Syntax::IfNode)
        collect_branch_local_type_facts(node)
        return
      end
      update_local_fact(node) if node.is_a?(Syntax::LocalVariableWriteNode)
      update_collection_builder_call(node) if node.is_a?(Syntax::CallNode)
      node.compact_child_nodes.each { |child| collect_local_type_facts(child) } if node.respond_to?(:child_nodes)
    end

    def collect_branch_local_type_facts(node)
      before = @current_local_types.dup
      before_builders = dup_collection_builders(@current_collection_builders)
      before_shapes = dup_hash_shapes(@current_hash_shapes)
      before_array_shapes = dup_hash_shapes(@current_array_element_shapes)

      self.current_local_types = before.dup
      self.current_collection_builders = dup_collection_builders(before_builders)
      self.current_hash_shapes = dup_hash_shapes(before_shapes)
      self.current_array_element_shapes = dup_hash_shapes(before_array_shapes)
      collect_local_type_facts(node.statements)
      then_types = @current_local_types.dup
      then_builders = dup_collection_builders(@current_collection_builders)
      then_shapes = dup_hash_shapes(@current_hash_shapes)
      then_array_shapes = dup_hash_shapes(@current_array_element_shapes)

      self.current_local_types = before.dup
      self.current_collection_builders = dup_collection_builders(before_builders)
      self.current_hash_shapes = dup_hash_shapes(before_shapes)
      self.current_array_element_shapes = dup_hash_shapes(before_array_shapes)
      collect_local_type_facts(node.subsequent)
      else_types = @current_local_types.dup
      else_builders = dup_collection_builders(@current_collection_builders)
      else_shapes = dup_hash_shapes(@current_hash_shapes)
      else_array_shapes = dup_hash_shapes(@current_array_element_shapes)

      self.current_local_types = merge_branch_local_types(before, then_types, else_types)
      self.current_collection_builders = merge_branch_collection_builders(before_builders, then_builders, else_builders)
      self.current_hash_shapes = merge_branch_hash_shapes(before_shapes, then_shapes, else_shapes)
      self.current_array_element_shapes = merge_branch_hash_shapes(before_array_shapes, then_array_shapes, else_array_shapes)
    end

    def merge_branch_local_types(before, then_types, else_types)
      names = (before.keys | then_types.keys | else_types.keys)
      names.each_with_object({}) do |name, merged|
        if then_types.key?(name) && else_types.key?(name)
          type = NilKill.static_sorbet_type([then_types[name], else_types[name]].compact)
          merged[name] = NilKill.useful_type?(type) ? type : "T.untyped"
        elsif before.key?(name)
          merged[name] = before[name]
        end
      end
    end

    def seed_param_collection_builders(record)
      record["params"].each_with_object({}) do |param, builders|
        type = param["type"].to_s
        info = collection_type_info(type)
        next unless info
        next unless info["element"].to_s.include?("T.untyped") || info["key"].to_s.include?("T.untyped") || info["value"].to_s.include?("T.untyped")
        builders[param["name"]] = collection_builder(info["kind"])
      end
    end

    def seed_param_hash_shapes(record)
      record["params"].each_with_index.each_with_object({}) do |(param, idx), shapes|
        shape = inferred_param_hash_shape(record["method"], param["name"], idx)
        shapes[param["name"]] = shape if shape && !shape["poisoned"]
      end
    end

    def seed_param_array_element_shapes(record)
      record["params"].each_with_index.each_with_object({}) do |(param, idx), shapes|
        shape = inferred_param_array_element_shape(record["method"], param["name"], idx)
        shapes[param["name"]] = shape if shape && !shape["poisoned"]
      end
    end

    def inferred_param_hash_shape(method_name, param_name, idx)
      shapes = [
        @inferred_param_hash_shapes[[method_name.to_s, "positional", idx.to_s]],
        @inferred_param_hash_shapes[[method_name.to_s, "keyword", param_name.to_s]],
      ].compact
      return nil if shapes.empty?
      shapes.reduce { |acc, shape| merge_hash_record_shapes(acc, shape) }
    end

    def inferred_param_array_element_shape(method_name, param_name, idx)
      shapes = [
        @inferred_param_array_element_shapes[[method_name.to_s, "positional", idx.to_s]],
        @inferred_param_array_element_shapes[[method_name.to_s, "keyword", param_name.to_s]],
      ].compact
      return nil if shapes.empty?
      shapes.reduce { |acc, shape| merge_hash_record_shapes(acc, shape) }
    end

    def dup_collection_builders(builders)
      builders.transform_values do |builder|
        { "kind" => builder["kind"], "types" => Array(builder["types"]).dup,
          "key_types" => Array(builder["key_types"]).dup, "value_types" => Array(builder["value_types"]).dup,
          "poisoned" => builder["poisoned"] }
      end
    end

    def collection_builder(kind)
      { "kind" => kind, "types" => [], "key_types" => [], "value_types" => [], "poisoned" => false }
    end

    def merge_branch_collection_builders(before, then_builders, else_builders)
      names = (before.keys | then_builders.keys | else_builders.keys)
      names.each_with_object({}) do |name, merged|
        if then_builders.key?(name) && else_builders.key?(name)
          merged[name] = merge_collection_builders(then_builders[name], else_builders[name])
        elsif before.key?(name)
          merged[name] = before[name]
        end
      end
    end

    def merge_collection_builders(left, right)
      return collection_builder("unknown").merge("poisoned" => true) unless left["kind"] == right["kind"]
      {
        "kind" => left["kind"],
        "types" => (Array(left["types"]) + Array(right["types"])).uniq,
        "key_types" => (Array(left["key_types"]) + Array(right["key_types"])).uniq,
        "value_types" => (Array(left["value_types"]) + Array(right["value_types"])).uniq,
        "poisoned" => left["poisoned"] || right["poisoned"],
      }
    end

    def dup_hash_shapes(shapes)
      shapes.transform_values { |shape| dup_hash_shape(shape) }
    end

    def dup_hash_shape(shape)
      HashShapeOps.dup_shape(shape)
    end

    def merge_branch_hash_shapes(before, then_shapes, else_shapes)
      names = (before.keys | then_shapes.keys | else_shapes.keys)
      names.each_with_object({}) do |name, merged|
        if then_shapes.key?(name) && else_shapes.key?(name)
          merged[name] = merge_hash_record_shapes(then_shapes[name], else_shapes[name])
        elsif before.key?(name)
          merged[name] = before[name]
        end
      end
    end

    def merge_hash_record_shapes(left, right)
      HashShapeOps.merge_shapes(left, right)
    end

    def merge_nested_hash_shape_maps(left, right)
      HashShapeOps.merge_nested_shape_maps(left, right)
    end

    def hash_shape_for_return_expressions(expressions)
      record_expressions = expressions.compact.reject { |expr| nil_return_expression?(expr) }
      shapes = record_expressions.filter_map { |expr| hash_shape_for_expression(expr) }
      return nil if shapes.empty? || shapes.size != record_expressions.size
      shapes.reduce { |acc, shape| merge_hash_record_shapes(acc, shape) }
    end

    def hash_shape_for_expression(expr)
      case expr
      when :bare_return
        nil
      when Syntax::StatementsNode, Syntax::BeginNode, Syntax::ElseNode, Syntax::ParenthesesNode
        hash_shape_for_expression(implicit_return_expression(expr))
      else
        if return_node?(expr)
          args = expr.respond_to?(:arguments) ? expr.arguments : nil
          values = args&.arguments || []
          return hash_shape_for_expression(values.first || :bare_return)
        end
        case expr
        when Syntax::IfNode
          left = hash_shape_for_expression(implicit_return_expression(expr.statements))
          right = expr.subsequent ? hash_shape_for_expression(implicit_return_expression(expr.subsequent)) : nil
          return nil unless left && right
          merge_hash_record_shapes(left, right)
        else
          hash_shape_for_value(expr)
        end
      end
    end

    def nil_return_expression?(expr)
      return true if expr == :bare_return
      if return_node?(expr)
        args = expr.respond_to?(:arguments) ? expr.arguments : nil
        values = args&.arguments || []
        return true if values.empty?
        return nil_return_expression?(values.first)
      end
      case expr
      when Syntax::NilNode
        true
      when Syntax::StatementsNode, Syntax::BeginNode, Syntax::ElseNode, Syntax::ParenthesesNode
        nil_return_expression?(implicit_return_expression(expr))
      else
        false
      end
    end

    def array_element_shape_for_return_expressions(expressions)
      record_expressions = expressions.compact.reject { |expr| nil_return_expression?(expr) }
      shapes = record_expressions.filter_map { |expr| array_element_shape_for_expression(expr) }
      return nil if shapes.empty? || shapes.size != record_expressions.size
      shapes.reduce { |acc, shape| merge_hash_record_shapes(acc, shape) }
    end

    def array_element_shape_for_expression(expr)
      case expr
      when :bare_return
        nil
      when Syntax::StatementsNode, Syntax::BeginNode, Syntax::ElseNode, Syntax::ParenthesesNode
        array_element_shape_for_expression(implicit_return_expression(expr))
      else
        if return_node?(expr)
          args = expr.respond_to?(:arguments) ? expr.arguments : nil
          values = args&.arguments || []
          return array_element_shape_for_expression(values.first || :bare_return)
        end
        case expr
        when Syntax::IfNode
          left = array_element_shape_for_expression(implicit_return_expression(expr.statements))
          right = expr.subsequent ? array_element_shape_for_expression(implicit_return_expression(expr.subsequent)) : nil
          return nil unless left && right
          merge_hash_record_shapes(left, right)
        else
          array_element_shape_for_value(expr)
        end
      end
    end

    def update_collection_builder_call(node)
      receiver = node.receiver
      if receiver.is_a?(Syntax::LocalVariableReadNode) && @current_collection_builders.key?(receiver.name.to_s)
        update_receiver_collection_builder(node, receiver.name.to_s)
      end
      poison_escaped_collection_builders(node)
    end

    def update_receiver_collection_builder(node, name)
      builder = @current_collection_builders[name]
      args = node.arguments&.arguments || []
      handled = true
      case node.name.to_s
      when "<<", "push", "add"
        add_collection_type(builder, args.first)
        add_array_element_shape(name, args.first) if builder["kind"] == "array"
      when "concat"
        add_array_collection_types(builder, args.first)
        add_array_element_shapes(name, args.first) if builder["kind"] == "array"
      when "[]="
        return unless args.size >= 2
        add_hash_collection_types(builder, args[0], args[-1])
        add_hash_shape_key(name, args[0], args[-1]) if builder["kind"] == "hash"
      when "merge!"
        add_hash_literal_collection_types(builder, args.first)
        merge_hash_shape_literal(name, args.first) if builder["kind"] == "hash"
      else
        handled = false
      end
      return unless handled
      @current_local_types[name] = synthesized_collection_builder_type(builder)
    end

    def add_array_element_shape(name, expr)
      shape = hash_shape_for_value(expr)
      return unless shape && !shape["poisoned"]
      current = @current_array_element_shapes[name]
      @current_array_element_shapes[name] = current ? merge_hash_record_shapes(current, shape) : dup_hash_shape(shape)
    end

    def add_array_element_shapes(name, expr)
      shape = array_element_shape_for_value(expr)
      return unless shape && !shape["poisoned"]
      current = @current_array_element_shapes[name]
      @current_array_element_shapes[name] = current ? merge_hash_record_shapes(current, shape) : dup_hash_shape(shape)
    end

    def add_hash_shape_key(name, key_expr, value_expr)
      key = hash_key_name(key_expr)
      type = expression_type(value_expr)
      return unless key && (NilKill.useful_type?(type) || type == "NilClass")
      shape = @current_hash_shapes[name] ||= { "keys" => {}, "poisoned" => false }
      shape["keys"][key] ||= []
      shape["keys"][key] |= [type]
    end

    def merge_hash_shape_literal(name, expr)
      shape = hash_shape_for_value(expr)
      return unless shape && !shape["poisoned"]
      current = @current_hash_shapes[name]
      @current_hash_shapes[name] = current ? merge_hash_record_shapes(current, shape) : dup_hash_shape(shape)
    end

    def poison_escaped_collection_builders(node)
      return if node.receiver
      return if node.name.to_s == @current_method_name
      return if known_return_type(node.name.to_s, node: node, allow_rbi: false)
      (node.arguments&.arguments || []).each do |arg|
        next unless arg.is_a?(Syntax::LocalVariableReadNode)
        builder = @current_collection_builders[arg.name.to_s]
        next unless builder
        builder["poisoned"] = true; @ep[0] += 1
        @current_local_types.delete(arg.name.to_s)
        @current_hash_shapes.delete(arg.name.to_s)
        @current_array_element_shapes.delete(arg.name.to_s)
      end
      (node.arguments&.arguments || []).each do |arg|
        next unless arg.is_a?(Syntax::LocalVariableReadNode)
        next unless @current_hash_shapes.key?(arg.name.to_s) || @current_array_element_shapes.key?(arg.name.to_s)
        @current_hash_shapes.delete(arg.name.to_s)
        @current_array_element_shapes.delete(arg.name.to_s)
      end
    end

    def add_collection_type(builder, expr)
      return unless builder && expr
      type = expression_type(expr)
      if NilKill.useful_type?(type) || type == "NilClass"
        builder["types"] |= [type]; @ep[0] += 1
      else
        builder["poisoned"] = true; @ep[0] += 1
      end
    end

    def add_array_collection_types(builder, expr)
      return unless builder && expr
      if expr.is_a?(Syntax::ArrayNode)
        expr.elements.each { |elem| add_collection_type(builder, elem) }
        return
      end
      type = expression_type(expr)
      info = collection_type_info(type)
      if info && info["kind"] == "array" && NilKill.useful_type?(info["element"])
        builder["types"] |= [info["element"]]; @ep[0] += 1
      else
        builder["poisoned"] = true; @ep[0] += 1
      end
    end

    def add_hash_collection_types(builder, key_expr, value_expr)
      return unless builder
      key_type = expression_type(key_expr)
      value_type = expression_type(value_expr)
      if (NilKill.useful_type?(key_type) || key_type == "NilClass") && (NilKill.useful_type?(value_type) || value_type == "NilClass")
        builder["key_types"] |= [key_type]; @ep[0] += 1
        builder["value_types"] |= [value_type]; @ep[0] += 1
      else
        builder["poisoned"] = true; @ep[0] += 1
      end
    end

    def add_hash_literal_collection_types(builder, expr)
      return unless builder && expr
      if expr.is_a?(Syntax::HashNode) || expr.is_a?(Syntax::KeywordHashNode)
        expr.elements.each do |assoc|
          next unless assoc.respond_to?(:key) && assoc.respond_to?(:value)
          add_hash_collection_types(builder, assoc.key, assoc.value)
        end
      else
        builder["poisoned"] = true; @ep[0] += 1
      end
    end

    def builder_has_evidence?(builder)
      builder && (!Array(builder["types"]).empty? || !Array(builder["key_types"]).empty? ||
        !Array(builder["value_types"]).empty? || builder["poisoned"])
    end

    def synthesized_collection_builder_type(builder)
      return nil unless builder
      return nil if builder["poisoned"]
      case builder["kind"]
      when "array"
        elem = NilKill.static_sorbet_type(builder["types"])
        elem = "T.untyped" unless NilKill.useful_type?(elem)
        "T::Array[#{elem}]"
      when "hash"
        key = NilKill.static_sorbet_type(builder["key_types"])
        value = NilKill.static_sorbet_type(builder["value_types"])
        key = "T.untyped" unless NilKill.useful_type?(key)
        value = "T.untyped" unless NilKill.useful_type?(value)
        "T::Hash[#{key}, #{value}]"
      when "set"
        elem = NilKill.static_sorbet_type(builder["types"])
        elem = "T.untyped" unless NilKill.useful_type?(elem)
        "T::Set[#{elem}]"
      end
    end

    def explicit_return_expressions(node)
      results = []
      collect_explicit_returns(node, results)
      results
    end

    def collect_explicit_returns(node, results)
      return unless node
      return if nested_scope_node?(node)
      if return_node?(node)
        args = node.respond_to?(:arguments) ? node.arguments : nil
        values = args&.arguments || []
        results << (values.first || :bare_return)
        return
      end
      node.compact_child_nodes.each { |child| collect_explicit_returns(child, results) } if node.respond_to?(:child_nodes)
    end

    def implicit_return_expression(node)
      case node
      when Syntax::StatementsNode
        node.body&.last
      when Syntax::BeginNode
        implicit_return_expression(node.statements)
      when Syntax::ElseNode
        implicit_return_expression(node.statements)
      when Syntax::ParenthesesNode
        implicit_return_expression(node.body)
      else
        node
      end
    end

    def return_syntax(explicit_expressions, implicit_present)
      explicit = !explicit_expressions.empty?
      return "mixed" if explicit && implicit_present
      return "explicit" if explicit
      "implicit"
    end

    def return_control_shape(explicit_expressions, implicit_expr, implicit_present)
      return "branching" if explicit_expressions.size > 1
      return "branching" if !explicit_expressions.empty? && implicit_present
      return "branching" if explicit_expressions.any? { |expr| branching_return_expression?(expr) }
      return "branching" if implicit_present && branching_return_expression?(implicit_expr)
      "branchless"
    end

    def branching_return_expression?(node)
      case node
      when nil, :bare_return
        false
      when Syntax::IfNode, Syntax::CaseNode, Syntax::RescueNode
        true
      else
        node.respond_to?(:child_nodes) && node.compact_child_nodes.any? { |child| branching_return_expression?(child) }
      end
    end

    def return_sources_for(node, blockers)
      return [{ "kind" => "nil", "type" => "NilClass", "line" => nil, "code" => "return" }] if node == :bare_return
      return [] unless node
      line = node.location.start_line
      code = node.slice

      if return_node?(node)
        args = node.respond_to?(:arguments) ? node.arguments : nil
        values = args&.arguments || []
        return return_sources_for(values.first || :bare_return, blockers)
      end

      if node.is_a?(Syntax::StatementsNode) || node.is_a?(Syntax::BeginNode) ||
          node.is_a?(Syntax::ElseNode) || node.is_a?(Syntax::ParenthesesNode)
        return return_sources_for(implicit_return_expression(node), blockers)
      end

      if node.is_a?(Syntax::InstanceVariableReadNode)
        ivar_type = ivar_expression_type(node.name.to_s)
        if NilKill.useful_type?(ivar_type)
          return [{ "kind" => "ivar_typed", "type" => ivar_type, "line" => line, "code" => code }]
        end
        blockers << "untyped instance variable #{code} at #{@rel}:#{line}"
        return [{ "kind" => "ivar_read", "line" => line, "code" => code }]
      end
      if node.is_a?(Syntax::ClassVariableReadNode) || node.is_a?(Syntax::GlobalVariableReadNode)
        blockers << "untyped instance variable #{code} at #{@rel}:#{line}"
        return [{ "kind" => "ivar_read", "line" => line, "code" => code }]
      end

      if node.is_a?(Syntax::IfNode)
        sources = []
        sources.concat(return_sources_for(implicit_return_expression(node.statements), blockers))
        if node.subsequent
          sources.concat(return_sources_for(implicit_return_expression(node.subsequent), blockers))
        else
          sources << { "kind" => "nil", "type" => "NilClass", "line" => line, "code" => "implicit else" }
        end
        blockers << "conditional return without exhaustive static branch type at #{@rel}:#{line}" if sources.empty?
        return sources
      end

      if node.is_a?(Syntax::UnlessNode)
        sources = []
        sources.concat(return_sources_for(implicit_return_expression(node.statements), blockers))
        if node.respond_to?(:else_clause) && node.else_clause
          sources.concat(return_sources_for(implicit_return_expression(node.else_clause), blockers))
        else
          sources << { "kind" => "nil", "type" => "NilClass", "line" => line, "code" => "implicit else" }
        end
        blockers << "unless return without exhaustive static branch type at #{@rel}:#{line}" if sources.empty?
        return sources
      end

      if node.is_a?(Syntax::CaseNode)
        sources = []
        node.conditions.each do |condition|
          sources.concat(return_sources_for(implicit_return_expression(condition.statements), blockers)) if condition.respond_to?(:statements)
        end
        sources.concat(return_sources_for(implicit_return_expression(node.else_clause), blockers)) if node.respond_to?(:else_clause)
        blockers << "case return without exhaustive static branch type at #{@rel}:#{line}" if sources.empty?
        return sources
      end

      if node.is_a?(Syntax::WhileNode) || node.is_a?(Syntax::UntilNode)
        return [{ "kind" => "nil", "type" => "NilClass", "line" => line, "code" => code }]
      end

      if node.is_a?(Syntax::CallNode)
        callee = node.name.to_s
        if assignment_call?(node)
          arg = assignment_value_expression(node)
          arg_type = expression_type(arg)
          if NilKill.useful_type?(arg_type)
            return [{ "kind" => "assignment", "callee" => callee, "type" => arg_type, "line" => line, "code" => code }]
          end
          blockers << "assignment #{callee} has unknown RHS at #{@rel}:#{line}"
          return [{ "kind" => "unknown", "line" => line, "code" => code,
            "unknown_reasons" => unknown_expression_reasons(arg) }]
        end
        if node.safe_navigation?
          ret = known_return_type(callee, node: node, allow_rbi: rbi_return_candidate?(node))
          if ret && NilKill.useful_type?(ret)
            return [{ "kind" => "safe_call", "callee" => callee, "type" => nilable_type(ret), "line" => line, "code" => code,
              "stdlib" => statically_provable_call?(node) }]
          end
          blockers << "safe navigation return may be nil at #{@rel}:#{line}"
          return [{ "kind" => "nil", "type" => "NilClass", "line" => line, "code" => code },
            { "kind" => "call_untyped", "callee" => callee, "line" => line, "code" => code }]
        end
        ret = known_return_type(callee, node: node, allow_rbi: rbi_return_candidate?(node))
        return [{ "kind" => "typed_call", "callee" => callee, "type" => ret, "line" => line, "code" => code,
          "stdlib" => statically_provable_call?(node) }] if ret && NilKill.useful_type?(ret)
        expr_type = expression_type(node)
        return [{ "kind" => "static", "callee" => callee, "type" => expr_type, "line" => line, "code" => code }] if NilKill.useful_type?(expr_type)
        blockers << "untyped callee #{callee} at #{@rel}:#{line}"
        return [{ "kind" => "call_untyped", "callee" => callee, "line" => line, "code" => code }]
      end

      # `@x = v` / `x = v` / `CONST = v` as the return expression: the
      # returned value IS the RHS, so type it as the RHS.
      if node.is_a?(Syntax::InstanceVariableWriteNode) || node.is_a?(Syntax::LocalVariableWriteNode) ||
         node.is_a?(Syntax::ClassVariableWriteNode) || node.is_a?(Syntax::GlobalVariableWriteNode) ||
         node.is_a?(Syntax::ConstantWriteNode)
        return return_sources_for(node.value, blockers)
      end

      type = expression_type(node)
      return [{ "kind" => type == "NilClass" ? "nil" : "static", "type" => type, "line" => line, "code" => code }] if type

      blockers << "unknown return expression #{node.class.name.split("::").last} at #{@rel}:#{line}"
      [{ "kind" => "unknown", "line" => line, "code" => code, "unknown_reasons" => unknown_expression_reasons(node) }]
    end

    def assignment_call?(node)
      setter_call?(node) || index_assignment_call?(node)
    end

    def setter_call?(node)
      # Comparisons (`==`, `!=`, `<=`, `>=`, `===`) also end with `=`;
      # without excluding them `1 != 2` is misread as an assignment.
      return false unless node.is_a?(Syntax::CallNode)
      name = node.name.to_s
      return false unless name.end_with?("=")
      return false if %w[== != <= >= ===].include?(name)
      (node.arguments&.arguments || []).size == 1
    end

    def index_assignment_call?(node)
      node.is_a?(Syntax::CallNode) && node.name == :[]= && (node.arguments&.arguments || []).size >= 2
    end

    def assignment_value_expression(node)
      args = node.arguments&.arguments || []
      args.last
    end

    def return_node?(node)
      node.is_a?(Syntax::ReturnNode)
    end

    def nested_scope_node?(node)
      node.is_a?(Syntax::DefNode) || node.is_a?(Syntax::ClassNode) || node.is_a?(Syntax::ModuleNode)
    end

    def rbi_return_candidate?(node)
      return false unless node.is_a?(Syntax::CallNode)
      # A global-variable receiver (`$stderr.puts`) is dynamically
      # reassignable, so its RBI nominal return is unsound to narrow on.
      return false if node.receiver.is_a?(Syntax::GlobalVariableReadNode)
      node.receiver || %w[! == puts print warn raise].include?(node.name.to_s)
    end

    def rbi_return_source?(node)
      node.is_a?(Syntax::CallNode) && NilKill.rbi_return_type(node.name.to_s, receiver_type_for_call(node))
    end

    # rbi_return_source? needs the external sorbet RBI payload, which is
    # absent under isolated test/CI tmp dirs. A call whose return is
    # provable from core Ruby semantics on a known receiver type
    # (propagated_core_return_type, e.g. Array[String]#join -> String)
    # is statically provable without any payload -- grade it the same.
    def statically_provable_call?(node)
      rbi_return_source?(node) || NilKill.useful_type?(propagated_core_return_type(node))
    end

    def known_return_type(method_name, node: nil, allow_rbi: true)
      propagated = propagated_core_return_type(node)
      return propagated if NilKill.useful_type?(propagated)
      static = @static_return_types[method_name.to_s]
      return static if NilKill.useful_type?(static)
      types = @method_return_types[method_name].compact.uniq
      return types.first if types.size == 1 && NilKill.useful_type?(types.first)
      return nil unless allow_rbi
      NilKill.rbi_return_type(method_name, receiver_type_for_call(node))
    end

    def propagated_core_return_type(node)
      return nil unless node.is_a?(Syntax::CallNode)
      receiver_type = receiver_type_for_call(node)
      case node.name.to_s
      when "[]"
        collection_index_return_type(node, receiver_type)
      when "each", "each_pair", "each_value", "each_key"
        collection_receiver_type?(receiver_type) ? receiver_type : nil
      when "<<", "push", "concat", "merge!", "add"
        collection_receiver_type?(receiver_type) ? receiver_type : nil
      when "map"
        collection_map_return_type(node, receiver_type)
      when "filter_map"
        collection_filter_map_return_type(node, receiver_type)
      when "compact"
        collection_compact_return_type(receiver_type)
      when "select", "reject"
        collection_receiver_type?(receiver_type) ? receiver_type : nil
      when "length", "size"
        collection_receiver_type?(receiver_type) || receiver_type == "String" ? "Integer" : nil
      when "empty?", "any?", "all?", "none?", "one?", "include?", "key?", "has_key?", "value?", "has_value?"
        collection_receiver_type?(receiver_type) || receiver_type == "String" ? "T::Boolean" : nil
      when "join"
        array_receiver_type?(receiver_type) ? "String" : nil
      when "to_s"
        node.receiver ? "String" : nil
      when "to_i"
        node.receiver ? "Integer" : nil
      when "to_sym"
        node.receiver ? "Symbol" : nil
      when "to_a"
        collection_receiver_type?(receiver_type) ? receiver_type : nil
      when "to_h"
        receiver_type.to_s.match?(/\AT::(?:Hash|Array)\b/) ? receiver_type : nil
      when "!", "!=", "==", "<", ">", "<=", ">=", "eql?", "equal?", "===", "frozen?", "respond_to?", "kind_of?", "instance_of?"
        "T::Boolean"
      when "<=>"
        node.receiver ? "T.nilable(Integer)" : nil
      when "hash"
        node.receiver ? "Integer" : nil
      when "inspect"
        node.receiver ? "String" : nil
      when "freeze", "dup", "clone", "itself", "tap"
        receiver_type if NilKill.useful_type?(receiver_type)
      when "+", "-", "*", "/", "%"
        # Receiver-typed for stdlib numerics, String, Array (where defined).
        # Skip for unknown receivers so we don't over-claim.
        case receiver_type.to_s
        when "Integer", "Float", "Rational", "Complex", "String" then receiver_type
        else
          array_receiver_type?(receiver_type) ? receiver_type : nil
        end
      else
        nil
      end
    end

    def receiver_type_for_call(node)
      return nil unless node.is_a?(Syntax::CallNode)
      expression_type(node.receiver)
    end

    def nilable_type(type)
      return type if type == "NilClass"
      return type if type.start_with?("T.nilable(")
      "T.nilable(#{type})"
    end

    def inspect_param_origins(node, scope)
      callee = node.name.to_s
      args = node.arguments&.arguments || []
      args.each_with_index do |arg, idx|
        if arg.is_a?(Syntax::KeywordHashNode)
          arg.elements.each do |assoc|
            next unless assoc.respond_to?(:key) && assoc.respond_to?(:value)
            key = hash_key_name(assoc.key)
            next unless key
            @param_origins << param_origin_record(node, assoc.value, callee, :keyword, key, scope)
            record_callsite_hash_shape(callee, :keyword, key, assoc.value)
            record_callsite_array_element_shape(callee, :keyword, key, assoc.value)
          end
        else
          @param_origins << param_origin_record(node, arg, callee, :positional, idx, scope)
          record_callsite_hash_shape(callee, :positional, idx, arg)
          record_callsite_array_element_shape(callee, :positional, idx, arg)
        end
      end
    end

    def record_callsite_hash_shape(callee, kind, slot, arg)
      shape = hash_shape_for_value(arg)
      return unless shape && !shape["poisoned"]
      callsite_callee_names(callee).each do |name|
        key = [name, kind.to_s, slot.to_s]
        @inferred_param_hash_shapes[key] =
          if @inferred_param_hash_shapes[key]
            merge_hash_record_shapes(@inferred_param_hash_shapes[key], shape)
          else
            dup_hash_shape(shape)
          end
      end
    end

    def record_callsite_array_element_shape(callee, kind, slot, arg)
      shape = array_element_shape_for_value(arg)
      return unless shape && !shape["poisoned"]
      callsite_callee_names(callee).each do |name|
        key = [name, kind.to_s, slot.to_s]
        @inferred_param_array_element_shapes[key] =
          if @inferred_param_array_element_shapes[key]
            merge_hash_record_shapes(@inferred_param_array_element_shapes[key], shape)
          else
            dup_hash_shape(shape)
          end
      end
    end

    def callsite_callee_names(callee)
      name = callee.to_s
      name == "new" ? ["new", "initialize"] : [name]
    end

    def inspect_attribute_shape_write(node)
      return unless node.is_a?(Syntax::CallNode) && node.receiver
      name = node.name.to_s
      return unless name.end_with?("=") && name != "=="
      args = node.arguments&.arguments || []
      return unless args.size == 1
      attr = name.delete_suffix("=")
      if (shape = hash_shape_for_value(args.first))
        merge_attribute_hash_shape(attr, shape)
      end
      if (shape = array_element_shape_for_value(args.first))
        merge_attribute_array_element_shape(attr, shape)
      end
    end

    def merge_attribute_hash_shape(attr, shape)
      return unless shape && !shape["poisoned"]
      current = self.class.attribute_hash_shapes[attr]
      self.class.attribute_hash_shapes[attr] = current ? merge_hash_record_shapes(current, shape) : dup_hash_shape(shape)
    end

    def merge_attribute_array_element_shape(attr, shape)
      return unless shape && !shape["poisoned"]
      current = self.class.attribute_array_element_shapes[attr]
      self.class.attribute_array_element_shapes[attr] = current ? merge_hash_record_shapes(current, shape) : dup_hash_shape(shape)
    end

    def merge_struct_field_hash_shape(klass, field, shape)
      return unless shape && !shape["poisoned"]
      key = [klass.to_s, field.to_s]
      current = self.class.struct_field_hash_shapes[key]
      self.class.struct_field_hash_shapes[key] = current ? merge_hash_record_shapes(current, shape) : dup_hash_shape(shape)
    end

    def merge_struct_field_array_element_shape(klass, field, shape)
      return unless shape && !shape["poisoned"]
      key = [klass.to_s, field.to_s]
      current = self.class.struct_field_array_element_shapes[key]
      self.class.struct_field_array_element_shapes[key] = current ? merge_hash_record_shapes(current, shape) : dup_hash_shape(shape)
    end

    def merge_struct_field_static_type(klass, field, type)
      return unless NilKill.useful_type?(type) || type == "NilClass"
      key = [klass.to_s, field.to_s]
      self.class.struct_field_static_types[key] ||= []
      self.class.struct_field_static_types[key] |= [type]
    end

    def param_origin_record(call_node, arg, callee, kind, slot, scope)
      type = expression_type(arg)
      origin_kind = type ? "static" : "unknown"
      source_method = nil
      if arg.is_a?(Syntax::CallNode)
        source_method = arg.name.to_s
        ret = known_return_type(source_method, node: arg, allow_rbi: rbi_return_candidate?(arg))
        if ret
          type = ret
          origin_kind = "typed_return"
        elsif NilKill.useful_type?(type)
          origin_kind = "typed_return"
        else
          origin_kind = "untyped_return"
        end
      elsif arg.is_a?(Syntax::LocalVariableReadNode)
        origin_kind = "local"
      end
      { "path" => @rel, "line" => call_node.location.start_line, "enclosing_scope" => scope.join("::"),
        "callee" => callee, "arg_kind" => kind.to_s, "slot" => slot.to_s, "origin_kind" => origin_kind,
        "receiver" => call_receiver_name(call_node), "source_method" => source_method, "type" => type, "code" => arg.slice,
        "hash_shape" => hash_shape_for_value(arg), "array_element_shape" => array_element_shape_for_value(arg),
        "unknown_reasons" => origin_kind == "unknown" ? unknown_expression_reasons(arg) : [] }
    end

    def call_receiver_name(call_node)
      receiver = call_node.receiver
      return nil unless receiver
      const_name(receiver)
    rescue StandardError
      receiver.slice.to_s
    end

    def unknown_expression_reasons(node)
      reasons = Set.new
      collect_unknown_expression_reasons(node, reasons)
      reasons.to_a.sort
    end

    def collect_unknown_expression_reasons(node, reasons)
      return unless node
      case node
      when Syntax::InstanceVariableReadNode, Syntax::InstanceVariableWriteNode
        reasons << "instance variable #{node.name}"
      when Syntax::ClassVariableReadNode, Syntax::ClassVariableWriteNode
        reasons << "class variable #{node.name}"
      when Syntax::GlobalVariableReadNode, Syntax::GlobalVariableWriteNode
        reasons << "global variable #{node.name}"
      when Syntax::LocalVariableReadNode
        reasons << "local variable #{node.name}"
      when Syntax::ConstantReadNode, Syntax::ConstantPathNode
        type = static_expression_type(node)
        reasons << (type ? "literal/static expression #{static_expression_reason(type)}" : "operation unresolved constant #{node.slice}")
        return
      when Syntax::ArrayNode
        reasons << "struct/array/collection value Array"
        return
      when Syntax::HashNode, Syntax::KeywordHashNode
        reasons << "struct/array/collection value Hash"
        return
      when Syntax::CallNode
        if node.receiver&.slice == "T" && %i[let cast unsafe bind].include?(node.name)
          reasons << "literal/static expression explicit #{node.receiver.slice}.#{node.name}"
          args = node.arguments&.arguments || []
          reasons << "literal/static expression explicit T.untyped" if args.any? { |arg| arg.slice == "T.untyped" }
          return
        elsif expression_type(node)
          reasons << "literal/static expression #{static_expression_reason(expression_type(node))}"
          return
        elsif !known_return_type(node.name.to_s, node: node, allow_rbi: rbi_return_candidate?(node))
          reasons << "forwarded return #{node.name}"
          collect_unknown_expression_reasons(node.receiver, reasons)
          return
        end
      else
        type = static_expression_type(node)
        if type
          reasons << "literal/static expression #{static_expression_reason(type)}"
          return
        else
          reasons << "operation #{node.class.name.split("::").last}"
        end
      end
      node.compact_child_nodes.each { |child| collect_unknown_expression_reasons(child, reasons) } if node.respond_to?(:child_nodes)
    end

    def param_protocols(node)
      names = params(node).map { |param| param["name"] }.to_set
      protocols = names.each_with_object({}) { |name, hash| hash[name] = { "methods" => Set.new, "aliases" => Set.new, "gaps" => Set.new } }
      collect_protocols(node.body, protocols, names)
      protocols.transform_values do |data|
        { "methods" => data["methods"].to_a.sort, "aliases" => data["aliases"].to_a.sort, "gaps" => data["gaps"].to_a.sort }
      end
    end

    def collect_protocols(node, protocols, param_names)
      return unless node
      if node.is_a?(Syntax::CallNode)
        receiver = node.receiver
        if receiver.is_a?(Syntax::LocalVariableReadNode) && protocols.key?(receiver.name.to_s)
          protocols[receiver.name.to_s]["methods"] << node.name.to_s
        end
        # Covers `@x.token`, `T.must(@x).token`, and safe-nav.
        if receiver.is_a?(Syntax::InstanceVariableReadNode) && @current_class_name
          @ivar_protocols[[@current_class_name, receiver.name.to_s]] << node.name.to_s
        end
        (node.arguments&.arguments || []).each_with_index do |arg, slot|
          if arg.is_a?(Syntax::LocalVariableReadNode) && protocols.key?(arg.name.to_s)
            protocols[arg.name.to_s]["gaps"] << "forwarded to #{node.name} slot #{slot} at #{@rel}:#{node.location.start_line}"
          end
        end
      elsif node.is_a?(Syntax::LocalVariableWriteNode)
        source = unwrap_alias_source(node.value)
        if source && protocols.key?(source)
          protocols[source]["aliases"] << "#{node.name} at #{@rel}:#{node.location.start_line}"
        end
      elsif node.is_a?(Syntax::InstanceVariableWriteNode)
        source = unwrap_alias_source(node.value)
        if source && protocols.key?(source)
          protocols[source]["gaps"] << "captured in #{node.name} at #{@rel}:#{node.location.start_line}"
          @ivar_param_origins[[@current_class_name, node.name.to_s]] << source if @current_class_name
        end
      end
      node.compact_child_nodes.each { |child| collect_protocols(child, protocols, param_names) } if node.respond_to?(:child_nodes)
    end

    def unwrap_alias_source(node)
      case node
      when Syntax::LocalVariableReadNode
        node.name.to_s
      when Syntax::CallNode
        if node.receiver&.slice == "T" && %i[must cast let].include?(node.name)
          unwrap_alias_source(node.arguments&.arguments&.first)
        end
      end
    end

    def sig_above(line)
      idx = line - 2
      idx -= 1 while idx >= 0 && @lines[idx].to_s.strip.empty?
      return nil if idx.negative?

      stripped = @lines[idx].to_s.strip
      return stripped if stripped.match?(/\bsig\s*\{/)

      if stripped == "end"
        floor = [idx - 40, 0].max
        idx.downto(floor) do |start_idx|
          current = @lines[start_idx].to_s
          return @lines[start_idx..idx].join if current.match?(/\bsig\s+do\b/)
          break if current.match?(/^\s*(def|class|module)\b/)
        end
      end

      nil
    end

    def params(node, sig = sig_above(node.location.start_line))
      p = node.parameters
      return [] unless p
      sig_types = NilKill.extract_param_entries(sig).to_h
      nodes = p.requireds + p.optionals + p.keywords
      nodes.filter_map do |n|
        next unless n.respond_to?(:name) && n.name
        name = n.name.to_s
        { "name" => name, "nil_default" => nil_default?(n), "type" => sig_types[name] }
      end
    end

    # Splat/double-splat/block params can never get runtime evidence
    # and the sig text has no `*`/`**`/`&` marker, so they must be
    # identified from the syntax parameter list, not the sig string.
    def untraceable_param_names(node)
      p = node.parameters
      return [] unless p
      names = []
      names << p.rest.name.to_s if p.rest.respond_to?(:name) && p.rest&.name
      kr = p.respond_to?(:keyword_rest) ? p.keyword_rest : nil
      names << kr.name.to_s if kr.respond_to?(:name) && kr&.name
      names << p.block.name.to_s if p.respond_to?(:block) && p.block.respond_to?(:name) && p.block&.name
      names
    end

    def non_nil_sig_params(sig)
      return [] unless sig
      params_match = sig.match(/params\((.*)\)\./)
      return [] unless params_match
      params_match[1].scan(/\b([a-zA-Z_]\w*):\s*([^,)]+)/).filter_map do |name, type|
        next if type.include?("T.nilable") || type == "T.untyped" || type == "NilClass"
        name
      end
    end

    def nil_default?(node)
      node.respond_to?(:value) && node.value.is_a?(Syntax::NilNode)
    end

    def uses_yield?(node)
      return false unless node&.respond_to?(:child_nodes)
      return true if node.is_a?(Syntax::YieldNode)
      node.compact_child_nodes.any? { |child| uses_yield?(child) }
    end

    def inspect_call(node)
      if node.name == :let && node.receiver&.slice == "T"
        args = node.arguments&.arguments || []
        @tlet_sites << { "path" => @rel, "line" => node.location.start_line, "tlet" => true, "type" => args[1]&.slice }
      elsif node.safe_navigation? && provably_non_nil?(node.receiver)
        @dead_nil_checks << { "path" => @rel, "line" => node.location.start_line, "kind" => "safe_nav",
          "code" => node.slice, "reason" => "#{node.receiver.slice} is provably non-nil" }
      elsif node.name == :nil? && node.receiver && provably_non_nil?(node.receiver)
        @dead_nil_checks << { "path" => @rel, "line" => node.location.start_line, "kind" => "nil_check",
          "code" => node.slice, "reason" => "#{node.receiver.slice} is provably non-nil; .nil? is always false" }
      end
    end

    def inspect_branch_guard(node, inverted:)
      predicate = node.respond_to?(:predicate) ? node.predicate : nil
      return unless predicate
      result = deterministic_predicate_result(predicate)
      return unless result

      truth = result["truth_value"]
      taken = inverted ? !truth : truth
      @deterministic_guards << {
        "path" => @rel,
        "line" => predicate.location.start_line,
        "class" => @current_class_name,
        "method" => @current_method_name,
        "code" => predicate.slice.split("\n").first.to_s.strip[0, 160],
        "branch_kind" => inverted ? "unless" : "if",
        "truth_value" => truth,
        "taken_branch" => taken ? "body" : "else",
        "proof_tier" => result["proof_tier"],
        "predicate_kind" => result["predicate_kind"],
        "reason" => result["reason"],
        "origin_kind" => result["origin_kind"],
        "origin_name" => result["origin_name"],
      }
    end

    def deterministic_predicate_result(node)
      node = implicit_return_expression(node) if node.is_a?(Syntax::ParenthesesNode)
      literal = literal_truth_value(node)
      return deterministic_guard_result(literal, "literal", "#{node.slice} is a boolean literal") unless literal.nil?

      if node.is_a?(Syntax::CallNode)
        nil_result = deterministic_nil_predicate_result(node)
        return nil_result if nil_result
        class_result = deterministic_class_predicate_result(node)
        return class_result if class_result
        return deterministic_literal_comparison_result(node)
      end
      nil
    end

    def deterministic_guard_result(truth_value, predicate_kind, reason, origin_kind: nil, origin_name: nil)
      {
        "truth_value" => truth_value,
        "proof_tier" => "static_proven",
        "predicate_kind" => predicate_kind,
        "reason" => reason,
        "origin_kind" => origin_kind,
        "origin_name" => origin_name,
      }
    end

    def literal_truth_value(node)
      case node
      when Syntax::TrueNode then true
      when Syntax::FalseNode then false
      else nil
      end
    end

    def deterministic_nil_predicate_result(node)
      return nil unless node.name == :nil? && node.receiver
      receiver = node.receiver
      origin_kind, origin_name = predicate_origin(receiver)
      receiver_type = deterministic_guard_subject_type(receiver)
      if receiver_type && receiver_type != "NilClass" && !receiver_type.to_s.start_with?("T.nilable(")
        return deterministic_guard_result(false, "nil_check",
          "#{receiver.slice} has static type #{receiver_type}; .nil? is always false",
          origin_kind: origin_kind, origin_name: origin_name)
      end
      if receiver_type == "NilClass"
        return deterministic_guard_result(true, "nil_check",
          "#{receiver.slice} has static type NilClass; .nil? is always true",
          origin_kind: origin_kind, origin_name: origin_name)
      end
      nil
    end

    def deterministic_class_predicate_result(node)
      return nil unless %i[is_a? kind_of? instance_of?].include?(node.name) && node.receiver
      args = node.arguments&.arguments || []
      return nil unless args.size == 1
      class_name = const_name(args.first)
      return nil if class_name.to_s.empty?
      receiver_type = deterministic_guard_subject_type(node.receiver)
      truth = class_guard_truth(receiver_type, class_name, exact: node.name == :instance_of?)
      return nil if truth.nil?

      origin_kind, origin_name = predicate_origin(node.receiver)
      deterministic_guard_result(truth, "class_guard",
        "#{node.receiver.slice} has static type #{receiver_type}; #{node.name}(#{class_name}) is always #{truth}",
        origin_kind: origin_kind, origin_name: origin_name)
    end

    def class_guard_truth(receiver_type, class_name, exact:)
      raw = receiver_type.to_s
      return nil if raw.empty? || raw == "T.untyped" || raw.include?("T.any(")
      return nil if raw.start_with?("T.nilable(")
      normalized = NilKill.strip_nilable_type(raw)
      return nil if normalized.nil? || normalized.empty?
      bare = bare_class_name(normalized)
      wanted = bare_class_name(class_name.to_s)
      return false if exact && known_disjoint_guard_classes?(bare, wanted)
      return nil if exact
      return true if bare == wanted || known_guard_subclass?(bare, wanted)
      return false if known_disjoint_guard_classes?(bare, wanted)
      nil
    end

    def bare_class_name(type)
      raw = type.to_s
      case raw
      when /\AT::Array\b/, /\AArray\b/ then "Array"
      when /\AT::Hash\b/, /\AHash\b/ then "Hash"
      when /\AT::Set\b/, /\ASet\b/ then "Set"
      when "T::Boolean" then "T::Boolean"
      else raw.delete_prefix("::").split("::").last
      end
    end

    CORE_RUNTIME_GUARD_CLASSES = %w[
      Array Hash Set String Symbol Integer Float NilClass TrueClass FalseClass
      Numeric Range Regexp Time
    ].freeze

    NUMERIC_GUARD_SUBCLASSES = %w[Integer Float].freeze
    BOOLEAN_GUARD_SUBCLASSES = %w[TrueClass FalseClass].freeze

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

    def deterministic_literal_comparison_result(node)
      return nil unless %i[== != > >= < <=].include?(node.name) && node.receiver
      args = node.arguments&.arguments || []
      return nil unless args.size == 1
      left = literal_static_value(node.receiver)
      right = literal_static_value(args.first)
      return nil if left == :__nil_kill_unknown || right == :__nil_kill_unknown
      truth = compare_literal_values(left, right, node.name)
      return nil if truth.nil?
      deterministic_guard_result(truth, "literal_comparison",
        "#{node.receiver.slice} #{node.name} #{args.first.slice} is always #{truth}")
    end

    # Deterministic branch rewrites need a stronger subject type than general
    # return-origin inference. In particular, a call receiver like `node.value`
    # may resolve by method name only (`value`) and collide across unrelated
    # classes. Limit this detector to local/param/ivar/literal subjects whose
    # type is already in the current source-index environment.
    def deterministic_guard_subject_type(node)
      case node
      when Syntax::LocalVariableReadNode
        name = node.name.to_s
        @current_param_types[name] || @current_local_types[name]
      when Syntax::InstanceVariableReadNode
        ivar_expression_type(node.name.to_s)
      else
        static_expression_type(node)
      end
    end

    def literal_static_value(node)
      case node
      when Syntax::StringNode then node.respond_to?(:unescaped) ? node.unescaped : node.slice.delete_prefix("\"").delete_prefix("'").delete_suffix("\"").delete_suffix("'")
      when Syntax::SymbolNode then node.value.to_sym
      when Syntax::IntegerNode then node.value
      when Syntax::FloatNode then node.value
      when Syntax::TrueNode then true
      when Syntax::FalseNode then false
      when Syntax::NilNode then nil
      else :__nil_kill_unknown
      end
    end

    def compare_literal_values(left, right, op)
      case op
      when :== then left == right
      when :!= then left != right
      when :>, :>=, :<, :<=
        return nil unless left.is_a?(Numeric) && right.is_a?(Numeric)
        left.public_send(op, right)
      end
    end

    def predicate_origin(node)
      case node
      when Syntax::LocalVariableReadNode
        name = node.name.to_s
        return ["param", name] if @current_param_types.key?(name)
        return ["local", name] if @current_local_types.key?(name)
      when Syntax::InstanceVariableReadNode
        return ["ivar", node.name.to_s]
      when Syntax::CallNode
        return ["attr", node.name.to_s] if node.receiver && ((node.arguments&.arguments) || []).empty?
        return ["call", node.name.to_s]
      end
      [nil, nil]
    end

    def provably_non_nil?(node)
      case node
      when Syntax::LocalVariableReadNode
        name = node.name.to_s
        @non_nil_locals.include?(name) && !@maybe_nil_locals.include?(name)
      when Syntax::CallNode
        !node.safe_navigation? && @non_nil_method_returns.include?(node.name.to_s)
      when Syntax::SelfNode
        true
      else
        !!non_nil_literal?(node)
      end
    end

    def update_local_fact(node)
      name = node.name.to_s
      builder = collection_builder_for_assignment(node.value)
      hash_shape = hash_shape_for_value(node.value)
      array_shape = array_element_shape_for_value(node.value)
      if builder
        @current_collection_builders[name] = builder
      elsif !preserve_collection_builder_assignment?(node.value)
        @current_collection_builders.delete(name)
      end
      if hash_shape
        @current_hash_shapes[name] = hash_shape
        @current_hash_shape_sources[name] = hash_record_source_for_assignment(node, hash_shape)
      elsif preserve_hash_shape_assignment?(node.value)
        @current_hash_shapes[name] = dup_hash_shape(@current_hash_shapes[node.value.name.to_s])
        @current_hash_shape_sources[name] = @current_hash_shape_sources[node.value.name.to_s]&.merge("alias" => name)
      else
        @current_hash_shapes.delete(name)
        @current_hash_shape_sources.delete(name)
      end
      if array_shape
        @current_array_element_shapes[name] = array_shape
      elsif preserve_array_element_shape_assignment?(node.value)
        @current_array_element_shapes[name] = dup_hash_shape(@current_array_element_shapes[node.value.name.to_s])
      else
        @current_array_element_shapes.delete(name)
      end
      type = expression_type(node.value)
      if NilKill.useful_type?(type)
        @current_local_types[name] = type
      elsif builder
        @current_local_types[name] = synthesized_collection_builder_type(builder)
      else
        @current_local_types.delete(name)
      end
      if non_nil_literal?(node.value) && !@maybe_nil_locals.include?(name)
        @non_nil_locals.add(name)
      else
        @non_nil_locals.delete(name)
        @maybe_nil_locals.add(name)
      end
    end

    def hash_shape_for_value(value)
      return nil unless value
      case value
      when Syntax::HashNode, Syntax::KeywordHashNode
        shape = { "keys" => {}, "value_hash_shapes" => {}, "value_array_element_shapes" => {}, "poisoned" => false }
        value.elements.each do |assoc|
          next unless assoc.respond_to?(:key) && assoc.respond_to?(:value)
          key = hash_key_name(assoc.key)
          type = expression_type(assoc.value)
          if key && (NilKill.useful_type?(type) || type == "NilClass")
            shape["keys"][key] ||= []
            shape["keys"][key] |= [type]
            if (nested_hash = hash_shape_for_value(assoc.value))
              shape["value_hash_shapes"][key] = nested_hash
            end
            if (nested_array = array_element_shape_for_value(assoc.value))
              shape["value_array_element_shapes"][key] = nested_array
            end
          elsif key
            shape["keys"][key] ||= []
            shape["keys"][key] |= ["T.untyped"]
          elsif !key
            shape["poisoned"] = true
          end
        end
        shape
      when Syntax::LocalVariableReadNode
        dup_hash_shape(@current_hash_shapes[value.name.to_s])
      when Syntax::CallNode
        if assignment_call?(value)
          hash_shape_for_value(assignment_value_expression(value))
        elsif value.receiver&.slice == "T" && %i[must cast let].include?(value.name)
          hash_shape_for_value(value.arguments&.arguments&.first)
        elsif %i[find detect].include?(value.name)
          array_element_shape_for_receiver(value.receiver)
        elsif %i[first last].include?(value.name)
          array_element_shape_for_receiver(value.receiver)
        elsif !value.receiver
          dup_hash_shape(@static_hash_return_shapes[value.name.to_s])
        else
          attribute_hash_shape_for_call(value)
        end
      when Syntax::OrNode
        merge_optional_hash_shape(hash_shape_for_value(value.left), hash_shape_for_value(value.right))
      end
    end

    def array_element_shape_for_value(value)
      return nil unless value
      case value
      when Syntax::ArrayNode
        shapes = value.elements.filter_map { |elem| hash_shape_for_value(elem) }
        return nil if shapes.empty?
        shapes.reduce { |acc, shape| merge_hash_record_shapes(acc, shape) }
      when Syntax::LocalVariableReadNode
        dup_hash_shape(@current_array_element_shapes[value.name.to_s])
      when Syntax::CallNode
        if assignment_call?(value)
          array_element_shape_for_value(assignment_value_expression(value))
        elsif value.receiver&.slice == "T" && %i[must cast let].include?(value.name)
          array_element_shape_for_value(value.arguments&.arguments&.first)
        elsif %i[map filter_map].include?(value.name)
          hash_shape_for_block_return(value)
        elsif %i[select reject compact].include?(value.name)
          array_element_shape_for_receiver(value.receiver)
        elsif !value.receiver
          dup_hash_shape(@static_array_element_return_shapes[value.name.to_s])
        elsif value.receiver
          attribute_array_element_shape_for_call(value)
        end
      when Syntax::OrNode
        merge_optional_hash_shape(array_element_shape_for_value(value.left), array_element_shape_for_value(value.right))
      end
    end

    def merge_optional_hash_shape(left, right)
      return dup_hash_shape(left) if left && !right
      return dup_hash_shape(right) if right && !left
      return nil unless left && right
      merge_hash_record_shapes(left, right)
    end

    def attribute_hash_shape_for_call(node)
      return nil unless node.is_a?(Syntax::CallNode)
      return nil if node.name.to_s.end_with?("=")
      if (shape = struct_field_hash_shape_for_call(node))
        return shape
      end
      dup_hash_shape(self.class.attribute_hash_shapes[node.name.to_s])
    end

    def attribute_array_element_shape_for_call(node)
      return nil unless node.is_a?(Syntax::CallNode)
      return nil if node.name.to_s.end_with?("=")
      if (shape = struct_field_array_element_shape_for_call(node))
        return shape
      end
      dup_hash_shape(self.class.attribute_array_element_shapes[node.name.to_s])
    end

    def hash_shape_for_block_return(call_node)
      block = call_node.block
      return nil unless block && block.respond_to?(:body)
      old_hash_shapes = @current_hash_shapes
      self.current_hash_shapes = dup_hash_shapes(@current_hash_shapes)
      block_param_names(block).each_with_index do |name, idx|
        shape = block_param_shapes_for_call(call_node)[idx]
        @current_hash_shapes[name] = dup_hash_shape(shape) if name && shape
      end
      expr = implicit_return_expression(block.body)
      shape = hash_shape_for_expression(expr)
      if (!shape || Hash(shape["keys"]).empty?) && (literal_shape = hash_shape_for_literal_keys(expr))
        shape = literal_shape
      end
      shape
    ensure
      self.current_hash_shapes = old_hash_shapes if old_hash_shapes
    end

    def hash_shape_for_literal_keys(value)
      return nil unless value.is_a?(Syntax::HashNode) || value.is_a?(Syntax::KeywordHashNode)
      shape = { "keys" => {}, "value_hash_shapes" => {}, "value_array_element_shapes" => {}, "poisoned" => false }
      value.elements.each do |assoc|
        next unless assoc.respond_to?(:key) && assoc.respond_to?(:value)
        key = hash_key_name(assoc.key)
        if key
          type = expression_type(assoc.value)
          shape["keys"][key] ||= []
          shape["keys"][key] |= [NilKill.useful_type?(type) || type == "NilClass" ? type : "T.untyped"]
          if (nested_hash = hash_shape_for_value(assoc.value))
            shape["value_hash_shapes"][key] = nested_hash
          end
          if (nested_array = array_element_shape_for_value(assoc.value))
            shape["value_array_element_shapes"][key] = nested_array
          end
        else
          shape["poisoned"] = true
        end
      end
      Hash(shape["keys"]).empty? ? nil : shape
    end

    def struct_field_hash_shape_for_call(node)
      struct_field_shape_for_call(node, self.class.struct_field_hash_shapes)
    end

    def struct_field_array_element_shape_for_call(node)
      struct_field_shape_for_call(node, self.class.struct_field_array_element_shapes)
    end

    def sym_to_s(sym)
      @sym_str[sym] ||= sym.to_s
    end

    def struct_field_shape_for_call(node, index)
      receiver_type = expression_type(node.receiver)
      name = sym_to_s(node.name)
      classes = receiver_classes_for_field_shape(receiver_type)
      classes.each do |klass|
        shape = index[[klass, name]]
        return dup_hash_shape(shape) if shape
      end
      if classes.empty?
        matching = index.select { |(_klass, field), _shape| field == name }.values
        return dup_hash_shape(matching.first) if matching.size == 1
      end
      nil
    end

    def struct_field_static_type_for_call(node)
      return nil unless node.is_a?(Syntax::CallNode) && node.receiver
      receiver_type = expression_type(node.receiver)
      name = sym_to_s(node.name)
      types = receiver_classes_for_field_shape(receiver_type).flat_map do |klass|
        Array(self.class.struct_field_static_types[[klass, name]])
      end
      NilKill.static_sorbet_type(types.uniq)
    end

    # Pure function of `type` -> memoize. .dup so callers keep getting
    # a fresh array.
    def receiver_classes_for_field_shape(type)
      (@rcfs_memo[type] ||= receiver_classes_for_field_shape_uncached(type)).dup
    end

    def receiver_classes_for_field_shape_uncached(type)
      raw = NilKill.strip_nilable_type(type.to_s)
      return [] if raw.empty? || raw == "T.untyped"
      if raw.start_with?("T.any(")
        return NilKill.split_top_level(NilKill.extract_call_args(raw, "T.any") || "").flat_map { |inner| receiver_classes_for_field_shape(inner) }.uniq
      end
      [raw, raw.split("::").last].uniq
    end

    def collection_builder_for_assignment(value)
      return nil unless value
      case value
      when Syntax::ArrayNode
        builder = collection_builder("array")
        value.elements.each { |elem| add_collection_type(builder, elem) }
        builder
      when Syntax::HashNode
        builder = collection_builder("hash")
        value.elements.each do |assoc|
          next unless assoc.respond_to?(:key) && assoc.respond_to?(:value)
          add_hash_collection_types(builder, assoc.key, assoc.value)
        end
        builder
      when Syntax::CallNode
        if value.name == :new && value.receiver&.slice == "Set"
          collection_builder("set")
        end
      end
    end

    def preserve_collection_builder_assignment?(value)
      value.is_a?(Syntax::LocalVariableReadNode) && @current_collection_builders.key?(value.name.to_s)
    end

    def preserve_hash_shape_assignment?(value)
      value.is_a?(Syntax::LocalVariableReadNode) && @current_hash_shapes.key?(value.name.to_s)
    end

    def hash_record_source_for_assignment(node, shape)
      value = node.value
      if value.is_a?(Syntax::HashNode) || value.is_a?(Syntax::KeywordHashNode)
        { "kind" => "hash literal", "name" => node.name.to_s, "path" => @rel,
          "line" => node.location.start_line, "code" => value.slice, "shape" => shape }
      else
        { "kind" => "local hash shape", "name" => node.name.to_s, "path" => @rel,
          "line" => node.location.start_line, "code" => value&.slice, "shape" => shape }
      end
    end

    def preserve_array_element_shape_assignment?(value)
      value.is_a?(Syntax::LocalVariableReadNode) && @current_array_element_shapes.key?(value.name.to_s)
    end

    def inspect_variable_write(node)
      if node.value.is_a?(Syntax::CallNode) && node.value.name == :let && node.value.receiver&.slice == "T"
        @ivar_tlet_names.add(node.name.to_s)
        return
      end
      return if @ivar_tlet_names.include?(node.name.to_s)
      type = static_expression_type(node.value)
      return if type == "NilClass"
      return unless type
      @tlet_sites << { "path" => @rel, "line" => node.location.start_line, "tlet" => false, "name" => node.name.to_s, "candidate_type" => type }
    end

    # Sound because expression_type only READS state and every mutation
    # of its read surface bumps @ep (the @current_* maps via EpochHash;
    # the writes to @static_return_types/@ivar_tlet_types/
    # @method_return_types); @current_class_name is in the key.
    # NIL_KILL_EXPR_SHADOW asserts memo == fresh per call.
    def expression_type(node)
      return expression_type_uncached(node) unless @expr_use_memo && node

      key = node.object_id
      ent = @expr_memo[key]
      if ent && ent[0] == @ep[0] && ent[1] == @current_class_name
        if @expr_shadow
          fresh = expression_type_uncached(node)
          if fresh != ent[2]
            @expr_shadow_bad += 1
            warn "EXPR_SHADOW MISMATCH #{node.class} cached=#{ent[2].inspect} fresh=#{fresh.inspect}" if @expr_shadow_bad <= 8
          end
        end
        return ent[2]
      end
      r = expression_type_uncached(node)
      @expr_memo[key] = [@ep[0], @current_class_name, r]
      r
    end

    def expression_type_uncached(node)
      return nil unless node
      if return_node?(node)
        args = node.respond_to?(:arguments) ? node.arguments : nil
        values = args&.arguments || []
        return expression_type(values.first) || "NilClass"
      end
      if node.is_a?(Syntax::CallNode) && node.name == :let && node.receiver&.slice == "T"
        return node.arguments&.arguments&.[](1)&.slice
      end
      if node.is_a?(Syntax::CallNode) && node.name == :must && node.receiver&.slice == "T"
        return expression_type(node.arguments&.arguments&.first)
      end
      if node.is_a?(Syntax::LocalVariableReadNode)
        name = node.name.to_s
        builder_type = synthesized_collection_builder_type(@current_collection_builders[name])
        return builder_type if builder_has_evidence?(@current_collection_builders[name]) && NilKill.useful_type?(builder_type)
        return "T::Hash[T.untyped, T.untyped]" if @current_hash_shapes[name]
        return "T::Array[T::Hash[T.untyped, T.untyped]]" if @current_array_element_shapes[name]
        return @current_local_types[name] if NilKill.useful_type?(@current_local_types[name])
        return @current_param_types[name]
      end
      if node.is_a?(Syntax::InstanceVariableReadNode)
        return ivar_expression_type(node.name.to_s)
      end
      if node.is_a?(Syntax::ParenthesesNode)
        return expression_type(implicit_return_expression(node.body))
      end
      if node.is_a?(Syntax::StatementsNode)
        return expression_type(node.body&.last)
      end
      if node.is_a?(Syntax::ElseNode)
        return expression_type(implicit_return_expression(node.statements))
      end
      if node.is_a?(Syntax::IfNode)
        left = expression_type(implicit_return_expression(node.statements))
        right = node.subsequent ? expression_type(implicit_return_expression(node.subsequent)) : "NilClass"
        return NilKill.static_sorbet_type([left, right].compact)
      end
      if node.is_a?(Syntax::UnlessNode)
        left = expression_type(implicit_return_expression(node.statements))
        right = node.respond_to?(:else_clause) && node.else_clause ? expression_type(implicit_return_expression(node.else_clause)) : "NilClass"
        return NilKill.static_sorbet_type([left, right].compact)
      end
      if node.is_a?(Syntax::WhileNode) || node.is_a?(Syntax::UntilNode)
        return "NilClass"
      end
      if node.is_a?(Syntax::OrNode)
        left = expression_type(node.left)
        right = expression_type(node.right)
        non_nil = [left, right].compact.reject { |type| type == "NilClass" }
        normalized = non_nil.map { |type| NilKill.strip_nilable_type(type.to_s) }.uniq
        return normalized.first if normalized.size == 1 && NilKill.useful_type?(normalized.first)
        return non_nil.first if non_nil.size == 1 && NilKill.useful_type?(non_nil.first)
        return left if left == right && NilKill.useful_type?(left)
      end
      if node.is_a?(Syntax::CallNode)
        if assignment_call?(node)
          return expression_type(assignment_value_expression(node))
        end
        return "T::Hash[T.untyped, T.untyped]" if hash_shape_for_receiver(node)
        return "T::Array[T::Hash[T.untyped, T.untyped]]" if array_element_shape_for_receiver(node)
        field_type = struct_field_static_type_for_call(node)
        return field_type if NilKill.useful_type?(field_type)
        ret = known_return_type(node.name.to_s, node: node, allow_rbi: rbi_return_candidate?(node))
        return ret if NilKill.useful_type?(ret)
      end
      return "T::Array[T::Hash[T.untyped, T.untyped]]" if array_element_shape_for_value(node)
      constant_expression_type(node) || literal_type(node)
    end

    def ivar_expression_type(name)
      return nil unless @current_class_name
      tlet_type = @ivar_tlet_types[[@current_class_name, name]]
      return tlet_type if NilKill.useful_type?(tlet_type)
      field = name.sub(/\A@/, "")
      class_chain = @current_class_name.split("::")
      while class_chain.any?
        candidate = class_chain.join("::")
        rbi_type = SourceIndex.rbi_field_types[[candidate, field]]
        return rbi_type if NilKill.useful_type?(rbi_type)
        rbi_type_short = SourceIndex.rbi_field_types[[class_chain.last, field]]
        return rbi_type_short if NilKill.useful_type?(rbi_type_short)
        class_chain.pop
      end
      nil
    end

    def array_receiver_type?(type)
      type.to_s.match?(/\A(?:Array|T::Array)\b/)
    end

    def hash_receiver_type?(type)
      type.to_s.match?(/\A(?:Hash|T::Hash)\b/)
    end

    def collection_receiver_type?(type)
      array_receiver_type?(type) || hash_receiver_type?(type) || type.to_s.match?(/\A(?:Set|T::Set)\b/)
    end

    def collection_index_return_type(node, receiver_type)
      args = node.arguments&.arguments || []
      return nil unless args.size == 1
      shape_type = hash_shape_index_return_type(node.receiver, args.first)
      return shape_type if NilKill.useful_type?(shape_type)
      info = collection_type_info(receiver_type)
      return nil unless info
      case info["kind"]
      when "array"
        elem = info["element"]
        return nil if elem.to_s.empty? || elem.include?("T.untyped")
        index = args.first
        if index.is_a?(Syntax::RangeNode)
          "T::Array[#{elem}]"
        elsif expression_type(index) == "Integer"
          nilable_type(elem)
        end
      when "hash"
        value = info["value"]
        return nil if value.to_s.empty? || value.include?("T.untyped")
        nilable_type(value)
      end
    end

    def hash_shape_index_return_type(receiver, index)
      shape = hash_shape_for_receiver(receiver)
      return nil unless shape && !shape["poisoned"]
      key = hash_key_name(index)
      return nil unless key
      types = Array(shape.dig("keys", key))
      return nil if types.empty?
      value = NilKill.static_sorbet_type(types)
      return nil unless NilKill.useful_type?(value)
      nilable_type(value)
    end

    def hash_shape_for_receiver(receiver)
      case receiver
      when Syntax::LocalVariableReadNode
        @current_hash_shapes[receiver.name.to_s]
      when Syntax::HashNode, Syntax::KeywordHashNode
        hash_shape_for_value(receiver)
      when Syntax::CallNode
        if receiver.receiver&.slice == "T" && %i[must cast let].include?(receiver.name)
          hash_shape_for_receiver(receiver.arguments&.arguments&.first)
        elsif %i[first last].include?(receiver.name)
          array_element_shape_for_receiver(receiver.receiver)
        else
          attribute_hash_shape_for_call(receiver)
        end
      end
    end

    def collection_map_return_type(node, receiver_type)
      info = collection_type_info(receiver_type)
      return nil unless info
      return nil unless array_receiver_type?(receiver_type)
      block_type = block_return_type(node, block_param_types_for_collection(info), block_param_shapes_for_collection(node, info))
      return nil unless NilKill.useful_type?(block_type)
      return nil if block_type.include?("T.untyped")
      "T::Array[#{block_type}]"
    end

    def collection_filter_map_return_type(node, receiver_type)
      info = collection_type_info(receiver_type)
      return nil unless info
      return nil unless array_receiver_type?(receiver_type)
      block_type = block_return_type(node, block_param_types_for_collection(info), block_param_shapes_for_collection(node, info))
      return nil unless NilKill.useful_type?(block_type)
      elem = non_nil_type(block_type)
      return nil if elem.to_s.empty? || elem.include?("T.untyped") || elem == "NilClass"
      "T::Array[#{elem}]"
    end

    def collection_compact_return_type(receiver_type)
      info = collection_type_info(receiver_type)
      return nil unless info && info["kind"] == "array"
      elem = non_nil_type(info["element"])
      return nil if elem.to_s.empty? || elem.include?("T.untyped") || elem == "NilClass"
      "T::Array[#{elem}]"
    end

    def block_return_type(call_node, param_types, param_shapes = [])
      block = call_node.block
      return nil unless block && block.respond_to?(:body)
      old_local_types = @current_local_types
      old_hash_shapes = @current_hash_shapes
      self.current_local_types = @current_local_types.dup
      self.current_hash_shapes = dup_hash_shapes(@current_hash_shapes)
      block_param_names(block).each_with_index do |name, idx|
        type = param_types[idx]
        @current_local_types[name] = type if name && NilKill.useful_type?(type)
        shape = param_shapes[idx]
        @current_hash_shapes[name] = dup_hash_shape(shape) if name && shape
      end
      expression_type(implicit_return_expression(block.body))
    ensure
      self.current_local_types = old_local_types if old_local_types
      self.current_hash_shapes = old_hash_shapes if old_hash_shapes
    end

    def block_param_names(block)
      return [] unless block.respond_to?(:parameters)
      params = block.parameters&.parameters
      return [] unless params
      (params.requireds + params.optionals).filter_map { |param| param.name.to_s if param.respond_to?(:name) && param.name }
    end

    def block_param_types_for_collection(info)
      case info["kind"]
      when "array", "set"
        [info["element"]]
      when "hash"
        [info["key"], info["value"]]
      else
        []
      end
    end

    def block_param_shapes_for_collection(call_node, info)
      return [] unless info["kind"] == "array"
      shape = array_element_shape_for_receiver(call_node.receiver)
      shape ? [shape] : []
    end

    def block_param_shapes_for_call(call_node)
      return [] unless %w[each map filter_map select reject find detect any? all? none? one?].include?(call_node.name.to_s)
      shape = array_element_shape_for_receiver(call_node.receiver)
      shape ? [shape] : []
    end

    def array_element_shape_for_receiver(receiver)
      case receiver
      when Syntax::LocalVariableReadNode
        @current_array_element_shapes[receiver.name.to_s]
      when Syntax::ArrayNode
        array_element_shape_for_value(receiver)
      when Syntax::CallNode
        if receiver.receiver&.slice == "T" && %i[must cast let].include?(receiver.name)
          array_element_shape_for_receiver(receiver.arguments&.arguments&.first)
        elsif %i[select reject compact].include?(receiver.name)
          array_element_shape_for_receiver(receiver.receiver)
        else
          attribute_array_element_shape_for_call(receiver)
        end
      end
    end

    def non_nil_type(type)
      raw = type.to_s
      return nil if raw.empty?
      if raw.start_with?("T.nilable(")
        return NilKill.strip_nilable_type(raw)
      end
      if raw.start_with?("T.any(")
        parts = NilKill.split_top_level(NilKill.extract_call_args(raw, "T.any") || "")
        parts = parts.reject { |part| part == "NilClass" }
        return NilKill.static_sorbet_type(parts)
      end
      raw
    end

    def collection_type_info(type)
      raw = NilKill.strip_nilable_type(type.to_s.strip)
      return nil if raw.empty?
      case raw
      when /\A(?:Array|T::Array)(?:\[(.*)\])?\z/
        { "kind" => "array", "element" => $1 }
      when /\A(?:Hash|T::Hash)(?:\[(.*)\])?\z/
        args = $1 ? NilKill.split_top_level($1) : []
        { "kind" => "hash", "key" => args[0], "value" => args[1] }
      when /\A(?:Set|T::Set)(?:\[(.*)\])?\z/
        { "kind" => "set", "element" => $1 }
      end
    end

    def constant_expression_type(node)
      return nil unless node.is_a?(Syntax::ConstantReadNode) || node.is_a?(Syntax::ConstantPathNode)
      name = node.slice
      return nil if name.to_s.empty?
      return "T.class_of(#{name})" if CORE_CLASS_CONSTANTS.include?(name.delete_prefix("::"))
      return "T.class_of(#{name})" if @class_like_constants.include?(name.delete_prefix("::"))
      nil
    end

    def static_expression_type(node)
      constant_expression_type(node) || literal_type(node)
    end

    def static_expression_reason(type)
      type.to_s.start_with?("T.class_of(") ? "class constant #{type.delete_prefix("T.class_of(").delete_suffix(")")}" : type
    end

    def literal_type(node)
      case node
      when Syntax::StringNode then "String"
      when Syntax::SymbolNode then "Symbol"
      when Syntax::IntegerNode then "Integer"
      when Syntax::FloatNode then "Float"
      when Syntax::TrueNode, Syntax::FalseNode then "T::Boolean"
      when Syntax::NilNode then "NilClass"
      when Syntax::RangeNode then "Range"
      when Syntax::InterpolatedStringNode then "String"
      when Syntax::ArrayNode then "T::Array[T.untyped]"
      when Syntax::HashNode then "T::Hash[T.untyped, T.untyped]"
      else
        node.is_a?(Syntax::CallNode) && node.name == :new && node.receiver ? node.receiver.slice : nil
      end
    end

    def non_nil_literal?(node)
      type = static_expression_type(node)
      type && type != "NilClass"
    end

  end
end
