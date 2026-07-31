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

  @ivar_runtime = {}
  @runtime_state_values = {}
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

  # NOTE: the parallel instrumented tree and its require/require_relative
  # redirect (instrumented_copy_for / resolve_required_source /
  # install_instrumented_require_hook) were DELETED. In-place
  # instrumentation puts the single wrapped copy at the real src path,
  # so every load mechanism loads instrumented code with no redirect --
  # which is exactly what made collect_ran_untraced non-convergent.

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
  NilKillTraceNative.configure_targets(Array(NilKillRuntimeTrace::TARGETS).map(&:to_s))
  NilKillRuntimeTrace.install_native_runtime_scip_trace if ENV["NIL_KILL_RUNTIME_SCIP"] == "1"
  begin
    require "sorbet-runtime"
  rescue LoadError
    nil
  end
  NilKillTraceNative.configure_struct_fields(Hash(NilKillRuntimeTrace.trace_plan&.fetch("struct_fields", nil)))
  NilKillTraceNative.configure_tlet_sites(Hash(NilKillRuntimeTrace.trace_plan&.fetch("tlets", nil)))
  NilKillTraceNative.install_tlet_hook
  NilKillTraceNative.install_record_hooks
  NilKillRuntimeTrace.install_open_struct_hook
  NilKillTraceNative.install_tstruct_hook
  NilKillTraceNative.install_collection_hook unless ENV["NIL_KILL_TRACE_COLLECTIONS"] == "0"
  # Sorbet may be required after the collector starts, so `T` is looked for
  # again whenever a class or module body finishes.
  TracePoint.new(:end) { NilKillTraceNative.install_tlet_hook }.enable
  at_exit do
    NilKillRuntimeTrace.dump
  end
end
