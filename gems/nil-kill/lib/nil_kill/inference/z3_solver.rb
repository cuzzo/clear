# typed: false
# frozen_string_literal: true

# Z3-based type analysis for the nil-kill pipeline. Three capabilities:
#
# A2 - consistent?(actions): pre-filters bisect batches.
#   Builds a call graph and encodes Sorbet subtype axioms in SMT2. For each
#   fix_sig_return action, checks whether the proposed return type would violate
#   an existing typed param at a call site. If Z3 returns UNSAT, bisects the
#   batch immediately, skipping the 30-120s spec run.
#
# A3 - infer_unobserved_params(evidence): new candidate discovery.
#   For methods never hit in the corpus (512 methods), aggregates literal and
#   typed-return argument types seen at call sites. Proposes add_sig actions
#   for any method whose params can be inferred from static call site evidence.
#
# A4 - provably_dead_safe_nav?(action): false-positive prevention.
#   For each remove_dead_safe_nav HIGH action, scans the method scope for any
#   nil assignment or nilable-return assignment to the receiver variable. If
#   found, blocks the action (the &. may be live even though the corpus never
#   observed nil). Retires the nil-kill-skip.json workaround for these cases.

require 'open3'
require 'set'

module NilKill
  class Z3Solver
    BUILT_IN_SUBTYPES = {
      "TrueClass"  => ["T::Boolean"],
      "FalseClass" => ["T::Boolean"],
      "Integer"    => ["Numeric"],
      "Float"      => ["Numeric"],
    }.freeze

    def initialize(evidence, source_files)
      @evidence = evidence
      @source_files = Array(source_files)
      @type_ids = {}        # type_string => integer id
      @sig_index = nil      # lazy: method_name => [{params, return_type}]
      @call_graph = nil     # lazy: callee_name => [{receiver_method, arg_kind, ...}]
      @param_sources = nil  # lazy: receiver_name => {keyword: {name => [types]}, positional: {pos => [types]}}
    end

    # A2: Returns true if SAT (batch may be ok), false if UNSAT (definitely
    # inconsistent -- bisect without running specs).
    def consistent?(actions)
      return true unless z3_available?
      constraints = collect_constraints(actions)
      return true if constraints.empty?
      sat?(constraints, actions)
    end

    # A3: For methods never observed in the corpus, infer param types from
    # call site evidence (literals + typed returns). Returns add_sig REVIEW
    # actions for any method whose params are consistently typed.
    def infer_unobserved_params(evidence)
      ps = param_sources
      si = sig_index
      # Only generate inferences for uniquely-named methods to avoid false
      # positives from name collisions (e.g. multiple classes define "run").
      unique_method_names = build_unique_method_names(evidence)

      unobserved = evidence["methods"].select { |m| m["calls"].to_i.zero? && !m["has_sig"] }
      new_actions = []

      unobserved.each do |rec|
        src = rec["source"]
        next unless src
        method_name = src["method"].to_s
        next unless unique_method_names.include?(method_name)

        sources = ps[method_name] || {}
        next if sources.empty?

        params = Array(src["params"])
        inferred = {}
        params.each_with_index do |param, idx|
          name = param["name"]
          # Prefer keyword match, fall back to positional
          types = sources.dig(:keyword, name)
          types = sources.dig(:positional, idx) if types.nil? || types.empty?
          types ||= []
          types = types.flatten.compact.uniq.reject { |t| t == "NilClass" }
          next if types.empty?
          # Also gather from sig returns for method-call args at this position
          types += resolve_method_call_types(method_name, idx, name, si)
          types = types.uniq
          type = NilKill.sorbet_type(types)
          inferred[name] = type if NilKill.useful_type?(type)
        end

        next if inferred.empty?

        params_str = params.map { |p| "#{p["name"]}: #{inferred[p["name"]] || "T.untyped"}" }.join(", ")
        clause = params_str.empty? ? "void" : "params(#{params_str}).returns(T.untyped)"
        sig = "sig { #{clause} }"

        new_actions << {
          "kind"       => "add_sig",
          "confidence" => REVIEW,
          "path"       => src["path"],
          "line"       => src["line"],
          "message"    => "Z3 static inference: #{inferred.map { |k, v| "#{k}: #{v}" }.join(", ")} (method absent from corpus)",
          "data"       => { "sig" => sig, "scope" => src["scope"] },
        }
      end

      new_actions
    end

    # A5: fast static/Z3-adjacent action preflight. This catches classes of
    # bad type rewrites before the guarded loop pays for Sorbet bisection.
    # Z3 still handles subtype batch consistency; these checks reject proposed
    # type strings or local source shapes that are not valid Sorbet contracts.
    def preflight_rejection(action)
      type = action.dig("data", "type").to_s
      return nil if type.empty?

      return "candidate union exceeds cutoff" if NilKill.broad_union_type?(type)
      return "candidate uses bare generic collection type" if bare_collection_type?(type)
      return "array candidate conflicts with tuple-like return shape" if tuple_like_array_return?(action, type)
      return "hash candidate collapses per-key symbol shape" if heterogeneous_symbol_hash_shape?(action, type)
      return "container candidate conflicts with receiver protocol use" if container_protocol_mismatch?(action, type)

      nil
    rescue StandardError => e
      "preflight analysis failed: #{e.class}: #{e.message}"
    end

    # A4: Returns true if the receiver IS provably non-nil (allow the action).
    # Returns false if the receiver might be nil (block the action).
    # Covers both remove_dead_safe_nav ("foo&.bar") and
    # replace_dead_nil_check ("foo.nil?") action kinds.
    # Scans the method scope for nil assignments or nilable-return assignments
    # to the receiver variable. Conservative: returns true (allow) when the
    # receiver is complex or the analysis is inconclusive.
    def provably_dead_safe_nav?(action)
      code = action.dig("data", "code")
      return true unless code

      # Extract bare receiver depending on action kind:
      #   remove_dead_safe_nav : "resolved&.dig(a)" -> "resolved"
      #   replace_dead_nil_check: "reason.nil?"     -> "reason"
      receiver = if action["kind"] == "replace_dead_nil_check"
        code.sub(/\.nil\?\z/, "").strip
      else
        code.split("&.").first.strip
      end
      # Skip complex receivers like "foo.bar&.baz" -- can't trace easily
      return true if receiver.include?(".") || receiver.include?("(")

      path = File.join(ROOT, action["path"])
      return true unless File.file?(path)

      lines = File.readlines(path)
      action_line = action["line"].to_i - 1  # 0-indexed

      # Walk backwards from the action to find the enclosing def boundary
      method_start = action_line
      while method_start > 0
        l = lines[method_start - 1]&.strip || ""
        break if l.match?(/\bdef\s+\w/)
        method_start -= 1
      end

      si = sig_index

      # Scan from method_start to action_line for any assignment to receiver
      method_start.upto(action_line - 1) do |i|
        line = lines[i]&.strip || ""
        next unless line.match?(/\b#{Regexp.escape(receiver)}\s*=/)

        if line =~ /\b#{Regexp.escape(receiver)}\s*=\s*(.+)/
          rhs = $1.strip.sub(/\s*#.*\z/, "") # strip inline comment

          # Direct nil assignment
          return false if rhs == "nil"

          # Bare method call whose sig says nilable
          callee = rhs.match(/\A(\w+)(?:\(|\s*$)/)&.captures&.first
          if callee
            recs = si[callee]
            if recs&.size == 1
              ret = recs.first[:return_type]
              return false if ret&.match?(/nilable|NilClass/)
            end
          end
        end
      end

      true
    end

    private

    # ---------- A5 preflight helpers ----------

    def bare_collection_type?(type)
      return true if type.match?(/\A(?:Array|Hash|Set)\z/)
      type.scan(/(?<![:\w])(?:Array|Hash|Set)(?![:\w\[])/).any?
    end

    def tuple_like_array_return?(action, type)
      return false unless %w[fix_sig_return narrow_generic_return].include?(action["kind"])
      return false unless type.include?("T::Array[") || type.match?(/\AArray\z/)
      def_node = action_def_node(action)
      return false unless def_node
      tuple_like_return_arrays(def_node).any?
    end

    def tuple_like_return_arrays(def_node)
      arrays = []
      walk = lambda do |node|
        return unless node
        if node.is_a?(Syntax::ReturnNode)
          Array(node.arguments&.arguments).each { |arg| arrays << arg if tuple_like_array_node?(arg) }
        elsif tuple_like_array_node?(node) && node.location&.start_line == def_node.location&.end_line.to_i - 1
          arrays << node
        end
        node.child_nodes.compact.each { |child| walk.call(child) } if node.respond_to?(:child_nodes)
      end
      walk.call(def_node.body)
      arrays
    end

    def tuple_like_array_node?(node)
      return false unless node.is_a?(Syntax::ArrayNode)
      element_types = node.elements.map { |elem| literal_type(elem) || static_constant_type(elem) }.compact.uniq
      node.elements.size > 1 && element_types.size != 1
    end

    def heterogeneous_symbol_hash_shape?(action, type)
      return false unless type.include?("T::Hash[Symbol, T.any(") || type.include?("T::Hash[Symbol, T.nilable(T.any(")
      def_node = action_def_node(action)
      return false unless def_node

      if action["kind"] == "narrow_generic_param" || action["kind"] == "fix_sig_param"
        name = action.dig("data", "name").to_s
        return false if name.empty?
        return symbol_index_keys(def_node, name).size > 1
      end

      returned_hash_literals(def_node).any? { |hash| heterogeneous_hash_literal?(hash) }
    end

    def returned_hash_literals(def_node)
      hashes = []
      walk = lambda do |node|
        return unless node
        if node.is_a?(Syntax::ReturnNode)
          Array(node.arguments&.arguments).each { |arg| hashes << arg if arg.is_a?(Syntax::HashNode) }
        end
        node.child_nodes.compact.each { |child| walk.call(child) } if node.respond_to?(:child_nodes)
      end
      walk.call(def_node.body)
      hashes
    end

    def heterogeneous_hash_literal?(node)
      value_types = node.elements.filter_map do |assoc|
        next unless assoc.is_a?(Syntax::AssocNode)
        literal_type(assoc.value) || static_constant_type(assoc.value)
      end.uniq
      value_types.size > 1
    end

    def symbol_index_keys(def_node, receiver_name)
      keys = Set.new
      walk = lambda do |node|
        return unless node
        if node.is_a?(Syntax::CallNode) && node.name == :[] && node.receiver&.slice == receiver_name
          arg = node.arguments&.arguments&.first
          keys << arg.value.to_s if arg.is_a?(Syntax::SymbolNode)
        end
        node.child_nodes.compact.each { |child| walk.call(child) } if node.respond_to?(:child_nodes)
      end
      walk.call(def_node.body)
      keys
    end

    def container_protocol_mismatch?(action, type)
      return false unless action["kind"] == "narrow_generic_param" || action["kind"] == "fix_sig_param"
      root = root_container_type(type)
      return false unless root
      name = action.dig("data", "name").to_s
      return false if name.empty?
      def_node = action_def_node(action)
      return false unless def_node

      protocol_calls(def_node, name).any? do |call|
        !container_supports_protocol?(root, call)
      end
    end

    def root_container_type(type)
      case type
      when /\AT::Hash\b/, /\AHash\b/ then "Hash"
      when /\AT::Array\b/, /\AArray\b/ then "Array"
      when /\AT::Set\b/, /\ASet\b/ then "Set"
      end
    end

    def protocol_calls(def_node, receiver_name)
      calls = Set.new
      walk = lambda do |node|
        return unless node
        if node.is_a?(Syntax::CallNode)
          receiver = node.receiver
          if receiver&.slice == receiver_name
            calls << node.name.to_s
          elsif receiver.is_a?(Syntax::CallNode) && receiver.name == :class && receiver.receiver&.slice == receiver_name
            calls << "class.#{node.name}"
          end
        end
        node.child_nodes.compact.each { |child| walk.call(child) } if node.respond_to?(:child_nodes)
      end
      walk.call(def_node.body)
      calls
    end

    def container_supports_protocol?(root, call)
      allowed = {
        "Array" => %w[[] []= each each_with_index empty? first last length size map filter select reject push << class name],
        "Hash" => %w[[] []= each each_pair keys values empty? length size merge merge! fetch dig class name],
        "Set" => %w[add << each include? empty? length size merge class name],
      }.fetch(root, [])
      allowed.include?(call)
    end

    def action_def_node(action)
      path = File.join(ROOT, action["path"].to_s)
      return nil unless File.file?(path)
      parsed = Syntax.parse_file(path)
      return nil unless parsed.success?
      target_line = action["line"].to_i
      find_def_node(parsed.value, target_line)
    end

    def find_def_node(node, target_line)
      return nil unless node
      if node.is_a?(Syntax::DefNode)
        start_line = node.location.start_line
        end_line = node.location.end_line
        return node if target_line >= start_line && target_line <= end_line
      end
      return nil unless node.respond_to?(:child_nodes)
      node.child_nodes.compact.filter_map { |child| find_def_node(child, target_line) }.first
    end

    def static_constant_type(node)
      return nil unless node.is_a?(Syntax::ConstantReadNode) || node.is_a?(Syntax::ConstantPathNode)
      "T.class_of(#{node.slice})"
    end

    # ---------- constraint collection ----------

    def collect_constraints(actions)
      si = sig_index
      cg = call_graph
      constraints = []

      actions.each do |action|
        next unless action.is_a?(Hash) && action["kind"] == "fix_sig_return"
        proposed = action.dig("data", "type")
        next unless proposed && proposed != "T.untyped"
        method_name = method_name_for(action)
        next unless method_name

        (cg[method_name] || []).each do |edge|
          receiver = edge[:receiver_method]
          recs = si[receiver]
          # Skip if ambiguous method name (multiple classes define it)
          next if recs.nil? || recs.size != 1
          param_type = param_type_from_edge(recs.first[:params], edge)
          next if param_type.nil? || param_type == "T.untyped"
          # Constraint: proposed must be a subtype of param_type
          constraints << [type_id(proposed), type_id(param_type)]
          # Ensure NilClass is in the lattice if needed for nilable reasoning
          if proposed.start_with?("T.nilable(")
            inner = proposed[10..-2]
            type_id(inner)
            type_id("NilClass")
          end
          if param_type.start_with?("T.nilable(")
            inner = param_type[10..-2]
            type_id(inner)
            type_id("NilClass")
          end
        end
      end

      constraints
    end

    def param_type_from_edge(params, edge)
      case edge[:arg_kind]
      when :keyword
        params.find { |p| p[:name] == edge[:arg_name] }&.fetch(:type, nil)
      when :positional
        params[edge[:arg_position]]&.fetch(:type, nil)
      end
    end

    # ---------- sig index ----------

    def sig_index
      @sig_index ||= build_sig_index
    end

    def build_sig_index
      index = Hash.new { |h, k| h[k] = [] }
      (@evidence["facts"]["existing_sigs"] || []).each do |rec|
        name = rec["method"].to_s
        sig  = rec["sig"].to_s
        ret    = extract_return_type(sig)
        params = extract_param_types(sig)
        index[name] << { return_type: ret, params: params }
      end
      index
    end

    def extract_return_type(sig)
      sig.match(/\.returns\((.+?)\)\s*\}/)&.captures&.first
    end

    def extract_param_types(sig)
      m = sig.match(/params\((.+?)\)\.(returns|void)/)
      return [] unless m
      parse_params(m[1])
    end

    # Parses "name: Type, name: Type" handling nested parens in types.
    def parse_params(str)
      result = []
      remaining = str.strip
      while remaining =~ /\A(\w+):\s*/
        name = $1
        remaining = remaining[$&.length..]
        type = extract_type_token(remaining)
        result << { name: name, type: type }
        remaining = remaining[type.length..].lstrip.sub(/\A,\s*/, "")
      end
      result
    end

    def extract_type_token(str)
      depth = 0
      i = 0
      str.each_char do |ch|
        case ch
        when '(' then depth += 1
        when ')' then
          break if depth == 0
          depth -= 1
        when ',' then break if depth == 0
        end
        i += 1
      end
      str[0...i].rstrip
    end

    # ---------- call graph + param sources ----------

    def call_graph
      build_graphs unless @call_graph
      @call_graph
    end

    def param_sources
      build_graphs unless @param_sources
      @param_sources
    end

    # Builds both the call graph (A2) and param_sources (A3) in one pass.
    # call_graph[callee] = [{receiver_method, arg_kind, arg_position|arg_name}]
    # param_sources[receiver][kind][key] = [type_strings]
    def build_graphs
      @call_graph   = Hash.new { |h, k| h[k] = [] }
      @param_sources = Hash.new { |h, k| h[k] = { keyword: Hash.new([]), positional: Hash.new([]) } }
      @source_files.each do |path|
        parsed = Syntax.parse_file(path)
        next unless parsed.success?
        walk_node(parsed.value, nil)
      rescue StandardError
        next
      end
    end

    def walk_node(node, enclosing)
      return unless node

      if node.is_a?(Syntax::DefNode)
        enclosing = node.name.to_s
      end

      if node.is_a?(Syntax::CallNode) && enclosing
        record_call_edges(node, enclosing)
      end

      return unless node.respond_to?(:child_nodes)
      node.child_nodes.compact.each { |c| walk_node(c, enclosing) }
    end

    def record_call_edges(call_node, _enclosing)
      receiver_method = call_node.name.to_s
      args = call_node.arguments&.arguments || []

      args.each_with_index do |arg, pos|
        if arg.is_a?(Syntax::KeywordHashNode)
          arg.elements.each do |assoc|
            next unless assoc.is_a?(Syntax::AssocNode)
            key = assoc.key.is_a?(Syntax::SymbolNode) ? assoc.key.value.to_s : nil
            next unless key

            if assoc.value.is_a?(Syntax::CallNode) && !assoc.value.safe_navigation?
              @call_graph[assoc.value.name.to_s] << {
                receiver_method: receiver_method,
                arg_kind: :keyword,
                arg_name: key,
              }
            end

            # A3: record literal type at this keyword position
            lit = literal_type(assoc.value)
            if lit
              src = @param_sources[receiver_method]
              src[:keyword] = src[:keyword].dup unless src[:keyword].respond_to?(:store)
              src[:keyword][key] = (src[:keyword][key] + [lit]).uniq
            end
          end
        else
          if arg.is_a?(Syntax::CallNode) && !arg.safe_navigation?
            @call_graph[arg.name.to_s] << {
              receiver_method: receiver_method,
              arg_kind: :positional,
              arg_position: pos,
            }
          end

          # A3: record literal type at this positional slot
          lit = literal_type(arg)
          if lit
            src = @param_sources[receiver_method]
            src[:positional] = src[:positional].dup unless src[:positional].respond_to?(:store)
            src[:positional][pos] = (src[:positional][pos] + [lit]).uniq
          end
        end
      end
    end

    # Infer a static type for a literal or simple expression. Returns nil for
    # anything that requires dataflow (variables, complex calls).
    def literal_type(node)
      case node
      when Syntax::StringNode         then "String"
      when Syntax::SymbolNode         then "Symbol"
      when Syntax::IntegerNode        then "Integer"
      when Syntax::FloatNode          then "Float"
      when Syntax::TrueNode           then "TrueClass"
      when Syntax::FalseNode          then "FalseClass"
      when Syntax::NilNode            then "NilClass"
      when Syntax::ArrayNode          then "Array"
      when Syntax::HashNode           then "Hash"
      end
    end

    # A3 helper: for a receiver_method+param, look up what return types other
    # sigs-bearing methods return when passed at call sites.
    def resolve_method_call_types(receiver_method, pos, param_name, si)
      types = []
      (@call_graph[receiver_method] || []).each do |edge|
        next unless (edge[:arg_kind] == :positional && edge[:arg_position] == pos) ||
                    (edge[:arg_kind] == :keyword && edge[:arg_name] == param_name)
        # Nope: this edge is "receiver_method's return flows to edge[:receiver_method]"
        # We want the reverse: what flows INTO receiver_method's param
        # The @call_graph records the wrong direction for this -- skip.
      end
      # Instead, iterate param_sources directly (already done by caller)
      types
    end

    # ---------- A3 helpers ----------

    def build_unique_method_names(evidence)
      counts = Hash.new(0)
      evidence["methods"].each { |m| counts[m["source"]&.fetch("method", nil)&.to_s] += 1 }
      counts.select { |_name, count| count == 1 }.keys.to_set
    end

    # ---------- method name lookup ----------

    def method_name_for(action)
      method_by_location["#{action["path"]}:#{action["line"]}"]
    end

    def method_by_location
      @method_by_location ||= (@evidence["facts"]["existing_sigs"] || []).each_with_object({}) do |rec, h|
        h["#{rec["path"]}:#{rec["line"]}"] = rec["method"].to_s
      end
    end

    # ---------- type id assignment ----------

    def type_id(type_str)
      @type_ids[type_str] ||= @type_ids.size
    end

    # ---------- Z3 SMT2 ----------

    def sat?(constraints, actions = [])
      return true unless z3_available?
      smt2 = build_smt2(constraints, actions)
      out, _err, _status = Open3.capture3("z3 -smt2 -in", stdin_data: smt2)
      # Returns true (SAT = consistent) unless Z3 explicitly says "unsat"
      !out.strip.start_with?("unsat")
    rescue Errno::ENOENT
      true # z3 not on PATH
    rescue Errno::ETIMEDOUT, Timeout::Error
      true # z3 timed out -- assume consistent
    end

    def clean_name(str)
      str.to_s.gsub('::', '__').gsub('@', '_AT_').gsub('?', '_Q_').gsub('!', '_E_').gsub(/[^\w]/, '_')
    end

    def param_var(class_name, method_name, param_name)
      "v_p__#{clean_name(class_name)}__#{clean_name(method_name)}__#{clean_name(param_name)}"
    end

    def return_var(class_name, method_name, kind)
      "v_r__#{clean_name(class_name)}__#{clean_name(method_name)}__#{clean_name(kind)}"
    end

    def field_var(class_name, field_name)
      "v_f__#{clean_name(class_name)}__#{clean_name(field_name)}"
    end

    def ivar_var(class_name, ivar_name)
      "v_i__#{clean_name(class_name)}__#{clean_name(ivar_name)}"
    end

    def method_rec_by_location
      @method_rec_by_location ||= begin
        h = {}
        [@evidence.dig("facts", "existing_sigs"), @evidence.dig("facts", "unsigned_methods")].compact.flatten.each do |rec|
          h["#{rec["path"]}:#{rec["line"]}"] = rec
        end
        h
      end
    end

    def populate_all_types(actions = [])
      return unless @type_ids.empty?

      # Collect all type strings first
      types = Set.new
      [@evidence.dig("facts", "existing_sigs"), @evidence.dig("facts", "unsigned_methods")].compact.flatten.each do |rec|
        Array(rec["params"]).each { |p| types.add(p["type"].to_s) if p["type"] }
        if rec["sig"]
          ret = extract_return_type(rec["sig"].to_s)
          types.add(ret) if ret
        end
      end
      Array(@evidence.dig("facts", "struct_declarations")).each do |decl|
        Hash(decl["field_types"]).each_value { |t| types.add(t.to_s) }
      end
      Array(@evidence.dig("facts", "param_origins")).each { |p| types.add(p["type"].to_s) if p["type"] }
      Array(@evidence.dig("facts", "return_origins")).each do |r|
        types.add(r["candidate_type"].to_s) if r["candidate_type"]
        Array(r["sources"]).each { |src| types.add(src["type"].to_s) if src["type"] }
      end
      Array(actions).each do |action|
        proposed = action.dig("data", "type").to_s
        types.add(proposed) unless proposed.empty?
      end
      types.add("NilClass")
      types.add("T.untyped")

      # Build the inheritance graph for sorting
      graph = Hash.new { |h, k| h[k] = Set.new }
      BUILT_IN_SUBTYPES.each { |sub, sups| sups.each { |sup| graph[sub].add(sup) } }

      # Scan class declarations from source files
      unqualified_map = Hash.new { |h, k| h[k] = [] }
      types.each do |type_str|
        base = type_str.start_with?("T.nilable(") ? type_str[10..-2] : type_str
        base_name = base.split("::").last
        unqualified_map[base_name] << base if base_name
      end

      @source_files.each do |path|
        next unless File.file?(path)
        begin
          content = File.read(path)
          content.scan(/class\s+([A-Za-z0-9_:]+)\s*<\s*([A-Za-z0-9_:]+)/) do |cls, sup|
            cls_base = cls.split("::").last
            sup_base = sup.split("::").last
            cls_candidates = unqualified_map[cls_base]
            sup_candidates = unqualified_map[sup_base]
            cls_candidates.each do |c_fq|
              sup_candidates.each do |s_fq|
                c_prefix = c_fq.split("::")[0..-2]
                s_prefix = s_fq.split("::")[0..-2]
                if c_prefix == s_prefix || s_fq == "Node" || s_fq == "MIR::Node"
                  graph[c_fq].add(s_fq)
                end
              end
            end
          end
        rescue StandardError
        end
      end

      # Perform topological sort: parents (supertypes) first -> children (subtypes) after
      sorted = []
      visited = {} # type => :visiting or :visited

      visit = lambda do |u|
        next if visited[u] == :visited
        visited[u] = :visiting

        if u.start_with?("T.nilable(")
          inner = u[10..-2]
          visit.call(inner) if types.include?(inner)

          # Parents of inner type converted to nilable are parents of this nilable
          parents = graph[inner]
          parents.each do |p|
            nilable_p = "T.nilable(#{p})"
            visit.call(nilable_p) if types.include?(nilable_p)
          end
        else
          parents = graph[u]
          parents.each { |p| visit.call(p) if types.include?(p) }
        end

        visited[u] = :visited
        sorted << u
      end

      visit.call("T.untyped")
      visit.call("NilClass")
      types.each { |t| visit.call(t) }

      @type_ids = {}
      sorted.each_with_index do |type_str, idx|
        @type_ids[type_str] = idx
      end
    end

    def declare_all_variables(lines)
      @declared_vars = Set.new

      # 1. Methods (Existing / Unsigned)
      [@evidence.dig("facts", "existing_sigs"), @evidence.dig("facts", "unsigned_methods")].compact.flatten.each do |rec|
        class_name = rec["class"].to_s
        method_name = rec["method"].to_s
        kind = rec["kind"].to_s

        declare_var(lines, return_var(class_name, method_name, kind))

        Array(rec["params"]).each do |param|
          p_name = param["name"].to_s
          declare_var(lines, param_var(class_name, method_name, p_name))
        end
      end

      # 2. Struct fields
      Array(@evidence.dig("facts", "struct_declarations")).each do |decl|
        class_name = decl["class"].to_s
        Array(decl["fields"]).each do |field|
          declare_var(lines, field_var(class_name, field.to_s))
        end
      end

      # 3. Ivars
      Array(@evidence.dig("facts", "ivar_param_origins")).each do |key, _|
        class_name, ivar_name = key.split("\0", 2)
        declare_var(lines, ivar_var(class_name, ivar_name))
      end
    end

    def declare_var(lines, var_name)
      return if @declared_vars.include?(var_name)
      @declared_vars.add(var_name)
      lines << "(declare-const #{var_name} Int)"
      lines << "(assert (and (>= #{var_name} 0) (< #{var_name} #{@type_ids.size})))"
    end

    def assert_existing_types(lines)
      [@evidence.dig("facts", "existing_sigs"), @evidence.dig("facts", "unsigned_methods")].compact.flatten.each do |rec|
        class_name = rec["class"].to_s
        method_name = rec["method"].to_s
        kind = rec["kind"].to_s

        # 1. Param signature types
        Array(rec["params"]).each do |param|
          p_name = param["name"].to_s
          type_str = param["type"].to_s
          if !type_str.empty? && type_str != "T.untyped"
            t_id = type_id(type_str)
            p_var = param_var(class_name, method_name, p_name)
            lines << "(assert (= #{p_var} #{t_id}))" if @declared_vars.include?(p_var)
          end
        end

        # 2. Return signature type
        if rec["sig"]
          ret = extract_return_type(rec["sig"].to_s)
          if ret && !ret.empty? && ret != "T.untyped" && ret != "void"
            t_id = type_id(ret)
            ret_var = return_var(class_name, method_name, kind)
            lines << "(assert (= #{ret_var} #{t_id}))" if @declared_vars.include?(ret_var)
          end
        end
      end

      # 3. Struct field static/RBI types
      Array(@evidence.dig("facts", "struct_declarations")).each do |decl|
        class_name = decl["class"].to_s
        Hash(decl["field_types"]).each do |field, type|
          type_str = type.to_s
          if !type_str.empty? && type_str != "T.untyped"
            t_id = type_id(type_str)
            f_var = field_var(class_name, field.to_s)
            lines << "(assert (= #{f_var} #{t_id}))" if @declared_vars.include?(f_var)
          end
        end
      end
    end

    def build_method_param_variable_map
      @method_param_vars = Hash.new { |h, k| h[k] = [] }

      [@evidence.dig("facts", "existing_sigs"), @evidence.dig("facts", "unsigned_methods")].compact.flatten.each do |rec|
        class_name = rec["class"].to_s
        method_name = rec["method"].to_s

        Array(rec["params"]).each_with_index do |param, idx|
          p_name = param["name"].to_s
          p_var = param_var(class_name, method_name, p_name)
          next unless @declared_vars.include?(p_var)

          # Index by keyword (name)
          @method_param_vars[[method_name, p_name]] << p_var
          # Index by positional (index as string)
          @method_param_vars[[method_name, idx.to_s]] << p_var
        end
      end
    end

    def assert_data_flow_constraints(lines)
      build_method_param_variable_map

      # 1. Ivar assignments from params
      Array(@evidence.dig("facts", "ivar_param_origins")).each do |key, params|
        class_name, ivar_name = key.split("\0", 2)
        ivar_var_name = ivar_var(class_name, ivar_name)
        next unless @declared_vars.include?(ivar_var_name)

        Array(params).each do |p_name|
          p_var = param_var(class_name, "initialize", p_name.to_s)
          if @declared_vars.include?(p_var)
            lines << "(assert (is-sub #{p_var} #{ivar_var_name}))"
          end
        end
      end

      # 2. Return origins
      Array(@evidence.dig("facts", "return_origins")).each do |r|
        class_name = r["class"].to_s
        method_name = r["method"].to_s
        kind = r["kind"].to_s
        ret_var = return_var(class_name, method_name, kind)
        next unless @declared_vars.include?(ret_var)

        Array(r["sources"]).each do |src|
          code = src["code"].to_s
          type = src["type"].to_s

          if code.start_with?("@")
            ivar_var_name = ivar_var(class_name, code)
            if @declared_vars.include?(ivar_var_name)
              lines << "(assert (is-sub #{ivar_var_name} #{ret_var}))"
            end
          elsif !type.empty? && type != "T.untyped"
            t_id = type_id(type)
            lines << "(assert (is-sub #{t_id} #{ret_var}))"
          end
        end
      end

      # 3. Param origins (calls)
      Array(@evidence.dig("facts", "param_origins")).each do |p|
        callee = p["callee"].to_s
        slot = p["slot"].to_s
        enclosing_scope = p["enclosing_scope"].to_s
        source_method = p["source_method"].to_s
        code = p["code"].to_s
        type = p["type"].to_s

        candidates = @method_param_vars[[callee, slot]]
        next if candidates.empty?

        candidates.each do |p_var|
          if code.start_with?("@")
            ivar_var_name = ivar_var(enclosing_scope, code)
            if @declared_vars.include?(ivar_var_name)
              lines << "(assert (is-sub #{ivar_var_name} #{p_var}))"
            end
          elsif !type.empty? && type != "T.untyped"
            t_id = type_id(type)
            lines << "(assert (is-sub #{t_id} #{p_var}))"
          elsif !code.empty? && code =~ /\A[a-z_][a-z0-9_]*\z/
            caller_p_var = param_var(enclosing_scope, source_method, code)
            if @declared_vars.include?(caller_p_var)
              lines << "(assert (is-sub #{caller_p_var} #{p_var}))"
            end
          end
        end
      end
    end

    def build_subtype_cases
      subtype_cases = ["(= a b)"]

      # 1. Build the inheritance graph from source files
      graph = Hash.new { |h, k| h[k] = Set.new }

      # Pre-populate with built-in subtypes
      BUILT_IN_SUBTYPES.each do |sub, sups|
        sups.each { |sup| graph[sub].add(sup) }
      end

      # Unqualified name map for type_ids: "Node" => ["AST::Node", "MIR::Node"]
      unqualified_map = Hash.new { |h, k| h[k] = [] }
      @type_ids.each_key do |type_str|
        base = type_str.start_with?("T.nilable(") ? type_str[10..-2] : type_str
        base_name = base.split("::").last
        unqualified_map[base_name] << base if base_name
      end

      # Scan source files for class declarations
      @source_files.each do |path|
        next unless File.file?(path)
        begin
          content = File.read(path)
          content.scan(/class\s+([A-Za-z0-9_:]+)\s*<\s*([A-Za-z0-9_:]+)/) do |cls, sup|
            cls_base = cls.split("::").last
            sup_base = sup.split("::").last

            cls_candidates = unqualified_map[cls_base]
            sup_candidates = unqualified_map[sup_base]

            cls_candidates.each do |c_fq|
              sup_candidates.each do |s_fq|
                c_prefix = c_fq.split("::")[0..-2]
                s_prefix = s_fq.split("::")[0..-2]
                if c_prefix == s_prefix || s_fq == "Node" || s_fq == "MIR::Node"
                  graph[c_fq].add(s_fq)
                end
              end
            end
          end
        rescue StandardError
          # Safe fallback if file read fails
        end
      end

      # 2. Compute transitive closure of base types
      transitive = Set.new
      @type_ids.each_key do |type_str|
        base_type = type_str.start_with?("T.nilable(") ? type_str[10..-2] : type_str

        visited = Set.new
        queue = [base_type]
        while (current = queue.shift)
          next if visited.include?(current)
          visited.add(current)

          if current != base_type
            transitive.add([base_type, current])
          end

          parents = graph[current]
          queue.concat(parents.to_a) if parents
        end
      end

      # 3. Add transitive relations to subtyping cases
      transitive.each do |sub, sup|
        sub_id = @type_ids[sub]
        sup_id = @type_ids[sup]
        subtype_cases << "(and (= a #{sub_id}) (= b #{sup_id}))" if sub_id && sup_id
      end

      # 4. Generate nilable variants for all type combinations
      @type_ids.each do |type_str, id|
        if type_str.start_with?("T.nilable(")
          inner = type_str[10..-2]
          inner_id = @type_ids[inner]
          nil_id   = @type_ids["NilClass"]

          # Direct nilable rules
          subtype_cases << "(and (= a #{inner_id}) (= b #{id}))" if inner_id
          subtype_cases << "(and (= a #{nil_id}) (= b #{id}))" if nil_id

          # Transitive nilable rules:
          # If X < Y, then:
          # - X < T.nilable(Y)
          # - T.nilable(X) < T.nilable(Y)
          transitive.each do |sub, sup|
            if sup == inner # Y is the inner type of this nilable
              sub_id = @type_ids[sub]
              subtype_cases << "(and (= a #{sub_id}) (= b #{id}))" if sub_id

              nilable_sub = "T.nilable(#{sub})"
              nilable_sub_id = @type_ids[nilable_sub]
              subtype_cases << "(and (= a #{nilable_sub_id}) (= b #{id}))" if nilable_sub_id
            end
          end
        end
      end

      subtype_cases.uniq
    end

    def build_smt2(constraints, actions = [])
      lines = []
      lines << "(set-logic QF_LIA)"

      populate_all_types(actions)

      subtype_cases = build_subtype_cases

      lines << "; subtype predicate over type integer IDs"
      lines << "(define-fun is-sub ((a Int) (b Int)) Bool"
      lines << "  (or #{subtype_cases.join(" ")}))"

      declare_all_variables(lines)
      assert_existing_types(lines)
      assert_data_flow_constraints(lines)

      # 1. Assert proposed changes from actions as constraints
      actions.each do |action|
        proposed = action.dig("data", "type").to_s
        next unless proposed && proposed != "T.untyped"

        rec = method_rec_by_location["#{action["path"]}:#{action["line"]}"]
        next unless rec

        class_name = rec["class"].to_s
        method_name = rec["method"].to_s
        kind = rec["kind"].to_s

        case action["kind"]
        when "fix_sig_return"
          ret_var = return_var(class_name, method_name, kind)
          if @declared_vars.include?(ret_var)
            t_id = type_id(proposed)
            lines << "(assert (= #{ret_var} #{t_id}))"
          end
        when "fix_sig_param", "narrow_generic_param"
          p_name = action.dig("data", "name").to_s
          p_var = param_var(class_name, method_name, p_name)
          if @declared_vars.include?(p_var)
            t_id = type_id(proposed)
            lines << "(assert (= #{p_var} #{t_id}))"
          end
        end
      end

      # 2. Original constraints
      constraints.each do |proposed_id, param_id|
        # Assertion: proposed_return IS a subtype of param_type.
        # If it is NOT, Z3 returns UNSAT.
        lines << "(assert (is-sub #{proposed_id} #{param_id}))"
      end

      lines << "(check-sat)"
      lines.join("\n") + "\n"
    end

    def solve_types(actions = [])
      return {} unless z3_available?

      smt2 = build_smt2([], actions)

      # Append optimization objectives for all declared variables
      optimize_lines = []
      @declared_vars.each do |var|
        optimize_lines << "(maximize #{var})"
      end
      optimize_lines << "(check-sat)"
      optimize_lines << "(get-model)"

      # Replace original check-sat with the optimization queries
      smt2_opt = smt2.sub("(check-sat)\n", optimize_lines.join("\n") + "\n")

      out, _err, _status = Open3.capture3("z3 -smt2 -in", stdin_data: smt2_opt)
      return {} if out.strip.start_with?("unsat")

      solved = {}
      id_to_type = @type_ids.invert

      out.scan(/\(define-fun\s+(\w+)\s+\(\)\s+Int\s+(\d+)\)/) do |var_name, val_str|
        val = val_str.to_i
        type_str = id_to_type[val]
        solved[var_name] = type_str if type_str
      end

      solved
    end

    # ---------- z3 availability ----------

    def z3_available?
      return @z3_available if defined?(@z3_available)
      @z3_available = system("which z3 > /dev/null 2>&1")
    end
  end
end
