# frozen_string_literal: true

module Espalier
  # Language-neutral algebra for polynomial size domains emitted by FactMine.
  # Domain ids are semantic; N/M/K are assigned only when rendering.
  module SymbolicComplexity
    module_function

    LETTERS = %w[N M K L P Q R S T U V W X Y Z].freeze
    RENDER_DOMAIN_LIMIT = 128

    def reset_intern_pool!
      @term_pool = {}
      @domain_pool = {}
      @expression_pool = {}
    end

    def from_fact(term, domains)
      return nil unless term.is_a?(Hash)

      factors = Array(term["factors"] || term[:factors]).each_with_object({}) do |factor, out|
        id = factor["domain_id"] || factor[:domain_id]
        exponent = (factor["exponent"] || factor[:exponent]).to_i
        out[id.to_s] = exponent if id && exponent.positive?
      end
      logarithmic = term["logarithmic"] || term[:logarithmic]
      logarithmic_domain = term["logarithmic_domain_id"] || term[:logarithmic_domain_id]
      logarithmic_domain ||= factors.keys.first if logarithmic && factors.length == 1
      normalize(
        terms: [{ factors: factors, logs: logarithmic_domain ? { logarithmic_domain => 1 } : {} }],
        domains: domain_index(domains),
        complete: term.key?("complete") ? term["complete"] : term.fetch(:complete, true)
      )
    end

    def constant
      normalize(terms: [{ factors: {}, logs: {} }], domains: {}, complete: true)
    end

    # A compiler-proven callback/reflection boundary has a precise parametric
    # cost even when the caller-supplied body is not available. Keep that cost
    # as an algebraic atom so loops and interprocedural propagation can compose
    # O(C), O(N*C), and similar bounds without inventing a scalar polynomial.
    def parameterized_cost(id:, name:, source_kind:, multiplicity_domain: nil, domains: [])
      factors = { id.to_s => 1 }
      factors[multiplicity_domain.to_s] = 1 if multiplicity_domain
      parameter = {
        "id" => id.to_s,
        "name" => name.to_s,
        "source_kind" => source_kind.to_s
      }
      normalize(
        terms: [{ factors: factors, logs: {} }],
        domains: domain_index(Array(domains) + [parameter]),
        complete: true
      )
    end

    def relative_call(complexity, receiver_domains:, argument_domains:, domains:)
      text = complexity.to_s.delete(" ")
      return constant if text == "O(1)"

      receiver = Array(receiver_domains).first
      argument = Array(argument_domains).find { |values| !Array(values).empty? }
      argument = Array(argument).first
      factors = case text
                when "O(logN)"
                  receiver ? {} : nil
                when "O(N)", "O(NlogN)"
                  receiver ? { receiver => 1 } : nil
                when "O(N*M)"
                  receiver && argument ? { receiver => 1, argument => 1 } : nil
                when /\AO\(N\^(\d+)\)\z/
                  receiver ? { receiver => Regexp.last_match(1).to_i } : nil
                end
      return nil unless factors

      normalize(
        terms: [{ factors: factors, logs: text.include?("logN") ? { receiver => 1 } : {} }],
        domains: domain_index(domains),
        complete: true
      )
    end

    def sum(*expressions)
      rows = expressions.flatten.compact
      return nil if rows.empty?

      normalize(
        terms: rows.flat_map { |expression| Array(expression[:terms]) },
        domains: rows.each_with_object({}) { |expression, out| out.merge!(expression[:domains] || {}) },
        complete: rows.all? { |expression| expression.fetch(:complete, true) }
      )
    end

    def multiply(left, right)
      return right unless left
      return left unless right

      terms = Array(left[:terms]).product(Array(right[:terms])).map do |a, b|
        factors = a[:factors].dup
        b[:factors].each { |id, exponent| factors[id] = factors.fetch(id, 0) + exponent }
        logs = a[:logs].dup
        b[:logs].each { |id, exponent| logs[id] = logs.fetch(id, 0) + exponent }
        { factors: factors, logs: logs }
      end
      normalize(
        terms: terms,
        domains: (left[:domains] || {}).merge(right[:domains] || {}),
        complete: left.fetch(:complete, true) && right.fetch(:complete, true)
      )
    end

    # Replace only domain metadata on an already-normalized expression. Terms
    # are immutable and interned, so rerunning pairwise dominance elimination
    # here is both redundant and quadratic in the number of monomials.
    def with_domains(expression, domains)
      return nil unless expression

      canonical_domains = intern_domains(domains || {})
      canonical = expression.merge(domains: canonical_domains).freeze
      @expression_pool ||= {}
      key = [
        canonical.fetch(:terms),
        canonical_domains,
        canonical.fetch(:complete, true)
      ]
      @expression_pool[key] ||= canonical
    end

    def substitute(expression, mapping, caller_domains: {})
      return nil unless expression

      terms = Array(expression[:terms]).map do |term|
        factors = {}
        term[:factors].each do |id, exponent|
          replacements = Array(mapping[id])
          replacements = [id] if replacements.empty?
          replacements.each do |replacement|
            factors[replacement] = factors.fetch(replacement, 0) + exponent
          end
        end
        logs = {}
        term[:logs].each do |id, exponent|
          replacements = Array(mapping[id])
          replacements = [id] if replacements.empty?
          replacements.each do |replacement|
            logs[replacement] = logs.fetch(replacement, 0) + exponent
          end
        end
        { factors: factors, logs: logs }
      end
      normalize(
        terms: terms,
        domains: (expression[:domains] || {}).merge(caller_domains),
        complete: expression.fetch(:complete, true)
      )
    end

    # Drop the given domain ids from an expression, treating them as constant.
    # Resolves a callback C to an O(1) callable: O(N*C) -> O(N).
    def without_domains(expression, ids)
      return expression if expression.nil? || Array(ids).empty?

      drop = Array(ids).map(&:to_s)
      terms = Array(expression[:terms]).map do |term|
        {
          factors: term[:factors].reject { |id, _| drop.include?(id.to_s) },
          logs: term[:logs].reject { |id, _| drop.include?(id.to_s) }
        }
      end
      normalize(
        terms: terms,
        domains: (expression[:domains] || {}).reject { |id, _| drop.include?(id.to_s) },
        complete: expression.fetch(:complete, true)
      )
    end

    # Ids of the open callback-cost parameters in an expression. Reflective
    # costs are deliberately excluded: no callable is passed at those sites, so
    # nothing can close them.
    def callback_domain_ids(expression)
      (expression && expression[:domains] || {}).filter_map do |id, domain|
        next unless domain.is_a?(Hash)

        id if (domain["source_kind"] || domain[:source_kind]).to_s == "callback_cost"
      end
    end

    # Choose the substitution for a call site that several callables reach
    # (`fold(seed, |a, b| ...)`, a nesting chain). The bound must hold for all
    # of them, so one callable of unknown cost forces C to stay open; otherwise
    # the costliest known cost is the substitution.
    #
    # Each row is `{ expression:, constant: }` - the callable's symbolic cost,
    # and whether it is proven constant.
    def worst_callable(rows)
      rows = Array(rows)
      return nil if rows.empty?
      return { expression: nil, constant: false } if rows.any? do |row|
        row[:expression].nil? && !row[:constant]
      end

      {
        expression: rows.filter_map { |row| row[:expression] }.max_by { |value| degree(value) },
        constant: true
      }
    end

    # Replace an open callback cost C with the cost of the callable actually
    # passed at that call site. An O(1) callable removes C (O(N*C) -> O(N)); a
    # costlier one multiplies its own cost in (O(N*C) -> O(N*M)).
    #
    # A callable whose own cost is neither symbolically known nor proven
    # constant leaves C open. Dropping it there would silently price a
    # non-constant callback as free.
    def substitute_callback_cost(expression, callable, callable_constant: false)
      ids = callback_domain_ids(expression)
      return expression if ids.empty?
      return expression unless callable || callable_constant

      reduced = without_domains(expression, ids)
      return reduced unless callable && degree(callable).positive?

      multiply(reduced, callable)
    end

    def render(expression)
      return nil unless expression

      terms = Array(expression[:terms])
      factor_entries = terms.sum { |term| term[:factors].length + term[:logs].length }
      if terms.length > RENDER_DOMAIN_LIMIT || factor_entries > RENDER_DOMAIN_LIMIT
        return render_collapsed_upper_bound(expression, terms)
      end

      ids = terms.flat_map { |term| term[:factors].keys + term[:logs].keys }.uniq
      ids.sort_by! do |id|
        containing_terms = Array(expression[:terms]).select { |term| term[:factors].key?(id) || term[:logs].key?(id) }
        exponents = containing_terms.map { |term| term[:factors].fetch(id, 0) }
        log_exponents = containing_terms.map { |term| term[:logs].fetch(id, 0) }
        containing_degrees = containing_terms.map { |term| term[:factors].values.sum }
        [-(containing_degrees.max || 0), -(exponents.max || 0), -exponents.sum,
         -(log_exponents.max || 0), -log_exponents.sum,
         *domain_sort_key(expression[:domains]&.fetch(id, nil), id)]
      end
      parameter_ids, size_ids = ids.partition do |id|
        domain = expression[:domains]&.fetch(id, nil) || {}
        (domain["source_kind"] || domain[:source_kind]).to_s.end_with?("_cost")
      end
      symbols = size_ids.each_with_index.to_h do |id, index|
        [id, LETTERS[index] || "D#{index + 1}"]
      end
      callback_index = 0
      reflection_index = 0
      parameter_ids.each do |id|
        domain = expression[:domains]&.fetch(id, nil) || {}
        kind = (domain["source_kind"] || domain[:source_kind]).to_s
        if kind == "reflective_target_cost"
          reflection_index += 1
          symbols[id] = reflection_index == 1 ? "R" : "R#{reflection_index}"
        else
          callback_index += 1
          symbols[id] = callback_index == 1 ? "C" : "C#{callback_index}"
        end
      end
      order = symbols.keys.each_with_index.to_h
      ordered_terms = Array(expression[:terms]).sort_by do |term|
        exponent_vector = symbols.keys.map { |id| -term[:factors].fetch(id, 0) }
        log_vector = symbols.keys.map { |id| -term[:logs].fetch(id, 0) }
        [-term[:factors].values.sum, *exponent_vector, *log_vector]
      end
      bodies = ordered_terms.map do |term|
        factors = term[:factors].sort_by { |id, _| order.fetch(id) }.map do |id, exponent|
          symbol = symbols.fetch(id)
          exponent == 1 ? symbol : "#{symbol}^#{exponent}"
        end
        body = factors.empty? ? "1" : factors.join("*")
        logarithms = term[:logs].sort_by { |id, _| order.fetch(id) }.map do |id, exponent|
          logarithm = "log #{symbols.fetch(id)}"
          exponent == 1 ? logarithm : "(#{logarithm})^#{exponent}"
        end
        unless logarithms.empty?
          body = factors.empty? ? logarithms.join("*") : "#{body} #{logarithms.join('*')}"
        end
        body
      end
      ["O(#{bodies.join(' + ')})", variables(expression, symbols)]
    end

    # A function has a fixed number of input domains, so a sum over many
    # independent domains is bounded by the largest domain raised to the
    # greatest observed degree (constant coefficients disappear in Big-O).
    # Preserve callback/reflection parameters as C/R so proof-tier
    # classification remains parametric rather than silently closing them.
    def render_collapsed_upper_bound(expression, terms)
      maxima = { size: 0, size_logs: 0, callback: 0, reflection: 0 }
      ids = { size: {}, callback: {}, reflection: {} }
      domains = expression[:domains] || {}
      terms.each do |term|
        row = { size: 0, size_logs: 0, callback: 0, reflection: 0 }
        term[:factors].each do |id, exponent|
          domain = domains.fetch(id, {})
          kind = (domain["source_kind"] || domain[:source_kind]).to_s
          bucket = if kind == "reflective_target_cost"
                     :reflection
                   elsif kind.end_with?("_cost")
                     :callback
                   else
                     :size
                   end
          row[bucket] += exponent
          ids[bucket][id] = true
        end
        term[:logs].each do |id, exponent|
          row[:size_logs] += exponent
          ids[:size][id] = true
        end
        maxima.each_key { |key| maxima[key] = [maxima[key], row[key]].max }
      end

      parts = []
      parts << power_text("N", maxima[:size]) if maxima[:size].positive?
      parts << power_text("log N", maxima[:size_logs], grouped: true) if maxima[:size_logs].positive?
      parts << power_text("C", maxima[:callback]) if maxima[:callback].positive?
      parts << power_text("R", maxima[:reflection]) if maxima[:reflection].positive?
      parts << "1" if parts.empty?
      variables = []
      [
        [:size, "N", "size"],
        [:callback, "C", "callback cost"],
        [:reflection, "R", "reflective target cost"]
      ].each do |bucket, symbol, label|
        next if ids[bucket].empty?

        variables << {
          symbol: symbol,
          domain_id: "collapsed:#{bucket}",
          name: "maximum of #{ids[bucket].length} #{label} domains",
          source_kind: "collapsed_upper_bound",
          domain_count: ids[bucket].length
        }
      end
      ["O(#{parts.join('*')})", variables]
    end

    def power_text(symbol, exponent, grouped: false)
      return symbol if exponent == 1

      grouped ? "(#{symbol})^#{exponent}" : "#{symbol}^#{exponent}"
    end

    def variables(expression, symbols = nil)
      symbols ||= begin
        ids = Array(expression[:terms]).flat_map { |term| term[:factors].keys + term[:logs].keys }.uniq.sort
        ids.each_with_index.to_h { |id, index| [id, LETTERS[index] || "D#{index + 1}"] }
      end
      symbols.map do |id, symbol|
        domain = expression[:domains]&.fetch(id, nil) || { "id" => id, "name" => id, "source_kind" => "unknown" }
        {
          symbol: symbol,
          domain_id: id,
          name: domain["name"] || domain[:name] || id,
          source_kind: domain["source_kind"] || domain[:source_kind] || "unknown",
          path: domain["path"] || domain[:path],
          span: domain["span"] || domain[:span],
          origin_owner: domain["origin_owner"] || domain[:origin_owner],
          origin_function: domain["origin_function"] || domain[:origin_function],
          propagated_via: domain["propagated_via"] || domain[:propagated_via],
          domain_count: domain["domain_count"] || domain[:domain_count]
        }.compact
      end
    end

    def degree(expression)
      Array(expression&.dig(:terms)).map do |term|
        term[:factors].values.sum + (term[:logs].values.sum * 0.1)
      end.max || 0
    end

    def rank_string(value)
      text = value.to_s
      return 200 if text == "O(N!)"
      return 100 if text == "O(2^N)"
      return 0 if text == "O(1)"
      return 0.1 if text == "O(log N)"
      return -1 if text == "unknown"

      body = text[/\AO\((.*)\)\z/, 1]
      return 0 unless body

      body.split(" + ").map do |term|
        compact_term = term.delete(" ")
        polynomial = compact_term.scan(/(?:\A|\*)(?:[A-Z]|D\d+)(?:\^(\d+))?/).sum do |match|
          match.first.to_i.zero? ? 1 : match.first.to_i
        end
        polynomial + (term.include?("log ") ? 0.1 : 0)
      end.max || 0
    end

    def normalize(expression)
      raw_terms = Array(expression[:terms])
      factor_entries = raw_terms.sum { |term| term[:factors].length + (term[:logs] || {}).length }
      if raw_terms.length > RENDER_DOMAIN_LIMIT || factor_entries > RENDER_DOMAIN_LIMIT
        return collapse_expression(expression, raw_terms)
      end

      terms = raw_terms.map do |term|
        intern_term(
          term[:factors].select { |_, exponent| exponent.to_i.positive? }.transform_values(&:to_i),
          (term[:logs] || {}).select { |_, exponent| exponent.to_i.positive? }.transform_values(&:to_i)
        )
      end.uniq
      terms.reject! do |candidate|
        terms.any? { |other| !other.equal?(candidate) && dominates?(other, candidate) }
      end
      canonical_terms = terms.sort_by { |term| [term[:factors].to_a, term[:logs].to_a] }.freeze
      canonical_domains = intern_domains(expression[:domains] || {})
      canonical = expression.merge(terms: canonical_terms, domains: canonical_domains).freeze
      @expression_pool ||= {}
      key = [canonical_terms, canonical_domains, canonical.fetch(:complete, true)]
      @expression_pool[key] ||= canonical
    end

    def collapse_expression(expression, terms)
      source_domains = expression[:domains] || {}
      maxima = { size: 0, size_logs: 0, callback: 0, reflection: 0 }
      ids = { size: {}, callback: {}, reflection: {} }
      terms.each do |term|
        row = { size: 0, size_logs: 0, callback: 0, reflection: 0 }
        term[:factors].each do |id, exponent|
          domain = source_domains.fetch(id, {})
          kind = (domain["source_kind"] || domain[:source_kind]).to_s
          bucket = if kind == "reflective_target_cost"
                     :reflection
                   elsif kind.end_with?("_cost")
                     :callback
                   else
                     :size
                   end
          row[bucket] += exponent.to_i
          ids[bucket][id] = true
        end
        (term[:logs] || {}).each do |id, exponent|
          row[:size_logs] += exponent.to_i
          ids[:size][id] = true
        end
        maxima.each_key { |key| maxima[key] = [maxima[key], row[key]].max }
      end

      factors = {}
      factors["collapsed:size"] = maxima[:size] if maxima[:size].positive?
      factors["collapsed:callback"] = maxima[:callback] if maxima[:callback].positive?
      factors["collapsed:reflection"] = maxima[:reflection] if maxima[:reflection].positive?
      logs = {}
      logs["collapsed:size"] = maxima[:size_logs] if maxima[:size_logs].positive?
      canonical_terms = [intern_term(factors, logs)].freeze
      domains = {}
      [
        [:size, "size", "collapsed_upper_bound"],
        [:callback, "callback cost", "callback_cost"],
        [:reflection, "reflective target cost", "reflective_target_cost"]
      ].each do |bucket, label, source_kind|
        next if ids[bucket].empty?

        domains["collapsed:#{bucket}"] = {
          "id" => "collapsed:#{bucket}",
          "name" => "maximum of #{ids[bucket].length} #{label} domains",
          "source_kind" => source_kind,
          "domain_count" => ids[bucket].length
        }
      end
      canonical_domains = intern_domains(domains)
      canonical = expression.merge(terms: canonical_terms, domains: canonical_domains).freeze
      @expression_pool ||= {}
      key = [canonical_terms, canonical_domains, canonical.fetch(:complete, true)]
      @expression_pool[key] ||= canonical
    end

    def intern_term(factors, logs)
      @term_pool ||= {}
      canonical_factors = factors.sort.to_h.freeze
      canonical_logs = logs.sort.to_h.freeze
      key = [canonical_factors, canonical_logs]
      @term_pool[key] ||= { factors: canonical_factors, logs: canonical_logs }.freeze
    end

    def intern_domains(domains)
      @domain_pool ||= {}
      canonical = domains.sort_by { |id, _| id.to_s }.to_h do |id, domain|
        [id.to_s.freeze, intern_domain_value(domain)]
      end
      @domain_pool[canonical] ||= canonical.freeze
    end

    # Deep-freeze a single domain once and reuse it across every expression that
    # references the same domain. `normalize` used to re-`deep_freeze_copy` every
    # domain on every call, which dominated GC; the per-domain pool collapses that
    # to one copy per distinct domain (facts are read-only, so keying on the raw
    # domain hash is safe).
    def intern_domain_value(domain)
      @domain_value_pool ||= {}
      @domain_value_pool[domain] ||= deep_freeze_copy(domain)
    end

    def deep_freeze_copy(value)
      case value
      when Hash
        value.to_h { |key, child| [deep_freeze_copy(key), deep_freeze_copy(child)] }.freeze
      when Array
        value.map { |child| deep_freeze_copy(child) }.freeze
      when String
        # `-string` returns a frozen, de-duplicated copy (shared fstring), which
        # is cheaper and lower-churn than dup+freeze for the repeated domain text.
        -value
      else
        value.freeze
      end
    end

    def dominates?(left, right)
      right[:factors].all? { |id, exponent| left[:factors].fetch(id, 0) >= exponent } &&
        right[:logs].all? { |id, exponent| left[:logs].fetch(id, 0) >= exponent }
    end

    def domain_index(domains)
      index = Array(domains).each_with_object({}) do |domain, out|
        id = domain["id"] || domain[:id]
        out[id.to_s] = domain if id
      end
      intern_domains(index)
    end

    def domain_sort_key(domain, id)
      return ["", 0, 0, id] unless domain

      span = domain["span"] || domain[:span] || []
      [domain["path"] || domain[:path] || "", span[0].to_i, span[1].to_i, id]
    end
  end
end
