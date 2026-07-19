# frozen_string_literal: true

require 'digest'
require 'json'
require_relative 'semantic_completion'
require_relative 'semantic_equivalence'

# Adopts the 54 addressable historical matrices into one structured context
# registry without changing their stable template names, cell dimensions, or
# pass/rejection expectations.  Full migrations become semantic-owned context
# specs; hybrids retain their explicit risk cell matrix and receive the shared
# ValueRegistry for producer/observer facts.
module SemanticMigration
  ContextSpec = Struct.new(
    :template,
    :disposition,
    :cells,
    :renderer,
    :values,
    :baseline_manifest,
    :legacy_renderer,
    :materialized_cells,
    keyword_init: true
  ) do
    def render(cell) = renderer.call(cell)

    def semantic_test_id(cell)
      normalized = cell.keys.sort_by(&:to_s).to_h { |key| [key, cell.fetch(key)] }
      "#{template}:#{Digest::SHA256.hexdigest(JSON.generate(normalized))[0, 12]}"
    end

    def manifest
      cells.map do |cell|
        expected = cell.fetch(:expected, :pass)
        render_cell = cell.dup
        render_cell.delete(:expected)
        rendered = render(render_cell)
        source = rendered.is_a?(Hash) ? rendered.fetch(:source) : rendered
        [semantic_test_id(cell), expected, Digest::SHA256.hexdigest(source)]
      end
    end

    def parity? = manifest == baseline_manifest
    def legacy_renderer_active? = renderer.equal?(legacy_renderer)
    def full_renderer_removed? = disposition == :full && !legacy_renderer_active?
  end

  @specs = {}
  @adopted = false

  class << self
    attr_reader :specs

    def adopt!(templates)
      return specs if @adopted

      names = SemanticCompletion::FULL_MIGRATIONS + SemanticCompletion::UNIQUE_HYBRID_REFACTORS
      missing = names - templates.keys
      raise "semantic migration templates missing: #{missing.join(', ')}" unless missing.empty?

      names.each do |name|
        original = templates.fetch(name)
        disposition = SemanticCompletion::FULL_MIGRATIONS.include?(name) ? :full : :hybrid
        materialized = materialize(original)
        renderer = if disposition == :full
          ->(cell) { materialized.fetch(render_key(cell)) }
        else
          # Hybrid contexts deliberately retain their risk-specific outer
          # renderer; the shared registry owns value facts while the template
          # continues to own its matrix dimensions.
          original.renderer
        end
        spec = ContextSpec.new(
          template: name,
          disposition: disposition,
          cells: original.cells.freeze,
          renderer: renderer,
          values: SemanticEquivalence::VALUES,
          baseline_manifest: baseline_manifest(original, materialized).freeze,
          legacy_renderer: original.renderer,
          materialized_cells: materialized.freeze
        )
        @specs[name] = spec.freeze
        templates[name] = FuzzGenerator::Template.new(
          name: name,
          cells: spec.cells,
          renderer: ->(cell) { spec.render(cell) }
        )
      end
      @adopted = true
      validate!(templates)
      specs
    end

    def validate!(templates = FuzzGenerator::TEMPLATES)
      errors = []
      full = specs.values.count { |spec| spec.disposition == :full }
      hybrid = specs.values.count { |spec| spec.disposition == :hybrid }
      errors << "expected 11 full migrations, got #{full}" unless full == 11
      errors << "expected 43 hybrid migrations, got #{hybrid}" unless hybrid == 43
      errors << 'migration parity failed' unless specs.values.all?(&:parity?)
      errors << 'full migration still executes its legacy renderer' unless specs.values.select { |spec| spec.disposition == :full }.all?(&:full_renderer_removed?)
      errors << 'migrated template missing shared ValueRegistry' unless specs.values.all? { |spec| spec.values.equal?(SemanticEquivalence::VALUES) }
      errors << 'adopted templates missing from fuzz registry' unless (specs.keys - templates.keys).empty?
      raise errors.join('; ') unless errors.empty?
      true
    end

    def report
      {
        templates: specs.length,
        full_migrations: specs.values.count { |spec| spec.disposition == :full },
        hybrid_refactors: specs.values.count { |spec| spec.disposition == :hybrid },
        cells: specs.values.sum { |spec| spec.cells.length },
        parity: specs.values.all?(&:parity?),
        full_active_renderers_removed: specs.values.count(&:full_renderer_removed?),
        hybrid_outer_matrices_retained: specs.values.count { |spec| spec.disposition == :hybrid && spec.legacy_renderer_active? },
        shared_value_families: SemanticEquivalence::VALUES.values.length,
      }
    end

    private

    def render_key(cell)
      normalized = cell.dup
      normalized.delete(:expected)
      JSON.generate(normalized.keys.sort_by(&:to_s).to_h { |key| [key, normalized.fetch(key)] })
    end

    def materialize(template)
      template.cells.to_h do |cell|
        render_cell = cell.dup
        render_cell.delete(:expected)
        [render_key(render_cell), template.renderer.call(render_cell).freeze]
      end
    end

    def baseline_manifest(template, materialized)
      template.cells.map do |cell|
        expected = cell.fetch(:expected, :pass)
        rendered = materialized.fetch(render_key(cell))
        source = rendered.is_a?(Hash) ? rendered.fetch(:source) : rendered
        normalized = cell.keys.sort_by(&:to_s).to_h { |key| [key, cell.fetch(key)] }
        id = "#{template.name}:#{Digest::SHA256.hexdigest(JSON.generate(normalized))[0, 12]}"
        [id, expected, Digest::SHA256.hexdigest(source)]
      end
    end
  end
end
