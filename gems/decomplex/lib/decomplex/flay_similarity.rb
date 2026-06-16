# frozen_string_literal: true

require "set"
require_relative "syntax"

module Decomplex
  # Tree-sitter structural similarity scanner for Type-2 / Type-3 clone pressure.
  #
  # The public class name is retained for report compatibility. The detector no
  # longer shells through the flay gem: it builds language-neutral structural
  # fingerprints from Tree-sitter node kinds, normalizing identifiers/literals
  # so renamed-but-isomorphic code groups as Type-2. Type-3 uses a small fuzzy
  # signature over child statements, matching functions/subtrees with a missing
  # or inserted child within the configured fuzzy budget.
  class FlaySimilarity
    DEFAULT_MASS = 32
    DEFAULT_FUZZY = 1
    MAX_FUZZY_CHILDREN = 14

    MethodSpan = Struct.new(:name, :first_line, :last_line, keyword_init: true)
    Candidate = Struct.new(:file, :line, :span, :method_name, :node_name, :mass,
                           :fingerprint, :raw, :child_fingerprints,
                           :child_masses, keyword_init: true)

    IDENTIFIER_KINDS = %w[
      identifier constant type_identifier field_identifier property_identifier
      shorthand_property_identifier_pattern variable_name
    ].freeze
    LITERAL_KINDS = %w[
      string string_content string_literal interpreted_string_literal raw_string_literal
      integer float int number rational imaginary character char_literal
      symbol simple_symbol true false nil none null
    ].freeze
    SKIP_CANDIDATE_KINDS = %w[
      comment identifier constant type_identifier field_identifier property_identifier
      parameters formal_parameters parameter_list argument_list arguments
      block_parameters method_parameters
      scope_resolution
    ].freeze
    CLONE_CANDIDATE_KINDS = %w[
      array assignment assignment_statement block case case_clause class
      class_definition class_declaration do_block enum_declaration for
      for_statement hash if if_statement match_expression match_statement
      method method_definition module operator_assignment singleton_method
      struct_declaration switch_case switch_expression switch_statement
      unless until while while_statement
    ].freeze
    BODY_KINDS = %w[
      body block body_statement declaration_list statement_block compound_statement
      suite do_block
    ].freeze
    CALL_KINDS = %w[call call_expression method_invocation invocation_expression].freeze

    def self.scan(files, mass: DEFAULT_MASS, fuzzy: DEFAULT_FUZZY)
      new(files, mass: mass, fuzzy: fuzzy).scan
    end

    def initialize(files, mass:, fuzzy:)
      @files = files
      @mass = mass
      @fuzzy = fuzzy
      @method_spans = {}
    end

    def scan
      candidates = @files.flat_map { |file| candidates_for_file(file) }
      findings = (type2_findings(candidates) + type3_findings(candidates)).sort_by do |finding|
        [finding[:clone_type] == :type2 ? 0 : 1, -finding[:mass].to_i, finding[:node].to_s, finding[:at].to_s]
      end
      prune_nested_findings(findings)
    rescue LoadError, StandardError
      []
    end

    private

    def candidates_for_file(file)
      return [] unless Syntax.supported_source?(file, parser: "tree_sitter")

      doc = Syntax.parse(file, parser: "tree_sitter")
      @method_spans[file] = collect_method_spans(doc)
      out = []
      seen = Set.new

      doc.function_defs.each do |fn|
        candidate = candidate_for(file, fn.body, node_name: "defn")
        add_candidate(out, seen, candidate) if candidate
      end

      walk(doc.root) do |node|
        next unless candidate_node?(node)

        add_candidate(out, seen, candidate_for(file, node))
      end

      out
    rescue StandardError
      []
    end

    def add_candidate(out, seen, candidate)
      return unless candidate
      return if candidate.mass < effective_mass_floor
      return if typed_struct_schema_text?(candidate.raw)

      key = [candidate.file, candidate.line, candidate.span, candidate.node_name, candidate.fingerprint]
      return if seen.include?(key)

      seen << key
      out << candidate
    end

    def candidate_for(file, node, node_name: nil)
      fp, mass = fingerprint(node)
      return nil if fp.to_s.empty?

      line = line(node)
      method = method_span_for(file, line)
      children = fuzzy_children_for(node)
      child_data = children.map { |child| fingerprint(child) }.reject { |child_fp, child_mass| child_fp.to_s.empty? || child_mass.zero? }

      Candidate.new(
        file: file,
        line: line,
        span: span(node),
        method_name: method.name,
        node_name: node_name || flay_node_name(node),
        mass: mass,
        fingerprint: fp,
        raw: normalize_text(node.text),
        child_fingerprints: child_data.map(&:first),
        child_masses: child_data.map(&:last)
      )
    end

    def type2_findings(candidates)
      candidates.group_by(&:fingerprint).values.filter_map do |cluster|
        cluster = uniq_sites(cluster)
        next if cluster.size < 2
        next if cluster.map(&:raw).uniq.size < 2
        next if typed_struct_schema_cluster?(cluster)

        finding_for(cluster, clone_type: :type2, mass: cluster.map(&:mass).min)
      end
    end

    def type3_findings(candidates)
      return [] if @fuzzy <= 0

      groups = Hash.new { |hash, key| hash[key] = [] }
      candidates.each do |candidate|
        fuzzy_signatures(candidate).each do |signature, signature_mass|
          next if signature_mass < effective_mass_floor

          groups[signature] << [candidate, signature_mass]
        end
      end

      seen = Set.new
      groups.values.filter_map do |rows|
        cluster = uniq_sites(rows.map(&:first))
        next if cluster.size < 2
        next if cluster.map(&:fingerprint).uniq.size < 2
        next if typed_struct_schema_cluster?(cluster)

        key = cluster.map { |candidate| [candidate.file, candidate.line, candidate.node_name] }.sort
        next if seen.include?(key)

        seen << key
        finding_for(cluster, clone_type: :type3, mass: rows.map(&:last).max)
      end
    end

    def finding_for(cluster, clone_type:, mass:)
      sites = cluster.map { |candidate| site_for(candidate) }.sort
      {
        at: sites.first,
        sites: sites,
        spans: spans_for(cluster),
        clone_type: clone_type,
        node: cluster.map(&:node_name).tally.max_by { |_node, count| count }.first.to_s,
        mass: mass,
        locations: cluster.map { |candidate| "#{candidate.file}:#{candidate.line}" }.sort
      }
    end

    def prune_nested_findings(findings)
      kept = []
      findings.each do |finding|
        next if kept.any? { |larger| nested_finding?(finding, larger) }

        kept << finding
      end
      kept
    end

    def nested_finding?(inner, outer)
      return false if inner.equal?(outer)
      return false if outer[:mass].to_i <= inner[:mass].to_i

      inner.fetch(:spans).all? do |site, span|
        file = site_file(site)
        outer.fetch(:spans).any? do |outer_site, outer_span|
          site_file(outer_site) == file && contains_span?(outer_span, span)
        end
      end
    end

    def contains_span?(outer, inner)
      outer_start = [outer[0].to_i, outer[1].to_i]
      outer_end = [outer[2].to_i, outer[3].to_i]
      inner_start = [inner[0].to_i, inner[1].to_i]
      inner_end = [inner[2].to_i, inner[3].to_i]
      (outer_start <=> inner_start) <= 0 && (outer_end <=> inner_end) >= 0
    end

    def site_file(site)
      parts = site.to_s.split(":")
      parts[0...-2].join(":")
    end

    def spans_for(cluster)
      cluster.each_with_object({}) do |candidate, out|
        out[site_for(candidate)] =
          if candidate.node_name == "defn"
            method = method_span_for(candidate.file, candidate.line)
            [method.first_line, 0, method.last_line, 1]
          else
            candidate.span
          end
      end
    end

    def site_for(candidate)
      "#{candidate.file}:#{candidate.method_name}:#{candidate.line}"
    end

    def uniq_sites(candidates)
      candidates.uniq { |candidate| [candidate.file, candidate.line, candidate.node_name] }
    end

    def fuzzy_signatures(candidate)
      children = candidate.child_fingerprints
      return [] if children.size < 2 || children.size > MAX_FUZZY_CHILDREN

      masses = candidate.child_masses
      max_delete = [@fuzzy, children.size - 1].min
      signatures = []
      (0..max_delete).each do |delete_count|
        (0...children.size).to_a.combination(delete_count) do |deleted|
          deleted_set = deleted.to_set
          kept = []
          mass = 0
          children.each_with_index do |fp, index|
            next if deleted_set.include?(index)

            kept << fp
            mass += masses[index].to_i
          end
          signatures << ["#{candidate.node_name}(#{kept.join('|')})", mass]
        end
      end
      signatures
    end

    def candidate_node?(node)
      return false unless ts_node?(node)
      return false unless node.named?
      return false if SKIP_CANDIDATE_KINDS.include?(node.kind)
      return false unless CLONE_CANDIDATE_KINDS.include?(node.kind)
      return false if typed_struct_schema_text?(node.text)

      node.named_child_count.positive?
    end

    def effective_mass_floor
      @effective_mass_floor ||= [@mass, (@mass * 23.0 / 8.0).ceil].max
    end

    def fuzzy_children_for(node)
      body = body_node(node)
      source = body || node
      children = source.named_children
      children = node.named_children if children.empty?
      children.reject { |child| SKIP_CANDIDATE_KINDS.include?(child.kind) || typed_struct_schema_text?(child.text) }
    end

    def body_node(node)
      named_field(node, "body") ||
        node.named_children.find { |child| BODY_KINDS.include?(child.kind) }
    end

	    def fingerprint(node, active = nil)
	      return ["", 0] unless ts_node?(node)
	      active ||= Set.new
	      key = node_key(node)
	      return ["", 0] if active.include?(key)

	      active << key
	      begin
	      return ["", 0] if node.kind == "comment"
	      return fingerprint_call(node, active) if CALL_KINDS.include?(node.kind) && call_message(node)

	      if node.child_count.zero?
	        token = terminal_token(node)
	        return ["", 0] if token.empty?

        return [token, 1]
      end

	      child_parts = []
	      mass = 1
	      node.children.each do |child|
	        child_fp, child_mass = fingerprint(child, active)
	        next if child_fp.empty?

	        child_parts << child_fp
	        mass += child_mass
      end

	      return [terminal_token(node), 1] if child_parts.empty?

	      ["#{node.kind}(#{child_parts.join(' ')})", mass]
	      ensure
	        active.delete(key)
	      end
	    end

	    def fingerprint_call(node, active)
	      message = call_message(node)
	      child_parts = []
	      mass = 1
	      node.children.each do |child|
	        child_fp, child_mass = fingerprint(child, active)
	        next if child_fp.empty?

        child_parts << child_fp
        mass += child_mass
      end
      ["#{node.kind}<#{message}>(#{child_parts.join(' ')})", mass]
    end

    def call_message(node)
      return nil unless node.children.any? { |child| %w[argument_list arguments].include?(child.kind) }

      callee = named_field(node, "function") || named_field(node, "callee")
      return callee_message(callee) if callee

      argument_node = node.children.find { |child| %w[argument_list arguments].include?(child.kind) }
      named_before_args = node.named_children.select do |child|
        argument_node.nil? || child.start_byte < argument_node.start_byte
      end
      callee_message(named_before_args.last)
    end

    def callee_message(node)
      return nil unless ts_node?(node)
      return node.text if IDENTIFIER_KINDS.include?(node.kind)

      leaf = node.named_children.reverse.find { |child| IDENTIFIER_KINDS.include?(child.kind) }
      leaf&.text
    end

    def terminal_token(node)
      kind = node.kind.to_s
      return "id" if IDENTIFIER_KINDS.include?(kind)
      return literal_token(kind) if LITERAL_KINDS.include?(kind)

      text = normalize_text(node.text)
      return "" if text.empty?
      return "id" if text.match?(/\A[A-Za-z_]\w*[!?=]?\z/)
      return "lit" if text.match?(/\A(?::[A-Za-z_]\w*|[-+]?\d+(?:\.\d+)?|".*"|'.*')\z/)

      "#{kind}:#{text}"
    end

    def literal_token(kind)
      case kind
      when "true", "false" then "bool"
      when "nil", "none", "null" then "nil"
      else "lit"
      end
    end

    def flay_node_name(node)
      return "defn" if %w[method function_definition function_declaration method_definition function_item].include?(node.kind)
      return "defs" if node.kind == "singleton_method"

      node.kind
    end

    def typed_struct_schema_cluster?(cluster)
      cluster.all? { |candidate| typed_struct_schema_line?(candidate.file, candidate.line) || typed_struct_schema_text?(candidate.raw) }
    end

    def typed_struct_schema_line?(file, line_no)
      source_line(file, line_no).match?(/\A\s*(?:const|prop)\s+:[A-Za-z_]\w*\b/)
    end

    def typed_struct_schema_text?(text)
      text.to_s.match?(/<\s*T::Struct\b/) ||
        text.to_s.lines.all? { |line| line.strip.empty? || line.match?(/\A\s*(?:const|prop)\s+:[A-Za-z_]\w*\b/) }
    end

    def source_line(file, line_no)
      (@source_lines ||= {})
      (@source_lines[file] ||= File.readlines(file))[line_no - 1].to_s
    rescue StandardError
      ""
    end

    def collect_method_spans(document)
      document.function_defs.map do |fn|
        MethodSpan.new(name: fn.name.to_s, first_line: fn.span[0], last_line: fn.span[2])
      end.sort_by { |span| [span.first_line, -span.last_line] }
    rescue StandardError
      []
    end

    def method_span_for(file, line_no)
      spans = @method_spans[file] || []
      spans.find { |span| span.first_line <= line_no && line_no <= span.last_line } ||
        MethodSpan.new(name: "(top-level)", first_line: line_no, last_line: line_no)
    end

	    def walk(node, &block)
	      return unless ts_node?(node)

	      pending = [node]
	      seen = Set.new
	      until pending.empty?
	        current = pending.pop
	        next unless ts_node?(current)
	        key = node_key(current)
	        next if seen.include?(key)

	        seen << key
	        yield current
	        current.children.reverse_each { |child| pending << child }
	      end
	    end

    def named_field(node, name)
      node.child_by_field_name(name)
    rescue StandardError
      nil
    end

	    def ts_node?(node)
	      node && node.respond_to?(:kind) && node.respond_to?(:children)
	    end

	    def node_key(node)
	      [node.kind, node.start_byte, node.end_byte]
	    rescue StandardError
	      node.object_id
	    end

    def span(node)
      [node.start_point.row + 1, node.start_point.column,
       node.end_point.row + 1, node.end_point.column]
    end

    def line(node)
      node.start_point.row + 1
    end

    def normalize_text(text)
      text.to_s.strip.gsub(/\s+/, " ")
    end
  end
end
