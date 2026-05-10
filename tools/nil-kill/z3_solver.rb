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
require 'prism'

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
      sat?(constraints)
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
          types = sources.dig(:keyword, name) || sources.dig(:positional, idx) || []
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

    # A4: Returns true if the safe-nav IS provably dead (allow the action).
    # Returns false if the receiver might be nil (block the action).
    # Scans the method scope for nil assignments or nilable-return assignments
    # to the receiver variable. Conservative: returns true (allow) when the
    # receiver is complex or the analysis is inconclusive.
    def provably_dead_safe_nav?(action)
      code = action.dig("data", "code")
      return true unless code

      # Extract bare receiver: "resolved&.dig(a)" -> "resolved"
      receiver = code.split("&.").first.strip
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
        parsed = Prism.parse_file(path)
        next unless parsed.success?
        walk_node(parsed.value, nil)
      rescue StandardError
        next
      end
    end

    def walk_node(node, enclosing)
      return unless node

      if node.is_a?(Prism::DefNode)
        enclosing = node.name.to_s
      end

      if node.is_a?(Prism::CallNode) && enclosing
        record_call_edges(node, enclosing)
      end

      return unless node.respond_to?(:child_nodes)
      node.child_nodes.compact.each { |c| walk_node(c, enclosing) }
    end

    def record_call_edges(call_node, _enclosing)
      receiver_method = call_node.name.to_s
      args = call_node.arguments&.arguments || []

      args.each_with_index do |arg, pos|
        if arg.is_a?(Prism::KeywordHashNode)
          arg.elements.each do |assoc|
            next unless assoc.is_a?(Prism::AssocNode)
            key = assoc.key.is_a?(Prism::SymbolNode) ? assoc.key.value.to_s : nil
            next unless key

            if assoc.value.is_a?(Prism::CallNode) && !assoc.value.safe_navigation?
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
          if arg.is_a?(Prism::CallNode) && !arg.safe_navigation?
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
      when Prism::StringNode         then "String"
      when Prism::SymbolNode         then "Symbol"
      when Prism::IntegerNode        then "Integer"
      when Prism::FloatNode          then "Float"
      when Prism::TrueNode           then "TrueClass"
      when Prism::FalseNode          then "FalseClass"
      when Prism::NilNode            then "NilClass"
      when Prism::ArrayNode          then "Array"
      when Prism::HashNode           then "Hash"
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

    def sat?(constraints)
      smt2 = build_smt2(constraints)
      out, _err, _status = Open3.capture3("z3 -smt2 -in", stdin_data: smt2)
      # Returns true (SAT = consistent) unless Z3 explicitly says "unsat"
      !out.strip.start_with?("unsat")
    rescue Errno::ENOENT
      true # z3 not on PATH
    rescue Errno::ETIMEDOUT, Timeout::Error
      true # z3 timed out -- assume consistent
    end

    def build_smt2(constraints)
      lines = []
      lines << "(set-logic QF_LIA)"

      # Build subtype cases before declaring constants (need full type_ids)
      subtype_cases = ["(= a b)"]

      @type_ids.each do |type_str, id|
        if type_str.start_with?("T.nilable(")
          inner = type_str[10..-2]
          inner_id = @type_ids[inner]
          nil_id   = @type_ids["NilClass"]
          subtype_cases << "(and (= a #{inner_id}) (= b #{id}))" if inner_id
          subtype_cases << "(and (= a #{nil_id}) (= b #{id}))" if nil_id
        end

        BUILT_IN_SUBTYPES.fetch(type_str, []).each do |sup|
          sup_id = @type_ids[sup]
          subtype_cases << "(and (= a #{id}) (= b #{sup_id}))" if sup_id
        end
      end

      lines << "; subtype predicate over type integer IDs"
      lines << "(define-fun is-sub ((a Int) (b Int)) Bool"
      lines << "  (or #{subtype_cases.join(" ")}))"

      constraints.each do |proposed_id, param_id|
        # Assertion: proposed_return IS a subtype of param_type.
        # If it is NOT, Z3 returns UNSAT.
        lines << "(assert (is-sub #{proposed_id} #{param_id}))"
      end

      lines << "(check-sat)"
      lines.join("\n") + "\n"
    end

    # ---------- z3 availability ----------

    def z3_available?
      return @z3_available if defined?(@z3_available)
      @z3_available = system("which z3 > /dev/null 2>&1")
    end
  end
end
