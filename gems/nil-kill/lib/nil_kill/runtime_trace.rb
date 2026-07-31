# typed: false
# frozen_string_literal: true

require "fileutils"
require "json"
require "pathname"
require "set"

module NilKillRuntimeTrace
  ROOT = if ENV.key?("NIL_KILL_ROOT")
           File.expand_path(ENV.fetch("NIL_KILL_ROOT"))
         else
           File.expand_path("../../../..", __dir__)
         end
  OUT_DIR = File.expand_path(
    ENV.fetch(
      "NIL_KILL_RUNTIME_DIR",
      File.join(ENV.fetch("NIL_KILL_TMP_DIR", File.join(ROOT, "tmp", "nil-kill")), "runtime")
    ),
    ROOT
  )
  SHARD_ROOT_PID = Process.pid
  TRACE_PLAN_PATH = File.expand_path(File.join(ENV.fetch("NIL_KILL_TMP_DIR", File.join(ROOT, "tmp", "nil-kill")), "trace-plan.json"), ROOT)
  TARGETS = ENV.fetch("NIL_KILL_TARGETS", "src").split(File::PATH_SEPARATOR).map do |path|
    File.expand_path(path, ROOT)
  end
  # This gem's own absolute path, computed ONCE. The per-event caller
  # scan used File.expand_path(__FILE__, ROOT) for EVERY candidate
  # frame to skip this gem's frames; that string-builds per frame.
  SELF_ABS = File.expand_path(__FILE__, ROOT)
  ELEMENT_SAMPLE = ENV.fetch("NIL_KILL_ELEMENT_SAMPLE", "20").to_i
  TRACE_PARAM_CLASSES = ENV.fetch("NIL_KILL_TRACE_PARAM_CLASSES", "String,Symbol").split(",").map(&:strip).reject(&:empty?).to_set

  @structs = {}
  @ivar_runtime = {}
  @runtime_state_values = {}
  @tuples = {}
  @shape_lookup = {}

  # ---- non-hooked recorder-internal accumulators (Fix 2) ----
  # install_collection_hook prepends Array/Hash/Set CLASS-wide, so the
  # recorder's OWN per-observation Set#merge / Hash#[]= bookkeeping
  # re-enters the hook (dispatch + super + marker read) ~dozens of
  # times per traced call -- the recorder taxing itself. NKSet/NKTally
  # are NOT Array/Hash/Set (nor subclasses), so the hook never fires on
  # them. They are recorder-private (never returned to the workload,
  # never marshaled, never serialized as objects -- every dump path
  # first does .to_a.sort / transform_values / sort_by.to_h), so output
  # is byte-identical for EVERY workload (unlike a per-object singleton
  # hook), and any semantics bug surfaces as different recorded JSON ->
  # caught by the byte-identical suite. Writes use Hash#[]= captured
  # HERE, in the class body, BEFORE install_collection_hook (line
  # ~1611) prepends -> the pristine C method, hook-free.
  ORIG_HASH_STORE = ::Hash.instance_method(:[]=)
  # A traced Struct may override #[] for domain-specific lookup (for example,
  # a coverage dataset that accepts a path). Field sampling must use Struct's
  # generated reader directly, never the application override.
  ORIG_STRUCT_FETCH = ::Struct.instance_method(:[])
  ORIG_STRUCT_MEMBERS = ::Struct.instance_method(:members)

  # Set semantics via Hash keys -- identical dedup to ::Set (also
  # Hash-backed: same eql?/hash). Every dump sorts, so insertion order
  # is irrelevant. Surface = exactly what the recorder calls.
  class NKSet
    include Enumerable
    def initialize; @h = {}; end
    def <<(item); ORIG_HASH_STORE.bind_call(@h, item, true); self; end
    alias_method :add, :<<
    def merge(enum); enum.each { |item| ORIG_HASH_STORE.bind_call(@h, item, true) }; self; end
    def each(&blk); @h.each_key(&blk); end
    def to_a; @h.keys; end
    def empty?; @h.empty?; end
    def freeze; @h.freeze; super; end
  end

  # ::Hash.new(0) semantics: a missing key reads as 0 and is NOT
  # stored; only []= stores -> insertion order == first-increment
  # order, exactly as Hash.new(0), so to_h / sort_by are byte-identical.
  class NKTally
    def initialize; @h = {}; end
    def [](key); @h.fetch(key, 0); end
    def []=(key, val); ORIG_HASH_STORE.bind_call(@h, key, val); end
    def to_h; @h; end
    def each(&blk); @h.each(&blk); end
    def sort_by(&blk); @h.sort_by(&blk); end
    def empty?; @h.empty?; end
  end
  @path_cache = {}
  @target_cache = {}
  @rel_cache = {}
  # Type-signature memo for collection shapes. container_shape and
  # collection_type_shape_key are PURE FUNCTIONS of the bounded
  # sampled element CLASSES (not values); the recorder only reads /
  # merges from the result, never mutates it. So a collection whose
  # sampled elements are all one scalar class yields byte-identical
  # output every call -- cache it under a nested-hash class key
  # (alloc-free lookup). Heterogeneous / nested / depth<=0 fall back
  # to the original code path unchanged.
  @cshape = {}
  @ctsk = {}
  @cls_name = {}
  @sampled_tstruct_fields = {}
  @trace_plan_loaded = false
  @trace_plan = nil
  @lock = Mutex.new

  class << self
    attr_reader :methods, :tlets, :structs, :tuples, :collections, :method_edges, :objects, :frames, :path_cache, :target_cache, :lock
  end

  def self.trace_plan
    return nil if ENV["NIL_KILL_TRACE_PLAN"] == "0"
    return @trace_plan if @trace_plan_loaded
    @trace_plan_loaded = true
    @trace_plan = File.exist?(TRACE_PLAN_PATH) ? JSON.parse(File.read(TRACE_PLAN_PATH)) : nil
    if @trace_plan
      plan_targets = Array(@trace_plan["target_dirs"]).map { |path| File.expand_path(path, ROOT) }.sort
      current_targets = TARGETS.map { |path| File.expand_path(path, ROOT) }.sort
      @trace_plan = nil unless plan_targets == current_targets
    end
    @trace_plan
  rescue JSON::ParserError
    @trace_plan = nil
  end

  def self.sample_struct_field?(klass_name, field)
    plan = trace_plan
    return true unless plan
    
    parts = klass_name.to_s.split("::")
    parts.length.downto(1) do |i|
      suffix = parts[-i..-1].join("::")
      value = plan.dig("struct_fields", [suffix, field.to_s].join("\0"))
      return value unless value.nil?
    end
    
    # Struct/Data declarations can be created dynamically or hidden behind
    # unsupported syntax. Absence from the static plan is therefore not proof
    # that a field is resolved; only an explicit false may elide observation.
    true
  end

  # In-place instrumentation: the wrapped file IS at its real src
  # path, so there is no parallel-tree remap to undo. Just expand
  # (cached). The NIL_KILL_INSTRUMENTED_ROOT translation is gone with
  # the parallel tree it served.
  def self.abs_path(path)
    raw = path.to_s
    @path_cache[raw] ||= File.expand_path(raw, ROOT)
  end

  def self.target_path?(path)
    raw = path.to_s
    cached = @target_cache[raw]
    return cached unless cached.nil?
    abs = abs_path(raw)
    TARGETS.any? { |target| abs == target || abs.start_with?(target + File::SEPARATOR) }
      .tap { |matched| @target_cache[raw] = matched }
  end

  MODULE_NAME = Module.instance_method(:name)

  # A module can override the singleton `.name` (e.g. REXML::Functions
  # defines `.name` as an XPath DSL method). Binding Module#name
  # directly always yields the real name and never invokes a user
  # override that could raise mid-trace and abort the whole collect.
  def self.safe_module_name(mod)
    return nil unless mod.is_a?(Module)
    MODULE_NAME.bind_call(mod) rescue nil
  end

  def self.class_name(value)
    return "NilClass" if value.nil?
    cls = value.class rescue nil
    return "T.untyped" unless cls
    n = @cls_name[cls]
    return n if n

    @cls_name[cls] = (safe_module_name(cls) || "T.untyped")
  end

  def self.shape_payload(key)
    @shape_lookup[key] || { "kind" => "class", "name" => "T.untyped" }
  end

  def self.remember_shape(key, payload)
    @shape_lookup[key] ||= payload
    key
  end

  def self.class_shape_key(value)
    cls = class_name(value)
    remember_shape("class:#{cls}", { "kind" => "class", "name" => cls })
  end

  # The single scalar element class shared by the first ELEMENT_SAMPLE
  # elements, or :empty, or nil if heterogeneous / nested-collection /
  # not eligible (-> caller uses the original full path). Allocation-
  # free (index-bounded scan, no intermediate arrays).
  def self.homog_scalar_class(value)
    # Memo-KEY derivation -- reruns every observation even though
    # container_shape / collection_type_shape_key memoize the RESULT.
    # The Array case (the hot one) uses an index loop: same elements,
    # same class checks, same result, but no per-element block-yield.
    if value.is_a?(Array)
      len = value.length
      return :empty if len.zero?

      limit = len < ELEMENT_SAMPLE ? len : ELEMENT_SAMPLE
      c0 = value[0].class
      return nil if c0 == Array || c0 == Hash || c0 == Set

      i = 1
      while i < limit
        cls = value[i].class
        return nil if cls == Array || cls == Hash || cls == Set
        return nil if cls != c0

        i += 1
      end
      return c0
    end

    n = 0
    c0 = nil
    value.each do |item|
      cls = item.class
      return nil if cls == Array || cls == Hash || cls == Set

      if n.zero? then c0 = cls
      elsif cls != c0 then return nil
      end
      n += 1
      break if n >= ELEMENT_SAMPLE
    end
    n.zero? ? :empty : c0
  end

  def self.collection_type_shape_key(value, depth = 3)
    if depth.positive?
      case value
      when Array, Set
        c = homog_scalar_class(value)
        if c
          m = (@ctsk[value.class] ||= {})
          k = m[c]
          return k if k

          return (m[c] = collection_type_shape_key_full(value, depth))
        end
      when Hash
        kc = nil
        vc = nil
        nn = 0
        homog = true
        value.each do |hk, hv|
          kk = hk.class
          vv = hv.class
          if kk == Array || kk == Hash || kk == Set ||
             vv == Array || vv == Hash || vv == Set
            homog = false
            break
          end
          if nn.zero? then kc = kk; vc = vv
          elsif kk != kc || vv != vc then homog = false; break
          end
          nn += 1
          break if nn >= ELEMENT_SAMPLE
        end
        if homog
          kc ||= :empty
          mk = (@ctsk[:h] ||= {})
          mkc = (mk[kc] ||= {})
          k = mkc[vc]
          return k if k

          return (mkc[vc] = collection_type_shape_key_full(value, depth))
        end
      end
    end
    collection_type_shape_key_full(value, depth)
  end

  def self.collection_type_shape_key_full(value, depth = 3)
    # A sampled collection element may itself be a fixed-field record. Keep
    # that structural observation under the collection shape so FactMine's
    # generic callback projection sees the record at the block binding. This
    # is observation only: the Ruby collector never follows source flow or
    # assigns a call cost.
    record_shape = runtime_record_shape_key(value)
    return record_shape if record_shape

    return class_shape_key(value) unless depth.positive?
    case value
    when Array
      elements = value.first(ELEMENT_SAMPLE).map { |item| collection_type_shape_key(item, depth - 1) }.uniq.sort
      remember_shape("array:[#{elements.join(";")}]", { "kind" => "array", "elements" => elements.map { |key| shape_payload(key) } })
    when Hash
      key_shapes = []
      value_shapes = []
      value.first(ELEMENT_SAMPLE).each do |key, val|
        key_shapes << collection_type_shape_key(key, depth - 1)
        value_shapes << collection_type_shape_key(val, depth - 1)
      end
      key_shapes = key_shapes.uniq.sort
      value_shapes = value_shapes.uniq.sort
      remember_shape("hash:{#{key_shapes.join(";")}}:{#{value_shapes.join(";")}}",
        { "kind" => "hash",
          "keys" => key_shapes.map { |key| shape_payload(key) },
          "values" => value_shapes.map { |key| shape_payload(key) } })
    when Set
      elements = value.first(ELEMENT_SAMPLE).map { |item| collection_type_shape_key(item, depth - 1) }.uniq.sort
      remember_shape("set:[#{elements.join(";")}]", { "kind" => "set", "elements" => elements.map { |key| shape_payload(key) } })
    else
      class_shape_key(value)
    end
  end

  def self.collection_value?(value)
    value.is_a?(Array) || value.is_a?(Hash) || (defined?(Set) && value.is_a?(Set))
  end

  def self.nested_collection_shape(value)
    record_shape = runtime_record_shape_key(value)
    return record_shape if record_shape

    collection_type_shape_key(value) if collection_value?(value)
  end

  # Type-signature-memoized: the result is a pure function of the
  # sampled element classes and is only READ / merged-from by the
  # recorder. Cached Sets are frozen so a regression that tried to
  # mutate them fails loudly instead of corrupting the memo. Hetero /
  # nested / depth fall through to the unchanged full computation.
  def self.container_shape(value)
    case value
    when Array, Set
      c = homog_scalar_class(value)
      if c
        m = (@cshape[value.class] ||= {})
        cached = m[c]
        return cached if cached

        return (m[c] = freeze_shape(container_shape_full(value)))
      end
    when Hash
      kc = nil
      vc = nil
      nn = 0
      homog = true
      value.each do |hk, hv|
        kk = hk.class
        vv = hv.class
        if kk == Array || kk == Hash || kk == Set ||
           vv == Array || vv == Hash || vv == Set
          homog = false
          break
        end
        if nn.zero? then kc = kk; vc = vv
        elsif kk != kc || vv != vc then homog = false; break
        end
        nn += 1
        break if nn >= ELEMENT_SAMPLE
      end
      if homog
        kc ||= :empty
        mk = (@cshape[:h] ||= {})
        mkc = (mk[kc] ||= {})
        cached = mkc[vc]
        return cached if cached

        return (mkc[vc] = freeze_shape(container_shape_full(value)))
      end
    end
    container_shape_full(value)
  end

  # Freeze the Sets inside a memoized container_shape tuple (read-only
  # by the recorder; merge-from a frozen Set is allowed).
  def self.freeze_shape(shape)
    return shape unless shape

    case shape[0]
    when :array
      shape[1].freeze
      shape[2].freeze
    when :hash
      shape[1][0].freeze
      shape[1][1].freeze
      shape[2][0].freeze
      shape[2][1].freeze
    end
    shape.freeze
  end

  def self.container_shape_full(value)
    case value
    when Array, Set
      [:array, value.first(ELEMENT_SAMPLE).map { |item| class_name(item) }.to_set,
        value.first(ELEMENT_SAMPLE).filter_map { |item| nested_collection_shape(item) }.to_set]
    when Hash
      keys = Set.new
      vals = Set.new
      key_shapes = Set.new
      value_shapes = Set.new
      value.first(ELEMENT_SAMPLE).each do |key, val|
        keys << class_name(key)
        vals << class_name(val)
        key_shape = nested_collection_shape(key)
        value_shape = nested_collection_shape(val)
        key_shapes << key_shape if key_shape
        value_shapes << value_shape if value_shape
      end
      [:hash, [keys, vals], [key_shapes, value_shapes]]
    end
  end

  def self.with_collection_hooks_disabled
    # Already disabled (re-entrant -- the wrapped recorder paths nest):
    # set-true + restore is a no-op, so skip both TLS writes and the
    # ensure frame. The begin/ensure below runs ONLY on the slow path,
    # which is reached ONLY when the flag was falsy -> restoring to nil
    # is indistinguishable from the prior falsy for every truthiness
    # read. Mirrors with_collection_hook_guard's early-return idiom.
    return yield if Thread.current[:__nil_kill_collection_hook]

    begin
      Thread.current[:__nil_kill_collection_hook] = true
      yield
    ensure
      Thread.current[:__nil_kill_collection_hook] = nil
    end
  end

  def self.source_location_for_class(klass)
    return nil unless klass.respond_to?(:instance_method)
    init = klass.instance_method(:initialize) rescue nil
    loc = init&.source_location
    loc && [File.expand_path(loc[0], ROOT), loc[1]]
  end

  def self.method_owner(defined_class)
    return nil unless defined_class
    if defined_class.respond_to?(:singleton_class?) && defined_class.singleton_class?
      target = defined_class.respond_to?(:attached_object) ? (defined_class.attached_object rescue nil) : nil
      tn = safe_module_name(target)
      return [tn, "class"] if tn
      nil
    else
      dn = safe_module_name(defined_class)
      dn && [dn, "instance"]
    end
  end

  def self.site_key(loc, cls)
    return "#{loc}:#{cls}" unless loc.respond_to?(:absolute_path)
    "#{abs_path(loc.absolute_path || loc.path)}:#{loc.lineno}:#{cls}"
  end

  def self.trace_key(trace, cls)
    frames = Array(trace).filter_map do |loc|
      if loc.respond_to?(:absolute_path)
        path = loc.absolute_path || loc.path
        next unless path
        "#{abs_path(path)}:#{loc.lineno}"
      else
        loc.to_s
      end
    end
    return nil if frames.empty?
    "#{frames.join("|")}:#{cls}"
  end

  def self.install_struct_hook
    return if Struct.singleton_class.method_defined?(:__nil_kill_orig_new)
    Struct.singleton_class.alias_method(:__nil_kill_orig_new, :new)
    Struct.singleton_class.define_method(:new) do |*fields, **opts, &blk|
      loc = caller_locations(1, 1)&.first
      klass = __nil_kill_orig_new(*fields, **opts, &blk)
      path = loc && File.expand_path(loc.absolute_path || loc.path, ROOT)
      if path && klass.is_a?(Class) && klass < Struct &&
          (NilKillRuntimeTrace.target_path?(path) || ENV["NIL_KILL_RUNTIME_SCIP"] == "1")
        klass.instance_variable_set(:@__nil_kill_struct_path, path)
        klass.instance_variable_set(:@__nil_kill_struct_line, loc.lineno)
        NilKillRuntimeTrace.attach_struct(klass)
      end
      klass
    end
    register_runtime_scip_transparent_wrapper(
      Struct.singleton_class,
      :new,
      owner: "Struct",
      name: "new",
      kind: "class",
      native: true
    )

    Module.prepend(Module.new do
      def const_added(name)
        super
        # `const_added` also fires for `autoload`. Loading that constant from
        # inside the hook forces arbitrary files during require-time, which can
        # reorder unrelated namespaces (notably project AST vs the external
        # `ast` gem) and crash the traced process.
        return if autoload?(name, false)

        value = const_get(name, false)
        NilKillRuntimeTrace.attach_struct(value) if value.is_a?(Class) && value < Struct
        NilKillRuntimeTrace.attach_data(value) if defined?(Data) && value.is_a?(Class) && value < Data
      rescue NameError
        nil
      end
    end)
  end

  def self.install_data_hook
    return unless defined?(Data) && Data.respond_to?(:define)
    return if Data.singleton_class.method_defined?(:__nil_kill_orig_define)
    Data.singleton_class.alias_method(:__nil_kill_orig_define, :define)
    Data.singleton_class.define_method(:define) do |*fields, &blk|
      loc = caller_locations(1, 1)&.first
      klass = __nil_kill_orig_define(*fields, &blk)
      path = loc && File.expand_path(loc.absolute_path || loc.path, ROOT)
      if path && NilKillRuntimeTrace.target_path?(path) && klass.is_a?(Class)
        klass.instance_variable_set(:@__nil_kill_struct_path, path)
        klass.instance_variable_set(:@__nil_kill_struct_line, loc.lineno)
        NilKillRuntimeTrace.attach_data(klass)
      end
      klass
    end
    register_runtime_scip_transparent_wrapper(
      Data.singleton_class,
      :define,
      owner: "Data",
      name: "define",
      kind: "class",
      native: true
    )
  end

  def self.install_open_struct_hook
    require "ostruct"
    return if OpenStruct.instance_variable_get(:@__nil_kill_attached)
    OpenStruct.instance_variable_set(:@__nil_kill_attached, true)
    original_locations = %i[initialize []=].to_h do |method_id|
      [method_id, OpenStruct.instance_method(method_id).source_location]
    end
    wrapper = Module.new do
      define_method(:initialize) do |hash = nil|
        super(hash)
        NilKillRuntimeTrace.record_open_struct(self)
      end

      define_method(:[]=) do |name, value|
        result = super(name, value)
        NilKillRuntimeTrace.record_open_struct_field(self, name, value)
        result
      end
    end
    OpenStruct.prepend(wrapper)
    %i[initialize []=].each do |method_id|
      path, line = original_locations.fetch(method_id)
      register_runtime_scip_transparent_wrapper(
        wrapper,
        method_id,
        owner: "OpenStruct",
        name: method_id.to_s,
        kind: "instance",
        native: false,
        path: path,
        line: line
      )
    end
  rescue LoadError
    nil
  end

  def self.install_tstruct_hook
    return unless defined?(T::Struct)
    return if T::Struct.instance_variable_get(:@__nil_kill_attached)
    T::Struct.instance_variable_set(:@__nil_kill_attached, true)

    T::Struct.singleton_class.prepend(Module.new do
      def inherited(child)
        super
        loc = caller_locations(1, 1)&.first
        path = loc && File.expand_path(loc.absolute_path || loc.path, NilKillRuntimeTrace::ROOT)
        if path && NilKillRuntimeTrace.target_path?(path)
          child.instance_variable_set(:@__nil_kill_struct_path, path)
          child.instance_variable_set(:@__nil_kill_struct_line, loc.lineno)
          NilKillRuntimeTrace.attach_tstruct(child)
        end
      end
    end)
  end

  # Observe construction above #initialize, but only for T::Struct subclasses
  # declared in a target file. A global T::Struct.new wrapper charged every
  # typed object in the process for telemetry that record_tstruct_instance
  # immediately discarded because the class had no target source location.
  # The inherited hook runs for named and anonymous subclasses before their
  # first possible instance; prepending their singleton class remains robust
  # when Sorbet later synthesizes/replaces the instance initializer.
  def self.attach_tstruct(klass)
    return if klass.instance_variable_get(:@__nil_kill_tstruct_attached)

    klass.instance_variable_set(:@__nil_kill_tstruct_attached, true)
    fields = klass.respond_to?(:props) ? klass.props.keys.map(&:to_s) : []
    klass.instance_variable_set(:@__nil_kill_struct_fields, fields.freeze)
    klass.instance_variable_set(:@__nil_kill_record_family, "TStruct")
    wrapper = Module.new do
      def new(*args, **kw, &blk)
        instance = super
        NilKillRuntimeTrace.record_tstruct_instance(instance, kw)
        instance
      end
    end
    klass.singleton_class.prepend(wrapper)
    @runtime_generated_wrapper_methods << [wrapper, :new]
    register_runtime_scip_transparent_wrapper(
      wrapper,
      :new,
      owner: safe_module_name(klass),
      name: "new",
      kind: "class",
      native: false,
      path: klass.instance_variable_get(:@__nil_kill_struct_path),
      line: klass.instance_variable_get(:@__nil_kill_struct_line)
    )
    fields.each do |field|
      method_id = field.to_sym
      defined_class = klass.instance_method(method_id).owner
      register_runtime_scip_transparent_wrapper(
        defined_class,
        method_id,
        owner: safe_module_name(klass),
        name: field,
        kind: "instance",
        native: false,
        path: klass.instance_variable_get(:@__nil_kill_struct_path),
        line: klass.instance_variable_get(:@__nil_kill_struct_line)
      )
    rescue NameError
      next
    end
  end

  def self.record_tstruct_instance(instance, keyword_values = {})
    klass = instance.class
    class_name = safe_module_name(klass) || "AnonymousTStruct"
    if klass.respond_to?(:props)
      fields = sampled_tstruct_fields(klass, class_name)
      fields = klass.props.each_key unless fields
      fields.each do |field|
        value = instance.send(field) rescue nil
        record_struct_field(klass, class_name, field, value)
      end
    else
      keyword_values.each do |field, value|
        record_struct_field(klass, class_name, field, value)
      end
    end
  end

  # T::Struct props are fixed once instances can be constructed. Resolve the
  # trace-plan decision once per class instead of walking every known prop on
  # every allocation. nil means there is no valid plan and preserves the
  # exhaustive fallback; an empty array means the plan proved every prop.
  def self.sampled_tstruct_fields(klass, class_name)
    plan = trace_plan
    return nil unless plan
    return @sampled_tstruct_fields[klass] if @sampled_tstruct_fields.key?(klass)

    fields = klass.props.each_key.select { |field| sample_struct_field?(class_name, field) }.freeze
    ORIG_HASH_STORE.bind_call(@sampled_tstruct_fields, klass, fields)
    fields
  end

  # NOTE: the parallel instrumented tree and its require/require_relative
  # redirect (instrumented_copy_for / resolve_required_source /
  # install_instrumented_require_hook) were DELETED. In-place
  # instrumentation puts the single wrapped copy at the real src path,
  # so every load mechanism loads instrumented code with no redirect --
  # which is exactly what made collect_ran_untraced non-convergent.

  def self.attach_struct(klass)
    return unless klass.is_a?(Class) && klass < Struct
    if klass.instance_variable_get(:@__nil_kill_attached)
      register_generated_constructor_wrapper(klass, native: true)
      Array(klass.instance_variable_get(:@__nil_kill_struct_fields)).each do |field|
        register_runtime_scip_generated_record_wrapper(klass, field, kind: "instance")
        register_runtime_scip_generated_record_wrapper(
          klass,
          "#{field}=",
          kind: "instance"
        )
      end
      return
    end
    path = klass.instance_variable_get(:@__nil_kill_struct_path)
    line = klass.instance_variable_get(:@__nil_kill_struct_line)
    unless path && line
      loc = source_location_for_class(klass)
      path, line = loc if loc
      klass.instance_variable_set(:@__nil_kill_struct_path, path) if path
      klass.instance_variable_set(:@__nil_kill_struct_line, line) if line
    end
    production_struct = path && target_path?(path)
    return unless production_struct || ENV["NIL_KILL_RUNTIME_SCIP"] == "1"
    fields = klass.members
    return if fields.empty?
    klass.instance_variable_set(:@__nil_kill_struct_fields, fields.map(&:to_s).freeze)
    klass.instance_variable_set(:@__nil_kill_record_family, "Struct")
    klass.instance_variable_set(:@__nil_kill_attached, true)
    # Do not prepend #initialize. A Struct is often assigned to a constant and
    # reopened immediately with a Sorbet-signed initializer; Sorbet cannot
    # replace a method hidden behind a prepended module. Observing Class#new
    # captures the same initial values after construction without constraining
    # how the generated class may subsequently define its initializer.
    original_new = klass.method(:new)
    klass.define_singleton_method(:new) do |*args, **kw, &blk|
      instance = original_new.call(*args, **kw, &blk)
      NilKillRuntimeTrace.record_struct_instance(instance, fields) if production_struct
      instance
    end
    register_generated_constructor_wrapper(klass, native: true)

    if production_struct && klass.method_defined?(:[]=)
      original_index_set = klass.instance_method(:[]=)
      klass.define_method(:[]=) do |field, value|
        class_name = NilKillRuntimeTrace.safe_module_name(self.class) || "AnonymousStruct"
        field_sym = field.to_sym rescue nil
        if field_sym && fields.include?(field_sym)
          NilKillRuntimeTrace.record_struct_field(self.class, class_name, field_sym, value)
        end
        original_index_set.bind_call(self, field, value)
      end
    end

    fields.each do |field|
      if !klass.method_defined?(field) || klass.instance_method(field).source_location.nil?
        original_getter = klass.instance_method(field) if klass.method_defined?(field)
        klass.define_method(field, struct_field_getter(field, original_getter))
        @runtime_generated_wrapper_methods << [klass, field.to_sym]
        register_runtime_scip_generated_record_wrapper(klass, field, kind: "instance")
      end

      setter = "#{field}="
      if !klass.method_defined?(setter) || klass.instance_method(setter).source_location.nil?
        original_setter = klass.instance_method(setter) if klass.method_defined?(setter)
        klass.define_method(
          setter,
          struct_field_setter(field, original_setter, record_field: production_struct)
        )
        @runtime_generated_wrapper_methods << [klass, setter.to_sym]
        register_runtime_scip_generated_record_wrapper(klass, setter, kind: "instance")
      end
    end
  end

  def self.register_generated_constructor_wrapper(klass, native: true)
    register_runtime_scip_generated_record_wrapper(klass, :new, kind: "class")
  end

  def self.struct_field_getter(field, original_getter)
    proc do
      if original_getter
        original_getter.bind_call(self)
      else
        self[field]
      end
    end
  end

  def self.struct_field_setter(field, original_setter, record_field: true)
    proc do |value|
      if record_field
        class_name = NilKillRuntimeTrace.safe_module_name(self.class) || "AnonymousStruct"
        NilKillRuntimeTrace.record_struct_field(self.class, class_name, field, value)
      end
      if original_setter
        original_setter.bind_call(self, value)
      else
        self[field] = value
      end
    end
  end

  def self.record_struct_instance(instance, fields)
    class_name = safe_module_name(instance.class) || "AnonymousStruct"
    fields.each do |field|
      record_struct_field(instance.class, class_name, field, ORIG_STRUCT_FETCH.bind_call(instance, field))
    end
  end

  def self.attach_data(klass)
    return unless klass.is_a?(Class)
    if klass.instance_variable_get(:@__nil_kill_attached)
      register_generated_constructor_wrapper(klass, native: true)
      return
    end
    path = klass.instance_variable_get(:@__nil_kill_struct_path)
    line = klass.instance_variable_get(:@__nil_kill_struct_line)
    return unless path && line && target_path?(path)
    fields = klass.respond_to?(:members) ? klass.members : []
    return if fields.empty?
    klass.instance_variable_set(:@__nil_kill_struct_fields, fields.map(&:to_s).freeze)
    klass.instance_variable_set(:@__nil_kill_record_family, "Data")
    klass.instance_variable_set(:@__nil_kill_attached, true)
    original_new = klass.method(:new)
    klass.define_singleton_method(:new) do |*args, **kw, &blk|
      instance = original_new.call(*args, **kw, &blk)
      class_name = NilKillRuntimeTrace.safe_module_name(instance.class) || "AnonymousData"
      fields.each do |field|
        NilKillRuntimeTrace.record_struct_field(instance.class, class_name, field, instance.public_send(field))
      end
      instance
    end
    register_generated_constructor_wrapper(klass, native: true)
  end

  def self.record_open_struct(instance)
    table = instance.instance_variable_get(:@table) rescue nil
    return unless table.respond_to?(:each)
    table.each { |field, value| record_open_struct_field(instance, field, value) }
  end

  def self.record_open_struct_field(instance, field, value)
    loc = nil
    seen = 0
    Thread.each_caller_location do |c|
      seen += 1
      next if seen == 1
      break if seen > 21

      raw = c.absolute_path || c.path
      next unless raw && target_path?(raw)
      next if abs_path(raw) == SELF_ABS

      loc = c
      break
    end
    return unless loc
    singleton_name = NilKillRuntimeTrace.safe_module_name(instance.class)
    klass_name = singleton_name && singleton_name != "OpenStruct" ? singleton_name : "OpenStruct"
    shim = Object.new
    shim.instance_variable_set(:@__nil_kill_struct_path, File.expand_path(loc.absolute_path || loc.path, ROOT))
    shim.instance_variable_set(:@__nil_kill_struct_line, loc.lineno)
    record_struct_field(shim, klass_name, field, value)
  end

  # The collector owns the record tables; this is the one call the declaration
  # hooks make into them.
  def self.record_struct_field(klass, klass_name, field, value)
    NilKillTraceNative.record_struct_field(klass, klass_name, field, value)
  end

  def self.record_tuple(kind, path, line, slot, value)
    return unless value.is_a?(Array) && value.size >= 2
    sampled = value.first(ELEMENT_SAMPLE)
    types = sampled.map { |item| class_name(item) }
    complete = sampled.size == value.size
    mixed = types.uniq.size > 1
    return unless complete || mixed
    key = [kind, abs_path(path), line, slot.to_s, complete ? value.size : ">=#{ELEMENT_SAMPLE}", types]
    rec = (@tuples[key] ||= { calls: 0, complete: complete, mixed: mixed })
    rec[:calls] += 1
    rec[:complete] &&= complete
    rec[:mixed] ||= mixed
  end

  def self.dump
    FileUtils.mkdir_p(OUT_DIR)
    pid = Process.pid
    dump_native_runtime_scip(pid) if ENV["NIL_KILL_RUNTIME_SCIP"] == "1"
    File.open(File.join(OUT_DIR, "structs-#{pid}.jsonl"), "w") do |file|
      NilKillTraceNative.struct_observations.each { |row| file.puts JSON.generate(row) }
    end
    File.open(File.join(OUT_DIR, "ivars-#{pid}.jsonl"), "w") do |file|
      @ivar_runtime.each do |(klass, name), rec|
        file.puts JSON.generate(class: klass, name: name, calls: rec[:calls], classes: rec[:classes].to_a.sort)
      end
    end
    File.open(File.join(OUT_DIR, "state-values-#{pid}.jsonl"), "w") do |file|
      @runtime_state_values.each do |(path, line, klass, name), rec|
        file.puts JSON.generate(
          path: path,
          line: line,
          class: klass,
          name: name,
          calls: rec[:calls],
          classes: rec[:classes].to_a.sort
        )
      end
    end
    File.open(File.join(OUT_DIR, "tuples-#{pid}.jsonl"), "w") do |file|
      NilKillTraceNative.tuple_observations.each { |row| file.puts JSON.generate(row) }
    end
    File.open(File.join(OUT_DIR, "collections-#{pid}.jsonl"), "w") do |file|
      NilKillTraceNative.collection_observations.each do |row|
        file.puts JSON.generate(row.merge(
          mutation_sites: row.fetch(:mutation_sites)
            .sort_by { |site, count| [-count, site.to_s] }.to_h
        ))
      end
    end
    File.open(File.join(OUT_DIR, "tlets-#{pid}.jsonl"), "w") do |file|
      NilKillTraceNative.tlet_observations.each do |row|
        file.puts JSON.generate(
          path: row.fetch(:path), line: row.fetch(:line),
          calls: row.fetch(:calls), classes: row.fetch(:classes)
        )
      end
    end
    dump_coverage(pid)
  end

  # Ruby stdlib line coverage for THIS collect run. Lets the report
  # tell a real tracer miss (executed during collect but no nil-kill
  # record) from a workload-input gap (just not exercised here) --
  # instead of comparing against a stale aggregate SimpleCov.
  def self.start_coverage!
    # SCIP-only rapid feedback needs runtime value evidence, not Ruby's line
    # coverage. Opting out also lets a workload spawn an independent Coverage
    # session (for example, to create a branch-coverage fixture) without
    # colliding with this tracer's process-wide Coverage configuration.
    if ENV["NIL_KILL_COLLECT_COVERAGE"] == "0"
      @coverage_owned = false
      return
    end
    require "coverage"
    if Coverage.respond_to?(:running?) && Coverage.running?
      @coverage_owned = ENV["NIL_KILL_SHARED_COVERAGE"] == "1"
      return
    end
    # Nil-Kill needs reachability, not execution-frequency counters. Ruby's
    # oneshot mode records each executed line once and then stops charging hot
    # lines; this preserves the collect-ran and loop-reached invariants without
    # turning tight loops into global counter-update hot paths.
    Coverage.start(oneshot_lines: true)
    @coverage_owned = true
  rescue StandardError, LoadError
    @coverage_owned = false
  end

  # Root-relative form of a raw trace path. A pure function of the string that
  # every :line event needs, so it is cached alongside @path_cache. Building
  # two Pathnames per line event dominated collection wall time.
  def self.rel_path(path)
    raw = path.to_s
    return @rel_cache[raw] if @rel_cache.key?(raw)

    @rel_cache[raw] = begin
      Pathname.new(abs_path(raw)).relative_path_from(Pathname.new(ROOT)).to_s
    rescue StandardError
      nil
    end
  end

  def self.dump_coverage(pid)
    return unless @coverage_owned
    require "coverage"
    require "pathname"
    result = Coverage.result(stop: false, clear: false)
    covered_by_path = {}
    File.open(File.join(OUT_DIR, "coverage-#{pid}.jsonl"), "w") do |file|
      result.each do |abs, data|
        next unless target_path?(abs)
        src = abs_path(abs)
        rel = Pathname.new(src).relative_path_from(Pathname.new(ROOT)).to_s rescue src
        # Native collection uses { oneshot_lines: [line, ...] }. A shared
        # SimpleCov session may already be running in counted-lines mode, so
        # retain compatibility with { lines: [nil, count, ...] } and plain
        # arrays rather than restarting or weakening that external session.
        oneshot = data.is_a?(Hash) ? (data[:oneshot_lines] || data["oneshot_lines"]) : nil
        lines = data.is_a?(Hash) ? (data[:lines] || data["lines"]) : data
        # Source is executed as written, so a coverage line IS a source line.
        covered = []
        if oneshot
          Array(oneshot).each do |line|
            covered << line if line
          end
        else
          Array(lines).each_with_index do |hits, i|
            next unless hits && hits.to_i.positive?
            covered << i + 1
          end
        end
        covered = covered.uniq.sort
        next if covered.empty?
        covered_by_path[src] = covered.to_set
        file.puts JSON.generate(path: src, lines: covered)
      end
    end
    File.open(File.join(OUT_DIR, "loops-#{pid}.jsonl"), "w") do |file|
      Hash(trace_plan&.fetch("loop_sites", {})).each_key do |raw_key|
        path, line = raw_key.split("\0", 2)
        line = line.to_i
        next unless covered_by_path[path]&.include?(line)

        # Espalier consumes loop evidence as a reached/not-reached predicate;
        # it does not use iteration magnitude. Ruby line coverage supplies
        # that fact without charging every loop evaluation a Ruby hash update.
        file.puts JSON.generate(path: path, line: line, count: 1)
      end
    end
  rescue StandardError
    nil
  end
