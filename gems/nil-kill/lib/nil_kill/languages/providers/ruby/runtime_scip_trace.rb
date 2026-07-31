# frozen_string_literal: true

# The value, package and record semantics the runtime_call event is built from.
# Observation itself lives in the native collector (ext/nil_kill_trace); this is
# what the collector delegates back to Ruby, once per distinct question and
# cached, so there is exactly one implementation of each rule.
module NilKillRuntimeTrace
  @runtime_package_by_path = {}
  @runtime_generated_wrapper_methods = Set.new

  def self.runtime_package(path, native:)
    return {
      package_manager: "ruby",
      package: "ruby",
      version: RUBY_VERSION,
    } if native

    # TracePoint uses pseudo-paths such as `<internal:warning>` for Ruby-core
    # implementations written outside the workspace. `File.expand_path`
    # would turn those into a relative path under ROOT and incorrectly label
    # `Kernel#warn` (and peers) as project code. They have no workspace source
    # declaration to analyze, so retain the trusted Ruby-core identity.
    raw_path = path.to_s
    if raw_path.start_with?("<internal:")
      return {
        package_manager: "ruby",
        package: "ruby",
        version: RUBY_VERSION,
      }
    end

    absolute = raw_path.empty? ? nil : abs_path(raw_path)
    return @runtime_package_by_path[absolute] if absolute && @runtime_package_by_path.key?(absolute)

    package =
      if absolute && target_path?(absolute)
        {
          package_manager: "workspace",
          package: ENV.fetch("NIL_KILL_PROJECT_NAME", File.basename(ROOT)),
          version: ENV.fetch("NIL_KILL_PROJECT_VERSION", "workspace"),
        }
      elsif absolute
        default_stubs = Gem::Specification.default_stubs
        spec = Gem.loaded_specs.values.find do |candidate|
          root = File.expand_path(candidate.full_gem_path)
          absolute == root || absolute.start_with?("#{root}#{File::SEPARATOR}")
        end
        spec ||= default_stubs.find do |candidate|
          root = File.expand_path(candidate.full_gem_path)
          absolute == root || absolute.start_with?("#{root}#{File::SEPARATOR}")
        end
        if spec
          stdlib = default_stubs.any? { |stub| stub.name == spec.name }
          {
            # Ruby ships a growing portion of its standard library as default
            # gems. Bundler may activate a newer vendored copy, but that does
            # not turn StringIO, JSON, etc. into third-party APIs.
            package_manager: stdlib ? "ruby" : "rubygems",
            package: spec.name,
            version: spec.version.to_s,
          }
        elsif absolute == ROOT || absolute.start_with?("#{ROOT}#{File::SEPARATOR}")
          # Trace targets are intentionally narrower than the workspace: a
          # project may call a sibling tool without instrumenting that tool's
          # source. It is still a workspace declaration, not a Ruby core
          # method. Keep real loaded gems above this branch so a checked-out
          # gem dependency retains its exact Rubygems identity.
          {
            package_manager: "workspace",
            package: ENV.fetch("NIL_KILL_PROJECT_NAME", File.basename(ROOT)),
            version: ENV.fetch("NIL_KILL_PROJECT_VERSION", "workspace"),
          }
        else
          {
            package_manager: "ruby",
            package: "ruby",
            version: RUBY_VERSION,
          }
        end
      else
        {
          package_manager: "ruby",
          package: "ruby",
          version: RUBY_VERSION,
        }
      end
    @runtime_package_by_path[absolute] = package if absolute
    package
  end

  def self.runtime_nonproduction_source_path?(path)
    runtime_nonproduction_source_paths.include?(File.expand_path(path, ROOT))
  rescue StandardError
    false
  end

  def self.runtime_nonproduction_source_paths
    source_roles_path = ENV["NIL_KILL_SOURCE_ROLES"].to_s
    cached = @runtime_nonproduction_source_paths
    return cached[:paths] if cached && cached[:source] == source_roles_path

    paths =
      if !source_roles_path.empty? && File.file?(source_roles_path)
        Array(JSON.parse(File.read(source_roles_path))["nonproduction"]).map do |path|
          File.expand_path(path, ROOT)
        end
      else
        []
      end
    @runtime_nonproduction_source_paths = {
      source: source_roles_path,
      paths: paths.to_set.freeze,
    }
    @runtime_nonproduction_source_paths[:paths]
  rescue StandardError
    @runtime_nonproduction_source_paths = {
      source: source_roles_path,
      paths: Set.new.freeze,
    }
    @runtime_nonproduction_source_paths[:paths]
  end

end
