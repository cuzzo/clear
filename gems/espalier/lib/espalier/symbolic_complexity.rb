# frozen_string_literal: true

module Espalier
  # Language-neutral algebra for polynomial size domains emitted by FactMine.
  # Domain ids are semantic; N/M/K are assigned only when rendering.
  module SymbolicComplexity
    module_function

    LETTERS = %w[N M K L P Q R S T U V W X Y Z].freeze

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
      {
        terms: [{ factors: factors, logs: logarithmic_domain ? { logarithmic_domain => 1 } : {} }],
        domains: domain_index(domains),
        complete: term.key?("complete") ? term["complete"] : term.fetch(:complete, true)
      }
    end

    def constant
      { terms: [{ factors: {}, logs: {} }], domains: {}, complete: true }
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

    def render(expression)
      return nil unless expression

      ids = Array(expression[:terms]).flat_map { |term| term[:factors].keys + term[:logs].keys }.uniq
      ids.sort_by! do |id|
        containing_terms = Array(expression[:terms]).select { |term| term[:factors].key?(id) || term[:logs].key?(id) }
        exponents = containing_terms.map { |term| term[:factors].fetch(id, 0) }
        log_exponents = containing_terms.map { |term| term[:logs].fetch(id, 0) }
        containing_degrees = containing_terms.map { |term| term[:factors].values.sum }
        [-(containing_degrees.max || 0), -(exponents.max || 0), -exponents.sum,
         -(log_exponents.max || 0), -log_exponents.sum,
         *domain_sort_key(expression[:domains]&.fetch(id, nil), id)]
      end
      symbols = ids.each_with_index.to_h do |id, index|
        [id, LETTERS[index] || "D#{index + 1}"]
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
          propagated_via: domain["propagated_via"] || domain[:propagated_via]
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
      terms = Array(expression[:terms]).map do |term|
        {
          factors: term[:factors].select { |_, exponent| exponent.to_i.positive? }.transform_values(&:to_i),
          logs: (term[:logs] || {}).select { |_, exponent| exponent.to_i.positive? }.transform_values(&:to_i)
        }
      end.uniq
      terms.reject! do |candidate|
        terms.any? { |other| other != candidate && dominates?(other, candidate) }
      end
      expression.merge(terms: terms.sort_by { |term| [term[:factors].to_a, term[:logs].to_a] })
    end

    def dominates?(left, right)
      right[:factors].all? { |id, exponent| left[:factors].fetch(id, 0) >= exponent } &&
        right[:logs].all? { |id, exponent| left[:logs].fetch(id, 0) >= exponent }
    end

    def domain_index(domains)
      Array(domains).each_with_object({}) do |domain, out|
        id = domain["id"] || domain[:id]
        out[id.to_s] = domain if id
      end
    end

    def domain_sort_key(domain, id)
      return ["", 0, 0, id] unless domain

      span = domain["span"] || domain[:span] || []
      [domain["path"] || domain[:path] || "", span[0].to_i, span[1].to_i, id]
    end
  end
end
