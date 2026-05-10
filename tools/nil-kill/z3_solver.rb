# typed: false
# frozen_string_literal: true

# Z3-based type consistency checker for nil-kill batch actions.
#
# Builds a lightweight call graph from Prism AST and encodes Sorbet's type
# subtype relation in SMT2. For each fix_sig_return action, checks whether the
# proposed return type is compatible with every receiving param whose declared
# type is already non-untyped. If Z3 returns UNSAT, the batch is definitely
# inconsistent -- skip the spec run and bisect immediately.
#
# False negatives (missing a real conflict) are fine -- we fall back to specs.
# False positives (claiming UNSAT when actually SAT) cause unnecessary bisect
# steps, so we err on the conservative side: skip the check when method names
# are ambiguous or Z3 times out.

require 'open3'
require 'prism'

module NilKill
  class Z3Solver
    # Sorbet subtype axioms for primitive types only.
    BUILT_IN_SUBTYPES = {
      "TrueClass"  => ["T::Boolean"],
      "FalseClass" => ["T::Boolean"],
      "Integer"    => ["Numeric"],
      "Float"      => ["Numeric"],
    }.freeze

    Z3_TIMEOUT = 5 # seconds

    def initialize(evidence, source_files)
      @evidence = evidence
      @source_files = Array(source_files)
      @type_ids = {}   # type_string => integer id
      @sig_index = nil # lazy
      @call_graph = nil # lazy
    end

    # Returns true if Z3 says the batch is SAT (may be ok), false if UNSAT
    # (definitely inconsistent -- bisect without running specs).
    def consistent?(actions)
      return true unless z3_available?

      constraints = collect_constraints(actions)
      return true if constraints.empty?

      sat?(constraints)
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

    # ---------- call graph ----------

    def call_graph
      @call_graph ||= build_call_graph
    end

    # Builds: callee_method_name => [{receiver_method, arg_kind, arg_position|arg_name}]
    # Records call sites where a method's return is passed directly as an arg
    # to another method call.
    def build_call_graph
      graph = Hash.new { |h, k| h[k] = [] }
      @source_files.each do |path|
        parsed = Prism.parse_file(path)
        next unless parsed.success?
        walk_node(parsed.value, nil, graph)
      rescue StandardError
        next
      end
      graph
    end

    def walk_node(node, enclosing, graph)
      return unless node

      if node.is_a?(Prism::DefNode)
        enclosing = node.name.to_s
      end

      if node.is_a?(Prism::CallNode) && enclosing
        record_call_edges(node, enclosing, graph)
      end

      return unless node.respond_to?(:child_nodes)
      node.child_nodes.compact.each { |c| walk_node(c, enclosing, graph) }
    end

    def record_call_edges(call_node, enclosing, graph)
      receiver_method = call_node.name.to_s
      args = call_node.arguments&.arguments || []

      args.each_with_index do |arg, pos|
        if arg.is_a?(Prism::KeywordHashNode)
          arg.elements.each do |assoc|
            next unless assoc.is_a?(Prism::AssocNode)
            next unless assoc.value.is_a?(Prism::CallNode) && !assoc.value.safe_navigation?
            key = assoc.key.is_a?(Prism::SymbolNode) ? assoc.key.value.to_s : nil
            next unless key
            graph[assoc.value.name.to_s] << {
              receiver_method: receiver_method,
              arg_kind: :keyword,
              arg_name: key,
            }
          end
        elsif arg.is_a?(Prism::CallNode) && !arg.safe_navigation?
          graph[arg.name.to_s] << {
            receiver_method: receiver_method,
            arg_kind: :positional,
            arg_position: pos,
          }
        end
      end
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
