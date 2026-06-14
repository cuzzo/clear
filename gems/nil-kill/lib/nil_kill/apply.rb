# typed: false
# frozen_string_literal: true

module NilKill
  class Apply
    def initialize(argv)
      @dry_run = argv.include?("--dry-run") || ENV["DRY_RUN"] == "1"
      @all = argv.include?("--all")
    end

    # Lazily loaded: the `apply_actions` path (used by infer's sorbet
    # pre-validate bisection) never needs evidence, so constructing an
    # Apply must not eagerly JSON.parse the multi-100MB evidence.json.
    def evidence
      @evidence ||= Store.read
    end

    def run
      if @all && ENV["NIL_KILL_UNSAFE_APPLY_ALL"] != "1"
        abort "`apply --all` would apply review actions without verification. Use `loop --hash-records -- <verify command...>` for reviewed fixes, or set NIL_KILL_UNSAFE_APPLY_ALL=1 for debugging."
      end
      actions = evidence["actions"].select { |a| @all || a["confidence"] == HIGH }
      apply_actions(actions)
    end

    def apply_actions(actions)
      changed = 0
      actions = expand_cross_file_actions(actions)
      actions.group_by { |a| a["path"] }.each do |rel_path, list|
        path = File.join(ROOT, rel_path)
        next unless File.exist?(path)
        lines = File.readlines(path)
        list.sort_by { |a| -a["line"].to_i }.each { |action| changed += 1 if apply_one(lines, action) }
        ensure_sorbet_runtime(lines) if list.any? { |a| %w[add_sig add_tlet narrow_tlet narrow_generic_param narrow_generic_return promote_hash_record_to_struct promote_hash_record_cluster_to_struct].include?(a["kind"]) }
        ensure_sig_extensions(lines, rel_path, list.select { |a| a["kind"] == "add_sig" })
        File.write(path, lines.join) unless @dry_run
      end
      puts "#{@dry_run ? "would apply" : "applied"} #{changed} action(s)"
      changed
    end

    def expand_cross_file_actions(actions)
      actions.flat_map do |action|
        next [action] unless action["kind"] == "promote_hash_record_cluster_to_struct"
        data = action["data"] || {}
        paths = (Array(data["producers"]) + Array(data["consumers"]) + Array(data["signatures"]))
          .map { |site| site["path"].to_s }.reject(&:empty?).uniq.sort
        paths << data["struct_path"].to_s unless data["struct_path"].to_s.empty?
        paths = paths.uniq.sort
        next [action] if paths.size <= 1
        primary = data["struct_path"].to_s.empty? ? action["path"].to_s : data["struct_path"].to_s
        paths.map do |path|
          copy = Marshal.load(Marshal.dump(action))
          copy["path"] = path
          copy["line"] = hash_record_action_line_for_path(copy, path)
          copy["data"]["insert_struct"] = (path == primary)
          copy
        end
      end
    end

    def hash_record_action_line_for_path(action, path)
      data = action["data"] || {}
      sites = Array(data["producers"]) + Array(data["consumers"]) + Array(data["signatures"])
      site = sites.select { |candidate| candidate["path"].to_s == path }.min_by { |candidate| candidate["line"].to_i }
      site ? site["line"].to_i : action["line"].to_i
    end

    def apply_one(lines, action)
      idx = action["line"].to_i - 1
      return false if idx.negative? || idx >= lines.length
      case action["kind"]
      when "add_sig"
        tgt = resolve_add_sig_idx(lines, idx, action)
        return false unless tgt
        return false if find_sig_idx(lines, tgt)
        lines.insert(tgt, "#{lines[tgt][/^\s*/]}#{action["data"]["sig"]}\n")
      when "fix_sig_param"
        return apply_signature_cst_rewrite(lines, action, "param", action["data"]["name"].to_s, "T.untyped", action["data"]["type"].to_s)
      when "fix_sig_return"
        type = action["data"]["type"].to_s
        return apply_signature_cst_rewrite(lines, action, "return", nil, "T.untyped", type)
      when "narrow_generic_param"
        return apply_signature_cst_rewrite(lines, action, "param", action["data"]["name"].to_s, action["data"]["from"].to_s, action["data"]["type"].to_s)
      when "narrow_generic_return"
        return apply_signature_cst_rewrite(lines, action, "return", nil, action["data"]["from"].to_s, action["data"]["type"].to_s)
      when "narrow_tlet"
        return apply_narrow_tlet_cst_rewrite(lines, action)
      when "add_tlet"
        return apply_add_tlet_cst_rewrite(lines, action)
      when "remove_dead_safe_nav"
        return apply_safe_nav_cst_rewrite(lines, action)
      when "replace_dead_nil_check"
        return apply_exact_code_cst_rewrite(lines, action, "false")
      when "replace_nil_with_default"
        return apply_nil_default_cst_rewrite(lines, action)
      when "promote_hash_record_to_struct"
        return apply_hash_record_struct_promotion(lines, action)
      when "promote_hash_record_cluster_to_struct"
        return apply_hash_record_cluster_promotion(lines, action)
      when "add_struct_field_sig"
        return apply_add_struct_field_sig(lines, action)
      else
        return false
      end
      true
    end

    # Idempotently set `sig { returns(TYPE) } / def FIELD; end` under
    # `class KLASS` in the struct-field RBI. The file is line-regular
    # (AUTO-GENERATED: top-level classes, 2-space body). Re-applying
    # updates the existing sig (so the verified loop's snapshot/restore
    # + bisection works unchanged). Multiple actions on the same RBI
    # accumulate because apply_actions mutates one shared `lines` per
    # path group.
    def apply_add_struct_field_sig(lines, action)
      klass = action.dig("data", "class").to_s
      field = action.dig("data", "field").to_s
      type  = action.dig("data", "type").to_s
      return false if klass.empty? || field.empty? || type.empty?
      sig_line = "  sig { returns(#{type}) }\n"
      def_line = "  def #{field}; end\n"

      cls_idx = lines.index { |l| l =~ /\A\s*class\s+#{Regexp.escape(klass)}\s*\z/ }
      if cls_idx
        end_idx = (cls_idx + 1...lines.length).find { |i| lines[i] =~ /\A\s*end\s*\z/ }
        return false unless end_idx
        def_idx = (cls_idx + 1...end_idx).find { |i| lines[i] =~ /\A\s*def\s+#{Regexp.escape(field)}\s*;/ }
        if def_idx
          if def_idx > cls_idx + 1 && lines[def_idx - 1] =~ /\A\s*sig\s*\{/
            return false if lines[def_idx - 1] == sig_line # already this type
            lines[def_idx - 1] = sig_line
          else
            lines.insert(def_idx, sig_line)
          end
        else
          lines.insert(end_idx, sig_line, def_line)
        end
      else
        lines << "\n" unless lines.empty? || lines[-1].end_with?("\n")
        lines.concat(["class #{klass}\n", sig_line, def_line, "end\n", "\n"])
      end
      true
    end

    def apply_hash_record_struct_promotion(lines, action)
      data = action["data"] || {}
      struct_name = data["struct_name"].to_s
      literal = data["literal"] || {}
      fields = Array(data["fields"])
      reads = Array(data["read_rewrites"])
      signatures = Array(data["signatures"]).select { |signature| signature["path"].to_s == action["path"].to_s }
      blockers = Array(data["blockers"])
      return false unless blockers.empty?
      return false if struct_name.empty? || fields.empty? || literal["code"].to_s.empty?

      changed = false
      source = lines.join
      parsed = Syntax.parse(source)
      if parsed.success?
        edits = []
        replacement = hash_record_constructor(struct_name, literal["code"])
        if replacement
          node = first_node_matching_source(parsed.value, literal["line"].to_i, literal["code"].to_s)
          edits << [node.location.start_offset, node.location.end_offset, replacement] if node
        end
        reads.each do |read|
          code = read["code"].to_s
          replacement = read["replacement"].to_s
          next if code.empty? || replacement.empty?
          nodes_matching_source(parsed.value, read["line"].to_i, code).each do |node|
            edits << [node.location.start_offset, node.location.end_offset, replacement]
          end
        end
        edits.concat(hash_record_signature_edits(parsed.value, signatures))
        unless edits.empty?
          lines.replace(apply_source_edits(source, edits).lines)
          changed = true
        end
      end
      changed = insert_hash_record_struct(lines, data) || changed
      changed
    end

    def apply_hash_record_cluster_promotion(lines, action)
      data = action["data"] || {}
      struct_name = data["struct_name"].to_s
      type_name = (data["type_name"] || struct_name).to_s
      fields = Array(data["fields"])
      producers = Array(data["producers"]).select { |producer| producer["path"].to_s == action["path"].to_s }
      consumers = Array(data["consumers"]).select { |consumer| consumer["path"].to_s == action["path"].to_s }
      signatures = Array(data["signatures"]).select { |signature| signature["path"].to_s == action["path"].to_s }
      blockers = Array(data["blockers"])
      return false unless blockers.empty?
      insert_only = data.fetch("insert_struct", true) && action["path"].to_s == data["struct_path"].to_s
      return false if struct_name.empty? || type_name.empty? || fields.empty? || (producers.empty? && consumers.empty? && signatures.empty? && !insert_only)

      source = lines.join
      parsed = Syntax.parse(source)
      return false unless parsed.success?

      edits = []
      producers.each do |producer|
        nodes_matching_source(parsed.value, producer["line"].to_i, producer["code"].to_s).each do |node|
          replacement = hash_record_constructor_from_node(type_name, node, consumers, fields)
          next unless replacement
          edits << [node.location.start_offset, node.location.end_offset, replacement]
        end
      end
      consumers.each do |consumer|
        replacement = hash_record_consumer_replacement(consumer)
        next unless replacement
        nodes_matching_source(parsed.value, consumer["line"].to_i, consumer["code"].to_s).each do |node|
          edits << [node.location.start_offset, node.location.end_offset, replacement]
        end
      end
      edits.concat(hash_record_signature_edits(parsed.value, signatures))
      changed = false
      unless edits.empty?
        lines.replace(apply_source_edits(source, edits).lines)
        changed = true
      end

      changed = insert_hash_record_struct(lines, data) || changed if data.fetch("insert_struct", true) && (changed || insert_only)
      changed
    end

    def hash_record_consumer_replacement(consumer)
      receiver = consumer["receiver"].to_s
      key = consumer["key"].to_s
      return nil if receiver.empty? || key.empty? || !key.match?(/\A[a-z_]\w*\z/)
      "#{receiver}.#{key}"
    end

    def apply_signature_cst_rewrite(lines, action, kind, name, from, to)
      return false if to.empty? || from.empty?
      source = lines.join
      parsed = Syntax.parse(source)
      return false unless parsed.success?
      sig_node = nearest_sig_call_before_line(parsed.value, action["line"].to_i)
      return false unless sig_node
      edit =
        if kind == "param"
          target = signature_param_type_node(sig_node, name.to_s, from)
          target ? [target.location.start_offset, target.location.end_offset, to] : nil
        elsif to == "void"
          signature_void_return_edit(sig_node, from)
        else
          target = signature_return_type_node(sig_node, from)
          target ? [target.location.start_offset, target.location.end_offset, to] : nil
        end
      return false unless edit
      lines.replace(apply_source_edits(source, [edit]).lines)
      true
    end

    def apply_narrow_tlet_cst_rewrite(lines, action)
      source = lines.join
      parsed = Syntax.parse(source)
      return false unless parsed.success?
      node = nodes_matching(parsed.value) do |candidate|
        candidate.is_a?(Syntax::CallNode) &&
          candidate.location.start_line == action["line"].to_i &&
          candidate.name == :let &&
          candidate.receiver&.slice == "T" &&
          candidate.arguments&.arguments&.[](1)&.slice == "T.untyped"
      end.first
      type_node = node&.arguments&.arguments&.[](1)
      return false unless type_node
      lines.replace(apply_source_edits(source, [[type_node.location.start_offset, type_node.location.end_offset, action["data"]["type"].to_s]]).lines)
      true
    end

    def apply_add_tlet_cst_rewrite(lines, action)
      source = lines.join
      parsed = Syntax.parse(source)
      return false unless parsed.success?
      name = action["data"]["name"].to_s
      node = nodes_matching(parsed.value) do |candidate|
        variable_write_node?(candidate) &&
          candidate.location.start_line == action["line"].to_i &&
          candidate.respond_to?(:name) &&
          candidate.name.to_s == name
      end.first
      value = node&.value
      return false unless value
      replacement = "T.let(#{value.slice}, #{action["data"]["type"]})"
      lines.replace(apply_source_edits(source, [[value.location.start_offset, value.location.end_offset, replacement]]).lines)
      true
    end

    def variable_write_node?(node)
      node.is_a?(Syntax::LocalVariableWriteNode) ||
        node.is_a?(Syntax::InstanceVariableWriteNode) ||
        node.is_a?(Syntax::ClassVariableWriteNode) ||
        node.is_a?(Syntax::GlobalVariableWriteNode)
    end

    def apply_safe_nav_cst_rewrite(lines, action)
      source = lines.join
      parsed = Syntax.parse(source)
      return false unless parsed.success?
      code = action.dig("data", "code").to_s
      nodes = if code.empty?
        nodes_matching(parsed.value) { |node| node.is_a?(Syntax::CallNode) && node.location.start_line == action["line"].to_i && node.safe_navigation? }
      else
        nodes_matching_source(parsed.value, action["line"].to_i, code).select { |node| node.is_a?(Syntax::CallNode) && node.safe_navigation? }
      end
      return false if nodes.empty?
      edits = nodes.filter_map do |node|
        replacement = node.slice.to_s.gsub("&.", ".")
        [node.location.start_offset, node.location.end_offset, replacement] if replacement != node.slice
      end
      return false if edits.empty?
      lines.replace(apply_source_edits(source, edits).lines)
      true
    end

    def apply_exact_code_cst_rewrite(lines, action, replacement)
      code = action.dig("data", "code").to_s
      return false if code.empty?
      source = lines.join
      parsed = Syntax.parse(source)
      return false unless parsed.success?
      nodes = nodes_matching_source(parsed.value, action["line"].to_i, code)
      return false if nodes.empty?
      edits = nodes.map { |node| [node.location.start_offset, node.location.end_offset, replacement] }
      lines.replace(apply_source_edits(source, edits).lines)
      true
    end

    def apply_nil_default_cst_rewrite(lines, action)
      source = lines.join
      parsed = Syntax.parse(source)
      return false unless parsed.success?
      nils = nodes_matching(parsed.value) { |node| node.is_a?(Syntax::NilNode) && node.location.start_line == action["line"].to_i }
      return false unless nils.size == 1
      node = nils.first
      lines.replace(apply_source_edits(source, [[node.location.start_offset, node.location.end_offset, action.dig("data", "default").to_s]]).lines)
      true
    end

    def first_node_matching_source(node, line, code)
      nodes_matching_source(node, line, code).first
    end

    def hash_record_signature_edits(root, signatures)
      Array(signatures).filter_map do |signature|
        sig_node = nearest_sig_call_before_line(root, signature["line"].to_i)
        next unless sig_node
        target =
          case signature["kind"]
          when "return"
            signature_return_type_node(sig_node, signature["from"].to_s)
          when "param"
            signature_param_type_node(sig_node, signature["name"].to_s, signature["from"].to_s)
          end
        next unless target
        [target.location.start_offset, target.location.end_offset, signature["type"].to_s]
      end
    end

    def nearest_sig_call_before_line(root, line)
      sigs = nodes_matching(root) do |node|
        node.is_a?(Syntax::CallNode) && node.name == :sig && node.location.end_line < line
      end
      sigs.select { |node| line - node.location.end_line <= 30 }.max_by { |node| node.location.end_line }
    end

    def signature_return_type_node(sig_node, from)
      nodes_matching(sig_node) do |node|
        node.is_a?(Syntax::CallNode) && node.name == :returns
      end.filter_map { |node| node.arguments&.arguments&.first }.find { |arg| arg&.slice == from }
    end

    def signature_void_return_edit(sig_node, from)
      returns_node = nodes_matching(sig_node) do |node|
        node.is_a?(Syntax::CallNode) && node.name == :returns
      end.find { |node| node.arguments&.arguments&.first&.slice == from }
      return nil unless returns_node
      receiver = returns_node.receiver
      if receiver
        [receiver.location.end_offset, returns_node.location.end_offset, ".void"]
      else
        [returns_node.location.start_offset, returns_node.location.end_offset, "void"]
      end
    end

    def signature_param_type_node(sig_node, name, from)
      params_call = nodes_matching(sig_node) do |node|
        node.is_a?(Syntax::CallNode) && node.name == :params
      end.first
      keyword_hash = params_call&.arguments&.arguments&.find { |arg| arg.is_a?(Syntax::KeywordHashNode) }
      keyword_hash&.elements&.filter_map do |assoc|
        next unless assoc.respond_to?(:key) && assoc.respond_to?(:value)
        key = signature_keyword_name(assoc.key)
        assoc.value if key == name && assoc.value&.slice == from
      end&.first
    end

    def signature_keyword_name(node)
      case node
      when Syntax::SymbolNode
        node.value.to_s
      when Syntax::StringNode
        node.content.to_s
      end
    end

    def nodes_matching(node, matches = [], &block)
      return matches unless node
      matches << node if yield(node)
      node.child_nodes.compact.each { |child| nodes_matching(child, matches, &block) } if node.respond_to?(:child_nodes)
      matches
    end

    def nodes_matching_source(node, line, code, matches = [])
      return matches unless node
      loc = node.respond_to?(:location) ? node.location : nil
      matches << node if loc && loc.start_line == line && node.respond_to?(:slice) && node.slice == code
      node.child_nodes.compact.each { |child| nodes_matching_source(child, line, code, matches) } if node.respond_to?(:child_nodes)
      matches
    end

    def apply_source_edits(source, edits)
      bytes = source.b
      non_overlapping_source_edits(edits).sort_by { |start_offset, _end_offset, _replacement| -start_offset }.each do |start_offset, end_offset, replacement|
        bytes = bytes.byteslice(0, start_offset) + replacement.b + bytes.byteslice(end_offset..).to_s
      end
      bytes
    end

    def non_overlapping_source_edits(edits)
      kept = []
      edits.sort_by { |start_offset, end_offset, _replacement| [start_offset, -(end_offset - start_offset)] }.each do |edit|
        start_offset, end_offset, = edit
        next if kept.any? { |kept_start, kept_end, _| start_offset >= kept_start && end_offset <= kept_end }
        kept << edit
      end
      kept
    end

    def hash_record_constructor(struct_name, hash_code)
      source = hash_code.to_s.strip
      return nil unless source.start_with?("{") && source.end_with?("}")
      "#{struct_name}.new(#{source[1...-1].strip})"
    end

    def hash_record_constructor_from_node(struct_name, node, consumers, fields = [])
      source = node.slice.to_s
      relative_edits = []
      Array(consumers).each do |consumer|
        replacement = hash_record_consumer_replacement(consumer)
        next unless replacement
        nodes_matching_source(node, consumer["line"].to_i, consumer["code"].to_s).each do |consumer_node|
          relative_edits << [
            consumer_node.location.start_offset - node.location.start_offset,
            consumer_node.location.end_offset - node.location.start_offset,
            replacement,
          ]
        end
      end
      rewritten = if relative_edits.empty?
        source
      else
        apply_source_edits(source, relative_edits)
      end
      hash_record_constructor(struct_name, hash_record_cast_constructor_fields(rewritten, fields))
    end

    def hash_record_cast_constructor_fields(hash_code, fields)
      field_types = Array(fields).each_with_object({}) { |field, index| index[field["name"].to_s] = field["type"].to_s }
      return hash_code if field_types.empty?
      parsed = Syntax.parse(hash_code)
      return hash_code unless parsed.success?
      edits = []
      root_hash = nodes_matching(parsed.value) { |node| node.is_a?(Syntax::HashNode) || node.is_a?(Syntax::KeywordHashNode) }.first
      edits.concat(hash_record_nested_constructor_edits(root_hash, fields)) if root_hash
      nodes_matching(parsed.value) do |node|
        (node.is_a?(Syntax::HashNode) || node.is_a?(Syntax::KeywordHashNode))
      end.each do |hash|
        Array(hash.elements).each do |assoc|
          next unless assoc.respond_to?(:key) && assoc.respond_to?(:value)
          key = hash_record_constructor_key_name(assoc.key)
          type = field_types[key.to_s]
          next unless hash_record_constructor_cast_type?(type)
          value = assoc.value
          next unless hash_record_constructor_cast_needed?(value, type)
          next if value.slice.to_s.start_with?("T.cast(")
          edits << [value.location.start_offset, value.location.end_offset, "T.cast(#{value.slice}, #{type})"]
        end
      end
      edits.empty? ? hash_code : apply_source_edits(hash_code, edits)
    end

    def hash_record_nested_constructor_edits(hash, fields)
      nested_by_field = Array(fields).each_with_object({}) do |field, index|
        index[field["name"].to_s] = field["nested"] if field["nested"]
      end
      return [] if nested_by_field.empty?
      Array(hash.elements).flat_map do |assoc|
        next [] unless assoc.respond_to?(:key) && assoc.respond_to?(:value)
        key = hash_record_constructor_key_name(assoc.key)
        nested = nested_by_field[key.to_s]
        next [] unless nested
        type_name = nested["type_name"].to_s
        next [] if type_name.empty?
        case nested["kind"]
        when "hash"
          value = assoc.value
          next [] unless value.is_a?(Syntax::HashNode) || value.is_a?(Syntax::KeywordHashNode)
          rewritten = hash_record_cast_constructor_fields(value.slice, nested["fields"])
          [[value.location.start_offset, value.location.end_offset, hash_record_constructor(type_name, rewritten)]]
        when "array"
          value = assoc.value
          next [] unless value.is_a?(Syntax::ArrayNode)
          Array(value.elements).filter_map do |elem|
            next unless elem.is_a?(Syntax::HashNode) || elem.is_a?(Syntax::KeywordHashNode)
            rewritten = hash_record_cast_constructor_fields(elem.slice, nested["fields"])
            [elem.location.start_offset, elem.location.end_offset, hash_record_constructor(type_name, rewritten)]
          end
        else
          []
        end
      end
    end

    def hash_record_constructor_key_name(node)
      case node
      when Syntax::SymbolNode
        node.respond_to?(:value) ? node.value.to_s : node.slice.delete_prefix(":")
      when Syntax::StringNode
        node.respond_to?(:unescaped) ? node.unescaped : node.slice.delete_prefix("\"").delete_prefix("'").delete_suffix("\"").delete_suffix("'")
      else
        nil
      end
    end

    def hash_record_constructor_cast_needed?(value, type)
      raw = type.to_s
      case value
      when Syntax::NilNode
        !raw.start_with?("T.nilable(")
      when Syntax::TrueNode, Syntax::FalseNode
        raw != "T::Boolean" && raw != "T.nilable(T::Boolean)" && raw != "T.untyped"
      when Syntax::IntegerNode
        raw != "Integer" && raw != "T.untyped"
      when Syntax::StringNode
        raw != "String" && raw != "T.untyped"
      when Syntax::SymbolNode
        raw != "Symbol" && raw != "T.untyped"
      when Syntax::ArrayNode
        !(raw.start_with?("T::Array[") || raw.start_with?("T.nilable(T::Array[") || raw == "T.untyped")
      when Syntax::HashNode, Syntax::KeywordHashNode
        !(raw.start_with?("T::Hash[") || raw.start_with?("T.nilable(T::Hash[") || raw == "T.untyped")
      else
        true
      end
    end

    def hash_record_constructor_cast_type?(type)
      raw = type.to_s
      return false if raw.empty? || raw == "T.untyped" || raw == "Object"
      raw.include?("::") || raw.start_with?("T.any(")
    end

    def insert_hash_record_struct(lines, data)
      struct_name = data["struct_name"].to_s
      return false if struct_name.empty? || lines.any? { |line| line.match?(/\bclass\s+#{Regexp.escape(struct_name)}\b/) }
      fields = Array(data["fields"])
      parsed = Syntax.parse(lines.join)
      return false unless parsed.success?
      scope = Array(data["scope"])
      if scope.empty?
        insert_at = top_level_struct_insert_index(lines)
        lines.insert(insert_at, *hash_record_all_struct_lines(data, ""))
        return true
      end
      node = find_scope_node(parsed.value, scope)
      return false unless node
      insert_at = hash_record_struct_insert_index(lines, node, data)
      indent = lines[node.location.start_line - 1][/^\s*/] + "  "
      lines.insert(insert_at, *hash_record_all_struct_lines(data, indent))
      true
    rescue StandardError => e
      warn "could not insert hash-record struct #{data["struct_name"]}: #{e.message}"
      false
    end

    def hash_record_struct_insert_index(lines, scope_node, data)
      insert_at = scope_node.location.start_line
      while lines[insert_at]&.match?(/^\s*extend\s+T::Sig\b/)
        insert_at += 1
      end
      dependency_lines = hash_record_struct_dependency_nodes(scope_node, data).map { |node| node.location.end_line }
      dependency_lines.empty? ? insert_at : [insert_at, dependency_lines.max].max
    end

    def hash_record_struct_dependency_nodes(scope_node, data)
      names = hash_record_struct_dependency_names(data).to_set
      return [] if names.empty?
      matches = []
      scope_node.child_nodes.compact.each do |child|
        nodes_matching(child) do |node|
          if node.is_a?(Syntax::ClassNode) || node.is_a?(Syntax::ModuleNode)
            names.include?(node.constant_path.slice.to_s.split("::").last)
          elsif node.is_a?(Syntax::ConstantWriteNode)
            # `Foo = Struct.new(...)` and similar constant-assigned types
            # are also legitimate dependency targets. Without recognising
            # them, the promoter inserts the new struct ABOVE its own
            # field-type reference, breaking `require` at load time
            # (e.g. MIR::NameRecord with field MIR::StructInit, where
            # StructInit is `StructInit = Struct.new(...)` later in the
            # same file).
            names.include?(node.name.to_s)
          else
            false
          end
        end.each { |node| matches << node }
      end
      matches
    end

    def hash_record_struct_dependency_names(data)
      scope = Array(data["scope"]).map(&:to_s).reject(&:empty?)
      return [] if scope.empty?
      namespace = scope.join("::")
      Array(data["fields"]).flat_map do |field|
        field["type"].to_s.scan(/\b#{Regexp.escape(namespace)}::([A-Z]\w*)\b/).flatten
      end.uniq
    end

    def top_level_struct_insert_index(lines)
      insert_at = 0
      lines.each_with_index do |line, idx|
        stripped = line.strip
        if stripped.empty? || line.start_with?("#") || stripped.match?(/\Arequire\s+["'][^"']+["']/)
          insert_at = idx + 1
        else
          break
        end
      end
      insert_at
    end

    def hash_record_struct_lines(struct_name, fields, indent)
      lines = ["#{indent}class #{struct_name} < T::Struct\n"]
      fields.each do |field|
        keyword = field["optional"] ? "prop" : "const"
        lines << "#{indent}  #{keyword} :#{field["name"]}, #{field["type"]}\n"
      end
      lines << "#{indent}end\n"
      lines << "\n"
      lines
    end

    def hash_record_all_struct_lines(data, indent)
      nested = Array(data["nested_structs"])
      nested.flat_map { |record| hash_record_struct_lines(record["struct_name"], record["fields"], indent) } +
        hash_record_struct_lines(data["struct_name"], data["fields"], indent)
    end

    def ensure_sorbet_runtime(lines)
      return if lines.any? { |line| line.match?(/require ["']sorbet-runtime["']/) }
      insert_at = 0
      lines.each_with_index do |line, idx|
        if line.start_with?("#") || line.strip.empty?
          insert_at = idx + 1
        else
          break
        end
      end
      lines.insert(insert_at, "require \"sorbet-runtime\"\n", "\n")
    end

    def ensure_sig_extensions(lines, rel_path, sig_actions)
      scopes = sig_actions.filter_map { |action| action.dig("data", "scope") }.uniq
      return if scopes.empty?
      parsed = Syntax.parse(lines.join)
      return unless parsed.success?
      insertions = []
      scopes.each do |scope|
        next if scope.empty?
        node = find_scope_node(parsed.value, scope)
        next unless node
        body_range = node.location.start_line..node.location.end_line
        next if body_range.any? { |line_no| lines[line_no - 1]&.match?(/\bextend\s+T::Sig\b/) }
        indent = lines[node.location.start_line - 1][/^\s*/] + "  "
        insertions << [node.location.start_line, "#{indent}extend T::Sig\n", "\n"]
      end
      insertions.sort_by { |line_no, _text, _blank| line_no }.reverse_each do |line_no, *text|
        lines.insert(line_no, *text)
      end
    rescue StandardError => e
      warn "#{rel_path}: could not ensure extend T::Sig: #{e.message}"
    end

    def find_scope_node(root, scope)
      found = nil
      walk = lambda do |node, stack|
        return if found
        case node
        when Syntax::ClassNode, Syntax::ModuleNode
          new_stack = stack + [node.constant_path.slice]
          found = node if new_stack == scope
          node.child_nodes.compact.each { |child| walk.call(child, new_stack) } if node.respond_to?(:child_nodes)
        else
          node.child_nodes.compact.each { |child| walk.call(child, stack) } if node.respond_to?(:child_nodes)
        end
      end
      walk.call(root, [])
      found
    end

    def find_sig_idx(lines, def_idx)
      (def_idx - 1).downto([def_idx - 5, 0].max) { |i| return i if lines[i]&.match?(/\bsig\s*\{/) }
      nil
    end

    DEF_HEADER = /\A\s*(?:(?:private|public|protected|private_class_method|public_class_method|module_function)\s+)?def\s+(?:self\.)?([A-Za-z_]\w*[!?=]?)/.freeze

    # The raw `action["line"]` is only a HINT. If the source shifted
    # under it (a rebase, or another edit in this batch) the indexed
    # line is no longer the target `def` -- blindly inserting there
    # drops the sig as dead code mid-body / before module_function and
    # poisons sorbet-runtime's global pending-sig state (the c34cc62f
    # corruption). Trust the hint ONLY when it actually lands on the
    # named def; otherwise re-locate the def by name via Tree-sitter, and if
    # it cannot be resolved unambiguously, REFUSE (a skipped sig is
    # always better than a corrupted source).
    def resolve_add_sig_idx(lines, idx, action)
      want = action.dig("data", "method").to_s
      hinted = lines[idx] && lines[idx][DEF_HEADER, 1]
      return idx if hinted && (want.empty? || hinted == want)
      return nil if want.empty? # no anchor + bad hint -> never guess
      relocate_def_idx(lines, want, Array(action.dig("data", "scope")))
    end

    # Tree-sitter-locate the `def want` whose enclosing class/module scope
    # best matches `scope`. Exactly one candidate -> its 0-based line;
    # zero or ambiguous -> nil (caller skips rather than corrupt).
    def relocate_def_idx(lines, want, scope)
      parsed = Syntax.parse(lines.join)
      return nil unless parsed.success?
      cands = []
      walk = lambda do |node, stack|
        return unless node.is_a?(Syntax::Node)
        case node
        when Syntax::DefNode
          cands << [stack.dup, node.location.start_line - 1] if node.name.to_s == want
        when Syntax::ClassNode, Syntax::ModuleNode
          stack = stack + [node.constant_path.slice]
        end
        node.compact_child_nodes.each { |c| walk.call(c, stack) }
      end
      walk.call(parsed.value, [])
      return nil if cands.empty?
      return cands.first[1] if cands.size == 1
      scoped = cands.select { |st, _| st.last == scope.last || st == scope }
      scoped.size == 1 ? scoped.first[1] : nil
    end
  end
end