end

require_relative "languages/providers/ruby/runtime_scip_trace"
require_relative "languages/providers/ruby/runtime_scip_native"

if ENV["NIL_KILL_TRACE"] == "1"
  NilKillRuntimeTrace.start_coverage!
  # The collector owns every per-event observation and the declaration hooks
  # that are already native, so it is loaded whether or not runtime SCIP is on.
  NilKillRuntimeTrace.require_native_scip!
  NilKillRuntimeTrace.install_native_runtime_scip_trace if ENV["NIL_KILL_RUNTIME_SCIP"] == "1"
  begin
    require "sorbet-runtime"
  rescue LoadError
    nil
  end
  NilKillTraceNative.configure_struct_fields(Hash(NilKillRuntimeTrace.trace_plan&.fetch("struct_fields", nil)))
  NilKillTraceNative.configure_tlet_sites(Hash(NilKillRuntimeTrace.trace_plan&.fetch("tlets", nil)))
  NilKillTraceNative.install_tlet_hook
  NilKillRuntimeTrace.install_struct_hook
  NilKillRuntimeTrace.install_data_hook
  NilKillRuntimeTrace.install_open_struct_hook
  NilKillRuntimeTrace.install_tstruct_hook
  NilKillTraceNative.install_collection_hook unless ENV["NIL_KILL_TRACE_COLLECTIONS"] == "0"
  # Sorbet may be required after the collector starts, so `T` is looked for
  # again whenever a class or module body finishes.
  TracePoint.new(:end) { NilKillTraceNative.install_tlet_hook }.enable
  TracePoint.new(:end) do
    NilKillRuntimeTrace.install_data_hook
  end.enable
  at_exit do
    NilKillRuntimeTrace.dump
  end
end
