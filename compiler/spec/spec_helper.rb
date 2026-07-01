# Loaded by .rspec via `--require spec_helper`. SimpleCov MUST start
# before any compiler source is required, otherwise files loaded earlier
# (transpiler.rb, lexer.rb, etc.) won't be instrumented.
#
# Output:
#   - coverage/.last_run.json -- RubyCritic's simple_cov formatter reads
#     this to populate its coverage column.
#   - coverage/.resultset.json -- per-run line+branch hit data. Merged
#     across runs (and across parallel workers) within merge_timeout.
#   - coverage/index.html     -- standalone HTML report.
#
# Off by default -- SimpleCov + parallel_rspec adds ~15x to wall time
# (2s -> 30s on this repo). CI's ruby-unit job opts in via COVERAGE=1
# so Codecov gets fresh data per push; local devs run uninstrumented
# and only flip the env var when they want a coverage report.

SPEC_ROOT = File.expand_path(__dir__)
$LOAD_PATH.unshift(SPEC_ROOT) unless $LOAD_PATH.include?(SPEC_ROOT)

if ENV["COVERAGE"] == "1"
  require "simplecov"

  # parallel_rspec forks N workers via Kernel#fork. Two consequences:
  #
  # (a) Every worker inherits the parent's SimpleCov instance with
  #     command_name "RSpec". Without per-worker disambiguation they
  #     all write to .resultset.json under the same key and the last
  #     to exit overwrites everyone else -- coverage collapses from
  #     ~75% to ~10%.
  #
  # (b) simplecov/process.rb only patches Process.fork, not
  #     Kernel#fork, so the SimpleCov.at_fork machinery never fires
  #     for parallel_rspec workers.
  #
  # Hook into parallel_rspec's own Config.after_fork (called inside
  # each child right after fork) to give the worker a unique
  # command_name and restart SimpleCov so its hits land under that
  # key. The parent merges all RSpec-w* resultsets at its at_exit.
  if defined?(ParallelRSpec) && ParallelRSpec::Config.respond_to?(:after_fork)
    ParallelRSpec::Config.after_fork do |worker|
      SimpleCov.command_name "RSpec-w#{worker}-#{Process.pid}"
      SimpleCov.print_error_status = false
      SimpleCov.minimum_coverage 0
      SimpleCov.start
    end
  end

  # Cobertura XML output for Codecov / Coveralls / GitLab. CI-friendly:
  # only loads the formatter when the gem is actually installed (skip
  # gracefully if a dev environment has bare simplecov).
  begin
    require "simplecov-cobertura"
    cobertura_available = true
  rescue LoadError
    cobertura_available = false
  end

  SimpleCov.start do
    coverage_dir ENV.fetch("COVERAGE_DIR", "coverage")
    enable_coverage :branch

    if cobertura_available
      formatter SimpleCov::Formatter::MultiFormatter.new([
        SimpleCov::Formatter::HTMLFormatter,
        SimpleCov::Formatter::CoberturaFormatter,
      ])
    end

    # Track all production code under compiler/ruby.
    track_files "compiler/ruby/**/*.rb"

    # Filter the rest -- they'd otherwise dilute the percentage.
    add_filter "/compiler/spec/"
    add_filter "/transpile-tests/"
    add_filter "/vendor/"
    add_filter "/examples/"
    add_filter "/benchmarks/"
    add_filter "/gems/nil-kill/"
    # Track user-facing compiler tools under compiler/ruby/tools. Root-level tools/
    # is internal repo automation and is not tracked by track_files above.
    add_filter do |source_file|
      source_file.filename.start_with?(File.join(SimpleCov.root, "tools/"))
    end

    # Subsystem groups so the index page surfaces where coverage is
    # concentrated vs. missing.
    add_group "AST + ClearParser",      "compiler/ruby/ast"
    add_group "Annotator",         "compiler/ruby/annotator"
    add_group "Annotator helpers", "compiler/ruby/annotator/helpers"
    add_group "MIR",               "compiler/ruby/mir"
    add_group "Backends",          "compiler/ruby/backends"
    add_group "Tools",             "compiler/ruby/tools"

    # Hold the resultset for an hour so a partial re-run merges into
    # existing data rather than dropping files the subset didn't load.
    merge_timeout 3600
  end
end

if defined?(ParallelRSpec) && File.basename($PROGRAM_NAME) == "prspec"
  files = RSpec.configuration.instance_variable_get(:@files_or_directories_to_run)
  RSpec.configuration.files_or_directories_to_run = RSpec.configuration.default_path if files.empty?
end

module MirPipelineSpecHelper
  def capability_transition(cap)
    require_relative "../ruby/semantic/capability_plan"

    source = if cap.is_a?(AST::Capability)
      cap
    else
      AST::Capability.new(**cap)
    end
    request = CapabilityPlan::CapabilityRequest.from_ast(source)
    var_node = request.var_node
    var_name = CapabilityPlan.var_name_for(var_node)
    resolved_type = source.resolved_type
    if resolved_type.untyped? && var_node.respond_to?(:full_type)
      begin
        resolved_type = var_node.full_type!(context: "spec capability transition")
      rescue RuntimeError
        resolved_type = Type.new(:Untyped)
      end
    end
    source_entry = if var_node.respond_to?(:symbol)
      var_node.symbol
    end
    old_scope = T.cast(source[:old_scope], T.nilable(Scope))
    source_type = source_entry ? Type.new(source_entry.type) : Type.new(resolved_type)
    target_label = if var_node.is_a?(AST::GetField)
      var_node.field.to_s
    elsif var_node.respond_to?(:name)
      var_node.name
    else
      var_name
    end
    target = CapabilityPlan::CapabilityTargetFact.new(
      var_node: var_node,
      var_name: var_name,
      target_label: target_label,
      field_target: var_node.is_a?(AST::GetField),
      index_target: var_node.is_a?(AST::GetIndex),
      resolved_type: Type.new(resolved_type),
      old_scope: old_scope,
      source_entry: source_entry,
      source_type: source_type,
      sync: source_entry&.sync || Type.new(resolved_type).sync,
      storage: source_entry&.storage || Type.new(resolved_type).ownership_storage,
      layout: source_entry&.layout || Type.new(resolved_type).layout,
      live_symbol_refreshed: false,
    )
    CapabilityPlan.transition_from(request, target, nil)
  end

  def attach_capability_plan!(with_node)
    require_relative "../ruby/semantic/capability_plan"

    plan = CapabilityPlan::WithCapabilityPlan.new
    with_node.capabilities.each do |cap|
      plan.add(capability_transition(cap))
    end
    with_node.capability_plan = plan
    with_node
  end

  def compile_mir_frontend(src, source_dir: Dir.pwd)
    require_relative "../ruby/compiler/compiler_frontend"
    require_relative "../ruby/compiler/module_importer"

    importer = ModuleImporter.new(base_dir: source_dir, use_mir: true)
    result = CompilerFrontend.compile(src, importer: importer, source_dir: source_dir)
    raise "CompilerFrontend returned nil" unless result

    result
  end

  def run_mir_frontend(src, source_dir: Dir.pwd)
    compile_mir_frontend(src, source_dir: source_dir).ast
  end
end

RSpec.configure do |config|
  config.include MirPipelineSpecHelper
end
