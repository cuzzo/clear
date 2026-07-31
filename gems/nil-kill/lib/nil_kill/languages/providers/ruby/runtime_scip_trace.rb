# frozen_string_literal: true

# The value, package and record semantics the runtime_call event is built from.
# Observation itself lives in the native collector (ext/nil_kill_trace); this is
# what the collector delegates back to Ruby, once per distinct question and
# cached, so there is exactly one implementation of each rule.
module NilKillRuntimeTrace
  @runtime_package_by_path = {}
  @runtime_generated_wrapper_methods = Set.new
  # Collector-installed wrappers may be the frame the VM reports even though the
  # workload invoked the wrapped method. Preserve that raw target identity
  # without doing any source/call-flow inference.
  @runtime_transparent_wrapper_targets = {}

  def self.register_runtime_scip_transparent_wrapper(defined_class, method_id, target)
    @runtime_transparent_wrapper_targets[[defined_class, method_id.to_sym]] = target.freeze
  end

  # Generated records outside the analyzed source corpus cannot join a parsed
  # declaration. Preserve the runtime-observed record family and members in a
  # structural symbol instead of presenting a body-less nominal method.
  # Generated records inside the corpus retain their nominal identity, while
  # non-production records retain theirs so FactMine can exclude the exact
  # replacement. This is raw Ruby reflection only; FactMine owns validation,
  # dispatch, CFG/DFG propagation, and every cost conclusion.
  def self.register_runtime_scip_generated_record_wrapper(klass, method_id, kind:)
    fields = Array(klass.instance_variable_get(:@__nil_kill_struct_fields))
    return if fields.empty?

    path = klass.instance_variable_get(:@__nil_kill_struct_path)
    family = klass.instance_variable_get(:@__nil_kill_record_family) || "Struct"
    nominal_owner = safe_module_name(klass)
    owner =
      if nominal_owner &&
          path &&
          !target_path?(path) &&
          !runtime_nonproduction_source_path?(path) &&
          !runtime_obvious_nonproduction_path?(path)
        normalized_owner = nominal_owner.split("::").join("/")
        "Generated#{family}(#{normalized_owner};#{fields.map(&:to_s).join(",")})"
      else
        nominal_owner || "Anonymous#{family}(#{fields.map(&:to_s).join(",")})"
      end
    register_runtime_scip_transparent_wrapper(
      kind == "class" ? klass.singleton_class : klass,
      method_id,
      owner: owner,
      name: method_id.to_s,
      kind: kind,
      native: true,
      path: path
    )
  rescue StandardError
    nil
  end

  def self.runtime_obvious_nonproduction_path?(path)
    parts = File.expand_path(path, ROOT).split(File::SEPARATOR)
    %w[test tests spec specs].any? { |component| parts.include?(component) } ||
      File.basename(path).match?(/(?:_test|_spec)\.rb\z/)
  end

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

  # C-backed accessors generated for a workspace/test class arrive as
  # :c_call events, so TracePoint gives them no Ruby method path.  Treating
  # every such method as CRuby incorrectly exports test doubles such as a
  # Struct reader as `ruby` stdlib symbols.  A named receiver class retains
  # the source location of its constant declaration; use that provenance only
  # for identity/role attribution. FactMine still owns the generated-accessor
  # complexity join.
  def self.native_receiver_source_location(receiver)
    klass = receiver.is_a?(Module) ? receiver : receiver.class
    return unless klass.is_a?(Module)

    @runtime_native_receiver_source_locations ||= {}
    return @runtime_native_receiver_source_locations[klass] if
      @runtime_native_receiver_source_locations.key?(klass)

    declared_path = klass.instance_variable_get(:@__nil_kill_struct_path)
    declared_line = klass.instance_variable_get(:@__nil_kill_struct_line)
    name = klass.name.to_s
    location =
      if declared_path && declared_line
        [declared_path, declared_line]
      else
        name.empty? ? nil : Object.const_source_location(name)
      end
    path = location && location.first
    absolute = path && !path.start_with?("<") ? abs_path(path) : nil
    value = absolute && File.file?(absolute) ? { path: absolute, line: location.last.to_i } : nil
    @runtime_native_receiver_source_locations[klass] = value
  rescue StandardError
    @runtime_native_receiver_source_locations[klass] = nil if defined?(klass) && klass
    nil
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

  # Ruby exposes singleton methods on constant objects such as ENV through an
  # anonymous singleton class. TracePoint therefore has an exact receiver but
  # `Module#name` cannot provide its source-level owner. Preserve the loaded
  # top-level constant whose value is identical to that receiver. This is
  # reflection-only identity recovery: it does not resolve dispatch, inspect
  # source, or infer any behavior/cost. Avoid autoloads so observation cannot
  # change application execution.
  def self.runtime_named_singleton_owner(value)
    constants = Object.constants(false)
    if @runtime_named_singleton_owner_constant_count != constants.length
      owners = {}
      constants.sort_by(&:to_s).each do |constant_name|
        next if Object.autoload?(constant_name)

        constant_value = Object.const_get(constant_name, false)
        owners[constant_value.__id__] ||= [constant_name.to_s, "class"]
      rescue NameError
        next
      end
      @runtime_named_singleton_owners = owners.freeze
      @runtime_named_singleton_owner_constant_count = constants.length
    end

    @runtime_named_singleton_owners[value.__id__]
  rescue StandardError
    nil
  end

  def self.empty_runtime_value_domain
    {
      types: [],
      singletons: [],
      elements: [],
      keys: [],
      values: [],
      shapes: [],
    }
  end

  # A runtime record is an observation about the value itself, rather than a
  # source-flow conclusion. Keep it in the language-neutral value-shape
  # vocabulary so FactMine can join it with its CFG/DFG without Ruby having to
  # reason about any call sites. Binding Struct#members also makes collection
  # safe when an application overrides `members` on a generated record.
  def self.runtime_record_shape_key(value, depth = 2)
    return unless value.is_a?(Struct)

    fields = ORIG_STRUCT_MEMBERS.bind_call(value)
    return unless fields.is_a?(Array)

    members = fields.each_with_object({}) do |field, out|
      name = field.to_s
      next if name.empty?

      # Ruby does not emit TracePoint call events for generated Struct reader
      # methods. Preserve the observed member value as a language-neutral
      # shape instead, so FactMine can type a downstream call through its
      # generic record-accessor CFG/DFG join.  This observes the value only;
      # it does not duplicate assignment or dispatch analysis in NilKill.
      member = ORIG_STRUCT_FETCH.bind_call(value, field)
      out[name] = runtime_record_member_shape(member, depth)
    end
    return if members.empty?

    name = runtime_record_type_name(value, fields)
    signature = members.map { |member, shape| "#{member}=#{JSON.generate(shape)}" }.join("\\0")
    key = "record:#{name}:#{signature}".freeze
    remember_shape(key, { kind: "record", name: name, members: members })
  rescue StandardError
    nil
  end

  def self.runtime_record_type_name(value, fields = nil)
    return unless value.is_a?(Struct)

    name = class_name(value)
    return name unless name == "T.untyped"

    # Anonymous Struct classes all lack a Ruby constant name. Treating every
    # layout as the same `T.untyped` record makes FactMine intersect unrelated
    # member sets and blocks generated-accessor proofs. The field schema is a
    # stable structural runtime identity; it claims no source-level nominal
    # type and is sufficient for the generic record contract.
    fields ||= ORIG_STRUCT_MEMBERS.bind_call(value)
    "AnonymousStruct(#{fields.map(&:to_s).join(",")})"
  rescue StandardError
    nil
  end

  def self.runtime_record_member_shape(value, depth)
    return shape_payload(class_shape_key(value)) unless depth.positive?

    record_key = runtime_record_shape_key(value, depth - 1)
    return shape_payload(record_key) if record_key

    if collection_value?(value)
      return shape_payload(collection_type_shape_key(value, depth - 1))
    end

    shape_payload(class_shape_key(value))
  end

  # After the first few executions of a callsite an observation adds no new
  # alternative, yet every merge rebuilt the field with a union, a re-sort, and a
  # JSON.generate per Hash member. Only rebuild when an alternative is genuinely
  # new. Domains are always stored unique and sorted by the same key, so
  # re-merging existing alternatives is exactly the identity and the emitted
  # evidence is unchanged.
  def self.merge_runtime_value_domain!(target, source)
    source.each do |field, values|
      values = Array(values)
      current = target[field]
      if current.nil?
        target[field] = sort_runtime_domain_values(values.uniq)
        next
      end
      next if values.empty?

      added = values.reject { |item| current.include?(item) }
      next if added.empty?

      target[field] = sort_runtime_domain_values(current | added)
    end
    target
  end

  def self.sort_runtime_domain_values(values)
    values.sort_by { |item| item.is_a?(Hash) ? JSON.generate(item) : item.to_s }
  end

end
