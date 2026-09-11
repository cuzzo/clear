# frozen_string_literal: true

# Stage 2 measurement at the UNIT boundary: let the whole closure compile even
# when some units cannot.
#
# probe_multi_error accumulates at the statement boundary and
# probe_lowering_survives at the function boundary. Everything that raises
# EARLIER than a statement -- DUPLICATE_DECLARATION at declaration time, an
# unresolved-type-facts assertion at the annotation boundary -- still ends the
# entire run, so a round reports ONE unit and no denominator. This is the same
# transform one level up: catch at the unit, record, hand back an empty module,
# and keep going.
#
# A dependent of a failed unit then sees none of its symbols, so the round's
# later errors include cascades. They are guidance, not verdicts -- the same
# caveat probe_multi_error carries. The point is that one round yields a work
# list across all 182 units instead of the first one that dies.
#
# It also times each unit, because nothing has ever measured where the ~25
# minutes goes.
require 'json'

module ProbeUnitSurvives
  FAILED = []
  TIMING = []

  def self.report
    { 'failed' => FAILED, 'timing' => TIMING.sort_by { |t| -t['seconds'] } }
  end

  def self.blank_module(source_dir)
    ModuleImporter::CompiledModule.new(
      nil, Scope.new, '', source_dir, {}, {}, {}, '', [], [], nil
    )
  end

  def compile_file(path, caller_dir: nil)
    abs = File.expand_path(path.to_s, caller_dir || instance_variable_get(:@base_dir))
    guard(abs, File.dirname(abs), abs) { super }
  end

  def compile_package_group(pkg_name, members)
    dir = File.dirname(members.first.to_s)
    guard("pkg:#{pkg_name}", dir, "pkg-group:#{pkg_name}") { super }
  end

  private

  # A failed unit MUST be memoised under the importer's own key. Without it the
  # importer never records the failure, so every dependent re-attempts the
  # compile from scratch and pays its full cost again -- the traversal stops
  # being linear in units and never finishes.
  def guard(unit, source_dir, cache_key)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = yield
    TIMING << { 'unit' => unit, 'seconds' => (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(2) }
    result
  rescue StandardError => e
    raise if e.is_a?(SystemExit) || e.is_a?(SignalException)
    # A cycle is the importer's own control flow, not a unit defect.
    raise if e.class.name.to_s.include?('CircularDependency')

    TIMING << { 'unit' => unit, 'seconds' => (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(2) }
    FAILED << {
      'unit' => unit,
      'class' => e.class.name.to_s,
      'message' => e.message.to_s.gsub(/\e\[[0-9;]*m/, '').lines.first(3).join.strip[0, 400],
    }
    blank = ProbeUnitSurvives.blank_module(source_dir)
    cache = instance_variable_get(:@module_cache)
    cache[cache_key] = blank if cache.respond_to?(:[]=)
    compiling = instance_variable_get(:@compiling)
    compiling.delete(cache_key) if compiling.respond_to?(:delete)
    blank
  end
end

TracePoint.new(:end) do |tp|
  k = tp.self
  next unless k.is_a?(Class)
  own = k.instance_methods(false) + k.private_instance_methods(false)
  # Identify the importer by what it defines, not by its name.
  next unless own.include?(:compile_file) && own.include?(:compile_package_group)
  k.prepend(ProbeUnitSurvives)
  tp.disable
end.enable
