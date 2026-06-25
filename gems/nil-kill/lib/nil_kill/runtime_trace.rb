# typed: false
# frozen_string_literal: true

require "fileutils"
require "json"
require "pathname"
require "set"

module NilKillRuntimeTrace
  ROOT = File.expand_path("../../../..", __dir__)
  OUT_DIR = File.expand_path(File.join(ENV.fetch("NIL_KILL_TMP_DIR", File.join(ROOT, "tmp", "nil-kill")), "runtime"), ROOT)
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

  @methods = {}
  @tlets = {}
  @structs = {}
  @ivar_runtime = {}
  @tuples = {}
  @collections = {}
  @method_edges = {}
  @objects = {}
  @object_tokens = {}
  # Mutation coalescing: a tight loop mutating ONE object at ONE site
  # with ONE element-class fires record_collection_mutation N times,
  # all producing the SAME observation. Defer them into a single
  # pending batch + count; flush (one core call/owner, count: N) on
  # any discriminator change or at dump. Byte-identical: every effect
  # is an additive count or an idempotent merge, so N x count:1 ==
  # 1 x count:N. NIL_KILL_COALESCE=0 restores the exact per-mutation
  # path (the differential-proof baseline).
  @coalesce = ENV["NIL_KILL_COALESCE"] != "0"
  @pending_mut = nil
  @frames = Hash.new { |h, k| h[k] = [] }
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
  # Per-(path,line) memo of the constant-per-callsite context (abs,
  # plan, bucket, site prefix, method-id string). The wrapper injects
  # owner/method_id/kind/__FILE__/line as LITERALS, so all of this is
  # invariant for a given instrumented def -- recomputing+allocating
  # it every call was the dominant collect cost (array key + to_s +
  # plan lookup + abs interpolation, x call/return/raise). Bucket
  # identity stays anchored in @methods[key], so concurrent first-
  # calls still converge on one bucket (no behaviour change).
  @site_ctx = {}
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
  @sym_s = Hash.new { |h, k| h[k] = (k.is_a?(String) ? k : k.to_s).freeze }
  @method_metadata = {}
  @planned_methods_by_class = nil
  @targeted_tracepoints = []
  @targeted_tracepoint_keys = Set.new
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
  rescue JSON::ParserError
    @trace_plan = nil
  end

  def self.planned_methods_by_class
    return @planned_methods_by_class if @planned_methods_by_class
    plan = trace_plan
    return nil unless plan
    methods =
      if ENV["NIL_KILL_TRACE_METHODS"] == "0"
        plan.fetch("tracepoint_methods", {})
      else
        fallback = plan.fetch("tracepoint_methods", {})
        fallback.empty? ? plan.fetch("methods", {}) : fallback
      end
    return nil if methods.empty?
    index = Hash.new { |h, k| h[k] = [] }
    methods.each do |raw_key, method_plan|
      owner, method_id, kind, path, line = raw_key.split("\0", 5)
      next if method_plan && method_plan["sample"] == false && method_plan["frame"] == false
      index[owner] << {
        owner: owner,
        method_id: method_id,
        kind: kind,
        path: path,
        line: line.to_i,
        params: method_plan.fetch("params", {}),
        return: method_plan["return"] != false,
        sample: method_plan["sample"] != false,
        frame: method_plan["frame"] != false,
      }
    end
    @planned_methods_by_class = index
  end

  def self.targeted_method_tracing?
    planned_methods_by_class
  end

  def self.install_targeted_method_traces(klass)
    index = planned_methods_by_class
    return unless index && klass.is_a?(Module)
    klass_name = safe_module_name(klass)
    return unless klass_name.is_a?(String)
    Array(index[klass_name]).each do |entry|
      target =
        if entry[:kind] == "class"
          klass.method(entry[:method_id]) rescue nil
        else
          klass.instance_method(entry[:method_id]) rescue nil
        end
      next unless target
      trace_key = [klass_name, entry[:kind], entry[:method_id], target.object_id]
      next unless @targeted_tracepoint_keys.add?(trace_key)
      sample_params = entry[:sample] && entry[:params].values.any?
      sample_return = entry[:sample] && entry[:return]
      frame_method = entry[:frame]
      @targeted_tracepoints << TracePoint.new(:call) { |tp| record_call(tp, forced_entry: entry) }.enable(target: target) if sample_params || frame_method
      @targeted_tracepoints << TracePoint.new(:return) { |tp| record_return(tp, forced_entry: entry) }.enable(target: target) if sample_return || frame_method
    end
  end

  def self.install_targeted_definition_trace
    trace = TracePoint.new(:end) do |tp|
      install_targeted_method_traces(tp.self)
    end
    @targeted_tracepoints << trace
    trace.enable
  end

  def self.method_plan(owner, method_id, kind, path, line)
    plan = trace_plan
    return nil unless plan
    plan.dig("methods", [owner, method_id.to_s, kind, abs_path(path), line].join("\0"))
  end

  def self.sample_param?(plan, name)
    return true unless plan
    plan.dig("params", name.to_s) != false
  end

  def self.sample_return?(plan)
    return true unless plan
    plan["return"] != false
  end

  def self.sample_tlet?(path, line)
    plan = trace_plan
    return true unless plan
    plan.dig("tlets", [abs_path(path), line].join("\0")) == true
  end

  def self.sample_struct_field?(klass_name, field)
    plan = trace_plan
    return true unless plan
    short = klass_name.to_s.split("::").last
    plan.dig("struct_fields", [klass_name.to_s, field.to_s].join("\0")) == true ||
      plan.dig("struct_fields", [short, field.to_s].join("\0")) == true
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

  # Memoized constant-per-callsite context, or false if `path` is not
  # a target (negative cached too). Anchors bucket on @methods[key]
  # via method_bucket so racing first-calls still share one bucket.
  def self.site_ctx(owner, method_id, kind, path, line)
    by_line = (@site_ctx[path.to_s] ||= {})
    c = by_line[line]
    return c unless c.nil?

    abs = abs_path(path)
    return (by_line[line] = false) unless target_path?(abs)

    ms = @sym_s[method_id]
    key = [owner, ms, kind, abs, line]
    plan = source_method_plan(owner, method_id, kind, abs, line)
    sample_method = plan.nil? || plan["sample"] != false
    frame_method = plan.nil? || plan["frame"] != false
    by_line[line] = { abs: abs, method_s: ms, kind: kind, owner: owner, line: line,
                      key: [owner, kind, ms, abs, line], method_key: key, plan: plan,
                      sample_method: sample_method, frame_method: frame_method,
                      bucket: (sample_method || frame_method) ? method_bucket(key, plan) : nil,
                      prefix: "#{abs}:#{line}" }
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

  # The finalizer MUST be built in a separate method so its closure
  # captures ONLY scalars/tokens and the module -- never `value`
  # (capturing value would pin it alive forever, the finalizer would
  # never run, and the leak would be reinstated). Ruby can reuse an
  # object_id before a stale finalizer runs, so deletion is generation
  # checked instead of keyed by object_id alone.
  def self.objects_finalizer(oid, token)
    proc do
      next unless @object_tokens[oid].equal?(token)
      @object_tokens.delete(oid)
      @objects.delete(oid)
    end
  end

  def self.register_collection_owner(value, owner)
    return unless value.is_a?(Array) || value.is_a?(Hash) || (defined?(Set) && value.is_a?(Set))

    if value.frozen?
      record_collection_snapshot(value, owner)
      return
    end

    oid = value.object_id
    owners = @objects[oid]
    unless owners
      # @objects is keyed by object_id and was NEVER evicted -> every
      # transient collection leaked an entry forever, and GC then
      # marked a monotonically growing live graph each cycle (the
      # collect end-to-end ceiling, and a real unbounded-memory bug).
      # ObjectSpace::WeakMap is unusable here: Ruby 3.2 holds WeakMap
      # VALUES weakly, so the owners hash would vanish for LIVE
      # collections -> lost mutation attribution. Instead evict via a
      # finalizer when the collection is GC'd: a GC'd collection can
      # never be mutated again, so no recorded mutation is ever lost
      # and downstream output is byte-identical. The 13 mutation-hook
      # read sites + record_collection_mutation keep object_id keys
      # unchanged.
      owners = {}
      token = Object.new
      @object_tokens[oid] = token
      @objects[oid] = owners
      ObjectSpace.define_finalizer(value, objects_finalizer(oid, token))
      # Mutation-gate marker. The collection-mutation hooks fire on
      # EVERY Array/Hash/Set mutation in the WHOLE process; the old
      # gate paid Kernel#object_id + an @objects hash lookup on each
      # one just to discover "not registered, ignore." Relevance is
      # known HERE (registration). Stamp the object so the hook
      # fast-path is one ivar read. Marker present <=> @objects entry
      # present for every live non-frozen registered object (both set
      # here, both die with the object; the finalizer only deletes
      # @objects when the object -- and its ivar -- are already gone).
      value.instance_variable_set(:@__nil_kill_traced, true)
    end
    owners[owner_identity_key(owner)] ||= owner
    record_collection_snapshot(value, owner)
  end

  def self.owner_identity_key(owner)
    [owner[:owner_kind].to_s, owner[:name].to_s, abs_path(owner[:path]), owner[:line]]
  end

  def self.collection_kind(value)
    if value.is_a?(Hash)
      "hash"
    elsif defined?(Set) && value.is_a?(Set)
      "set"
    else
      "array"
    end
  end

  def self.collection_key(value, owner)
    collection_key_for(collection_kind(value), owner)
  end

  def self.collection_key_for(kind, owner)
    [owner[:owner_kind].to_s, owner[:name].to_s, abs_path(owner[:path]), owner[:line], kind]
  end

  def self.record_collection_snapshot(value, owner)
    shape = container_shape(value)
    return unless shape
    if shape[0] == :array
      record_collection_observation(value, owner, elem_classes: shape[1], elem_shapes: shape[2])
    else
      record_collection_observation(value, owner, key_classes: shape[1][0], value_classes: shape[1][1], key_shapes: shape[2][0], value_shapes: shape[2][1])
    end
  end

  def self.record_collection_observation(value, owner, elem_classes: [], key_classes: [], value_classes: [], elem_shapes: [], key_shapes: [], value_shapes: [], mutation_site: nil)
    record_collection_observation_core(class_name(value), collection_kind(value), owner,
      elem_classes: elem_classes, key_classes: key_classes, value_classes: value_classes,
      elem_shapes: elem_shapes, key_shapes: key_shapes, value_shapes: value_shapes, mutation_site: mutation_site)
  end

  # cname/kind are the derived CLASS strings -- never the object. The
  # coalescer stores THESE (never `value`/`elem`), so a pending batch
  # cannot pin a workload object alive (no GC-leak hazard). `count`
  # multiplies the additive effects (calls, mutation_sites); the set
  # merges are idempotent so they run once regardless -> coalescing N
  # identical mutations into one core call with count: N is exactly
  # byte-identical to N separate count: 1 calls.
  def self.record_collection_observation_core(cname, kind, owner, count: 1, elem_classes: [], key_classes: [], value_classes: [], elem_shapes: [], key_shapes: [], value_shapes: [], mutation_site: nil)
    with_collection_hooks_disabled do
      path = owner[:path]
      line = owner[:line]
      return unless path && line
      key = collection_key_for(kind, owner)
      rec = (@collections[key] ||= { calls: 0, classes: NKSet.new, elem_classes: NKSet.new, key_classes: NKSet.new, value_classes: NKSet.new,
                                      elem_shapes: NKSet.new, key_shapes: NKSet.new, value_shapes: NKSet.new, mutation_sites: NKTally.new })
      rec[:calls] += count
      rec[:classes] << cname
      rec[:elem_classes].merge(elem_classes)
      rec[:key_classes].merge(key_classes)
      rec[:value_classes].merge(value_classes)
      rec[:elem_shapes].merge(elem_shapes)
      rec[:key_shapes].merge(key_shapes)
      rec[:value_shapes].merge(value_shapes)
      rec[:mutation_sites][mutation_site] += count if mutation_site
      bucket = owner[:bucket]
      if bucket
        case owner[:owner_kind].to_s
        when "method_param"
          if kind == "hash"
            bucket[:param_kv][owner[:name]][0].merge(key_classes)
            bucket[:param_kv][owner[:name]][1].merge(value_classes)
            bucket[:param_kv_shapes][owner[:name]][0].merge(key_shapes)
            bucket[:param_kv_shapes][owner[:name]][1].merge(value_shapes)
          else
            bucket[:param_elem][owner[:name]].merge(elem_classes)
            bucket[:param_elem_shapes][owner[:name]].merge(elem_shapes)
          end
        when "method_return"
          if kind == "hash"
            bucket[:return_kv][0].merge(key_classes)
            bucket[:return_kv][1].merge(value_classes)
            bucket[:return_kv_shapes][0].merge(key_shapes)
            bucket[:return_kv_shapes][1].merge(value_shapes)
          else
            bucket[:return_elem].merge(elem_classes)
            bucket[:return_elem_shapes].merge(elem_shapes)
          end
        end
      end
    end
  end

  def self.record_collection_mutation(value, elem: :__nil_kill_missing, key: :__nil_kill_missing, val: :__nil_kill_missing)
    owners_by_key = @objects[value.object_id]
    owners = owners_by_key&.values
    return if owners.nil? || owners.empty?
    elem_classes = []
    key_classes = []
    value_classes = []
    elem_shapes = []
    key_shapes = []
    value_shapes = []
    elem_classes << class_name(elem) unless elem == :__nil_kill_missing
    key_classes << class_name(key) unless key == :__nil_kill_missing
    value_classes << class_name(val) unless val == :__nil_kill_missing
    elem_shape = nested_collection_shape(elem) unless elem == :__nil_kill_missing
    key_shape = nested_collection_shape(key) unless key == :__nil_kill_missing
    value_shape = nested_collection_shape(val) unless val == :__nil_kill_missing
    elem_shapes << elem_shape if elem_shape
    key_shapes << key_shape if key_shape
    value_shapes << value_shape if value_shape
    mutation_site = collection_mutation_site
    unless @coalesce
      @lock.synchronize do
        owners.each do |owner|
          record_collection_observation(value, owner, elem_classes: elem_classes, key_classes: key_classes, value_classes: value_classes,
            elem_shapes: elem_shapes, key_shapes: key_shapes, value_shapes: value_shapes, mutation_site: mutation_site)
        end
      end
      return
    end

    # Derived CLASS strings only -- never `value`/`elem` (no GC pin).
    cname = class_name(value)
    kind = collection_kind(value)
    @lock.synchronize do
      p = @pending_mut
      if p && p[:obk].equal?(owners_by_key) && p[:olen] == owners_by_key.size &&
         p[:site] == mutation_site && p[:ec] == elem_classes && p[:kc] == key_classes &&
         p[:vc] == value_classes && p[:es] == elem_shapes && p[:ks] == key_shapes && p[:vs] == value_shapes
        # Same object-registration, owner-set, site and element-class
        # signature as the pending batch -> identical observation; just
        # bump the count.
        p[:count] += 1
      else
        # Discriminator changed (incl. a different object -- the common
        # interleave -- or owner-set growth): the old batch is complete.
        flush_pending_locked!(p) if p
        @pending_mut = { obk: owners_by_key, olen: owners_by_key.size, owners: owners,
                         cname: cname, kind: kind, site: mutation_site,
                         ec: elem_classes, kc: key_classes, vc: value_classes,
                         es: elem_shapes, ks: key_shapes, vs: value_shapes, count: 1 }
      end
    end
  end

  # Flush ONE coalesced batch. @lock MUST already be held. Replays it
  # as a single core call per owner with count == the coalesced total;
  # byte-identical to `count` separate observations (additive counts,
  # idempotent merges). Iterates the owner SNAPSHOT taken at batch
  # start -- valid because owner-set growth ends the batch.
  def self.flush_pending_locked!(pending)
    pending[:owners].each do |owner|
      record_collection_observation_core(pending[:cname], pending[:kind], owner, count: pending[:count],
        elem_classes: pending[:ec], key_classes: pending[:kc], value_classes: pending[:vc],
        elem_shapes: pending[:es], key_shapes: pending[:ks], value_shapes: pending[:vs], mutation_site: pending[:site])
    end
  end

  # Flush the outstanding batch. MUST run before dump reads
  # @collections (the counts/sites are otherwise still pending). Timing
  # is otherwise irrelevant -- every effect is additive or idempotent.
  def self.flush_pending_mutations!
    @lock.synchronize do
      pending = @pending_mut
      @pending_mut = nil
      flush_pending_locked!(pending) if pending
    end
  end

  # Was caller_locations(2, 20) -- a 20-frame backtrace ALLOCATION on
  # every collection mutation of a registered collection (microseconds
  # x per-mutation = the hot-loop killer). Thread.each_caller_location
  # is lazy + early-exits at the first match and allocates nothing.
  # Byte-identical: same predicate, same skip-1 offset (the +1 frame is
  # this gem's own, excluded by SELF_ABS anyway) and same 20-frame
  # window cap (indices 2..21), so a match deeper than the original
  # window still yields nil exactly as before.
  def self.collection_mutation_site
    seen = 0
    Thread.each_caller_location do |c|
      seen += 1
      next if seen == 1
      return nil if seen > 21

      raw = c.absolute_path || c.path
      next unless raw && target_path?(raw)

      a = abs_path(raw)
      next if a == SELF_ABS

      return "#{a}:#{c.lineno}"
    end
    nil
  end

  def self.with_collection_hook_guard
    previous = Thread.current[:__nil_kill_collection_hook]
    return if previous
    Thread.current[:__nil_kill_collection_hook] = true
    yield
  ensure
    Thread.current[:__nil_kill_collection_hook] = previous
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

  def self.bucket(tp)
    meta = method_metadata(tp)
    return nil unless meta && meta[:target]
    bucket_for_meta(meta)
  end

  def self.method_metadata(tp, known_target: false)
    defined_class = tp.defined_class
    class_key = defined_class&.object_id || 0
    by_class = (@method_metadata[class_key] ||= {})
    by_method = (by_class[tp.method_id] ||= {})
    by_path = (by_method[tp.path] ||= {})
    cached = by_path[tp.lineno]
    return cached if cached

    path = abs_path(tp.path)
    target = known_target || target_path?(path)
    owner = target ? method_owner(defined_class) : nil
    method_id = tp.method_id.to_s
    plan = owner && target ? method_plan(owner[0], tp.method_id, owner[1], path, tp.lineno) : nil
    sample_method = plan.nil? || plan["sample"] != false
    frame_method = target && (plan.nil? || plan["frame"] != false)
    params = target ? (tp.parameters rescue nil) : nil
    by_path[tp.lineno] = {
      target: target,
      owner: owner,
      method_id: method_id,
      path: path,
      line: tp.lineno,
      key: owner && [owner, method_id, path],
      bucket_key: owner && [owner[0], method_id, owner[1], path, tp.lineno],
      method_key: owner && [owner[0], method_id, owner[1], path, tp.lineno],
      method_site: "#{path}:#{tp.lineno}",
      plan: plan,
      sample_method: sample_method,
      frame_method: frame_method,
      params: params,
    }
  end

  def self.forced_method_metadata(tp, entry)
    plan = {
      "sample" => entry[:sample],
      "params" => entry[:params],
      "return" => entry[:return],
      "frame" => entry[:frame],
    }
    path = abs_path(entry[:path])
    params = entry[:params].keys.map { |name| [:req, name.to_sym] }
    sample_method = entry[:sample] != false
    {
      target: true,
      owner: [entry[:owner], entry[:kind]],
      method_id: entry[:method_id].to_s,
      path: path,
      line: entry[:line],
      key: [[entry[:owner], entry[:kind]], entry[:method_id].to_s, path],
      bucket_key: [entry[:owner], entry[:method_id].to_s, entry[:kind], path, entry[:line]],
      method_key: [entry[:owner], entry[:method_id].to_s, entry[:kind], path, entry[:line]],
      method_site: "#{path}:#{entry[:line]}",
      plan: plan,
      sample_method: sample_method,
      frame_method: entry[:frame] != false,
      params: params,
      forced_values: forced_param_values(tp, entry),
    }
  end

  def self.forced_param_values(tp, entry)
    values = {}
    args = tp.binding.local_variable_get(:args) rescue nil
    return values unless args.is_a?(Array)
    entry[:params].keys.each_with_index do |name, index|
      values[name.to_s] = args[index] if index < args.length
    end
    values
  end

  def self.bucket_for_meta(meta)
    return nil unless meta[:owner]
    key = meta[:bucket_key]
    method_bucket(key, meta[:plan])
  end

  def self.method_bucket(key, plan = nil)
    @methods[key] ||= {
      calls: 0,
      ok_calls: 0,
      raised_calls: 0,
      params_by_name: Hash.new { |h, k| h[k] = NKSet.new },
      params_ok: Hash.new { |h, k| h[k] = NKSet.new },
      params_raised: Hash.new { |h, k| h[k] = NKSet.new },
      param_sites: Hash.new { |h, k| h[k] = NKTally.new },
      param_sites_ok: Hash.new { |h, k| h[k] = NKTally.new },
      param_sites_raised: Hash.new { |h, k| h[k] = NKTally.new },
      param_traces: Hash.new { |h, k| h[k] = NKTally.new },
      param_traces_ok: Hash.new { |h, k| h[k] = NKTally.new },
      param_traces_raised: Hash.new { |h, k| h[k] = NKTally.new },
      param_elem: Hash.new { |h, k| h[k] = NKSet.new },
      param_kv: Hash.new { |h, k| h[k] = [NKSet.new, NKSet.new] },
      param_elem_shapes: Hash.new { |h, k| h[k] = NKSet.new },
      param_kv_shapes: Hash.new { |h, k| h[k] = [NKSet.new, NKSet.new] },
      returns: NKSet.new,
      return_elem: NKSet.new,
      return_kv: [NKSet.new, NKSet.new],
      return_elem_shapes: NKSet.new,
      return_kv_shapes: [NKSet.new, NKSet.new],
      raised: NKSet.new,
      plan: plan,
    }
  end

  def self.method_edge_record(caller_key, callee_key)
    @method_edges[[caller_key, callee_key]] ||= { calls: 0, ok_calls: 0, raised_calls: 0 }
  end

  def self.record_method_edge_entry(frame, stack)
    caller = stack.last
    return unless caller && caller[:method_key] && frame[:method_key]

    edge_key = [caller[:method_key], frame[:method_key]]
    method_edge_record(edge_key[0], edge_key[1])[:calls] += 1
    frame[:edge_key] = edge_key
  end

  def self.record_method_edge_outcome(frame, outcome)
    edge_key = frame && frame[:edge_key]
    return unless edge_key

    rec = method_edge_record(edge_key[0], edge_key[1])
    outcome == :raised ? rec[:raised_calls] += 1 : rec[:ok_calls] += 1
  end

  def self.source_method_frame(ctx)
    {
      key: ctx[:key],
      method_key: ctx[:method_key],
      bucket: ctx[:bucket],
      sample_method: ctx[:sample_method],
      plan: ctx[:plan],
      method_site: ctx[:prefix],
      edge_key: nil,
    }
  end

  def self.source_method_plan(owner, method_id, kind, path, line)
    method_plan(owner, method_id, kind, path, line)
  end

  def self.record_source_method_call(owner, method_id, kind, path, line, params)
    return if Thread.current[:__nil_kill_collection_hook]
    ctx = site_ctx(owner, method_id, kind, path, line)
    return unless ctx

    abs = ctx[:abs]
    plan = ctx[:plan]
    b = ctx[:bucket]
    frame = source_method_frame(ctx)
    with_collection_hooks_disabled do
      @lock.synchronize do
        stack = @frames[Thread.current.object_id]
        record_method_edge_entry(frame, stack)
        stack << frame if ctx[:frame_method]
        b[:calls] += 1 if b
        next unless ctx[:sample_method]

        params.each do |name, value|
          next unless sample_param?(plan, name)
          cls = class_name(value)
          name = @sym_s[name]
          b[:params_by_name][name] << cls
          b[:param_sites][name]["#{ctx[:prefix]}:#{cls}"] += 1
          shape = container_shape(value)
          if shape
            if shape[0] == :array
              b[:param_elem][name].merge(shape[1])
              b[:param_elem_shapes][name].merge(shape[2])
              record_tuple("param", abs, line, name, value)
            else
              b[:param_kv][name][0].merge(shape[1][0])
              b[:param_kv][name][1].merge(shape[1][1])
              b[:param_kv_shapes][name][0].merge(shape[2][0])
              b[:param_kv_shapes][name][1].merge(shape[2][1])
            end
            register_collection_owner(value, owner_kind: "method_param", name: name, path: abs, line: line, bucket: b)
          end
        end
      end
    end
    nil
  end

  def self.record_source_method_return(owner, method_id, kind, path, line, value)
    return value if Thread.current[:__nil_kill_collection_hook]

    ctx = site_ctx(owner, method_id, kind, path, line)
    return value unless ctx

    abs = ctx[:abs]
    b = ctx[:bucket]
    with_collection_hooks_disabled do
      @lock.synchronize do
        frame = pop_frame_for_key(ctx[:key])
        record_method_edge_outcome(frame, :ok)
        return value if ctx[:frame_method] && frame.nil?
        b[:ok_calls] += 1 if b
        return value unless ctx[:sample_method] && sample_return?(ctx[:plan])

        b[:returns] << class_name(value)
        shape = container_shape(value)
        if shape
          if shape[0] == :array
            b[:return_elem].merge(shape[1])
            b[:return_elem_shapes].merge(shape[2])
            record_tuple("return", abs, line, ctx[:method_s], value)
          else
            b[:return_kv][0].merge(shape[1][0])
            b[:return_kv][1].merge(shape[1][1])
            b[:return_kv_shapes][0].merge(shape[2][0])
            b[:return_kv_shapes][1].merge(shape[2][1])
          end
          register_collection_owner(value, owner_kind: "method_return", name: ctx[:method_s], path: abs, line: line, bucket: b)
        end
      end
    end
    value
  end

  def self.record_source_method_raise(owner, method_id, kind, path, line, error)
    return if Thread.current[:__nil_kill_collection_hook]

    ctx = site_ctx(owner, method_id, kind, path, line)
    return unless ctx

    b = ctx[:bucket]
    @lock.synchronize do
      frame = pop_frame_for_key(ctx[:key])
      record_method_edge_outcome(frame, :raised)
      return if ctx[:frame_method] && frame.nil?
      return unless b

      b[:raised_calls] += 1
      b[:raised] << class_name(error)
    end
    nil
  end

  def self.record_call(tp, forced_entry: nil)
    return if Thread.current[:__nil_kill_collection_hook]
    return unless forced_entry || target_path?(tp.path)
    with_collection_hooks_disabled do
      meta = forced_entry ? forced_method_metadata(tp, forced_entry) : method_metadata(tp, known_target: true)
      return unless meta
      params = meta[:params]
      return unless params
      method_plan = meta[:plan]
      sample_method = meta[:sample_method]
      b = (sample_method || meta[:frame_method]) ? bucket_for_meta(meta) : nil
      binding = tp.binding
      frame = {
        key: meta[:key],
        method_key: meta[:method_key],
        bucket: b,
        sample_method: sample_method,
        frame_method: meta[:frame_method],
        plan: method_plan,
        params: Hash.new { |h, k| h[k] = NKSet.new },
        param_sites: Hash.new { |h, k| h[k] = NKTally.new },
        param_traces: Hash.new { |h, k| h[k] = NKTally.new },
        param_elem: Hash.new { |h, k| h[k] = NKSet.new },
        param_kv: Hash.new { |h, k| h[k] = [NKSet.new, NKSet.new] },
        param_elem_shapes: Hash.new { |h, k| h[k] = NKSet.new },
        param_kv_shapes: Hash.new { |h, k| h[k] = [NKSet.new, NKSet.new] },
        callsite: nil,
        trace: [],
        method_site: meta[:method_site],
      }
      @lock.synchronize do
        stack = @frames[Thread.current.object_id]
        active_trace = stack.reverse.filter_map { |active| active[:method_site] }
        frame[:trace] = (Array(frame[:trace]) + active_trace).uniq
        record_method_edge_entry(frame, stack)
        b[:calls] += 1 if b
        params.each do |kind, name|
          next unless name
          next if %i[rest keyrest block].include?(kind)
          next unless sample_method && sample_param?(method_plan, name)
          value = meta[:forced_values]&.fetch(name.to_s, nil)
          value = binding.local_variable_get(name) rescue nil unless meta[:forced_values]&.key?(name.to_s)
          cls = class_name(value)
          frame[:params][name.to_s] << cls
          frame[:param_sites][name.to_s][site_key(frame[:method_site], cls)] += 1
          if TRACE_PARAM_CLASSES.include?(cls)
            trace_key = trace_key(frame[:trace], cls)
            frame[:param_traces][name.to_s][trace_key] += 1 if trace_key
          end
          shape = container_shape(value)
          if shape
            if shape[0] == :array
              frame[:param_elem][name.to_s].merge(shape[1])
              frame[:param_elem_shapes][name.to_s].merge(shape[2])
              record_tuple("param", meta[:path], meta[:line], name.to_s, value)
            else
              frame[:param_kv][name.to_s][0].merge(shape[1][0])
              frame[:param_kv][name.to_s][1].merge(shape[1][1])
              frame[:param_kv_shapes][name.to_s][0].merge(shape[2][0])
              frame[:param_kv_shapes][name.to_s][1].merge(shape[2][1])
            end
            register_collection_owner(value, owner_kind: "method_param", name: name.to_s, path: meta[:path], line: meta[:line], bucket: b)
          end
        end
        if meta[:frame_method] || sample_return?(method_plan)
          stack << frame
        elsif b
          commit_params_observed(b, frame)
        end
      end
    end
  end

  def self.record_return(tp, forced_entry: nil)
    return if Thread.current[:__nil_kill_collection_hook]
    return unless forced_entry || target_path?(tp.path)
    with_collection_hooks_disabled do
      meta = forced_entry ? forced_method_metadata(tp, forced_entry) : method_metadata(tp, known_target: true)
      return unless meta
      frame = pop_frame_for_meta(meta)
      @lock.synchronize { record_method_edge_outcome(frame, :ok) } if frame
      b = frame ? frame[:bucket] : bucket_for_meta(meta)
      return unless b
      value = tp.return_value
      @lock.synchronize do
        commit_params(b, frame, :ok) if frame
        b[:ok_calls] += 1
        return if frame && !frame[:sample_method]

        b[:returns] << class_name(value) if sample_return?(frame && frame[:plan])
        next_shape = sample_return?(frame && frame[:plan])
        return unless next_shape
        shape = container_shape(value)
        if shape
          if shape[0] == :array
            b[:return_elem].merge(shape[1])
            b[:return_elem_shapes].merge(shape[2])
            record_tuple("return", meta[:path], meta[:line], meta[:method_id], value)
          else
            b[:return_kv][0].merge(shape[1][0])
            b[:return_kv][1].merge(shape[1][1])
            b[:return_kv_shapes][0].merge(shape[2][0])
            b[:return_kv_shapes][1].merge(shape[2][1])
          end
          register_collection_owner(value, owner_kind: "method_return", name: meta[:method_id], path: meta[:path], line: meta[:line], bucket: b)
        end
      end
    end
  end

  def self.record_raise(tp, forced_entry: nil)
    return if Thread.current[:__nil_kill_collection_hook]
    return unless forced_entry || target_path?(tp.path)
    with_collection_hooks_disabled do
      meta = forced_entry ? forced_method_metadata(tp, forced_entry) : method_metadata(tp, known_target: true)
      return unless meta
      frame = pop_frame_for_meta(meta)
      @lock.synchronize { record_method_edge_outcome(frame, :raised) } if frame
      b = frame ? frame[:bucket] : bucket_for_meta(meta)
      return unless b
      @lock.synchronize do
        commit_params(b, frame, :raised) if frame && frame[:sample_method]
        b[:raised_calls] += 1
        b[:raised] << class_name(tp.raised_exception)
      end
    end
  end

  def self.pop_frame(tp)
    meta = method_metadata(tp)
    return nil unless meta
    pop_frame_for_meta(meta)
  end

  def self.pop_frame_for_meta(meta)
    expected = meta[:key]
    return nil unless expected
    stack = @frames[Thread.current.object_id]
    idx = stack.rindex { |frame| frame[:key] == expected }
    return nil unless idx
    stack.delete_at(idx)
  end

  def self.pop_frame_for_key(expected)
    return nil unless expected
    stack = @frames[Thread.current.object_id]
    idx = stack.rindex { |frame| frame[:key] == expected }
    return nil unless idx
    stack.delete_at(idx)
  end

  def self.commit_params(bucket, frame, outcome)
    frame[:params].each do |name, classes|
      bucket[:params_by_name][name].merge(classes)
      target = outcome == :ok ? bucket[:params_ok] : bucket[:params_raised]
      target[name].merge(classes)
    end
    frame[:param_sites].each do |name, sites|
      sites.each do |site, count|
        bucket[:param_sites][name][site] += count
        target = outcome == :ok ? bucket[:param_sites_ok] : bucket[:param_sites_raised]
        target[name][site] += count
      end
    end
    frame[:param_traces].each do |name, traces|
      traces.each do |trace, count|
        bucket[:param_traces][name][trace] += count
        target = outcome == :ok ? bucket[:param_traces_ok] : bucket[:param_traces_raised]
        target[name][trace] += count
      end
    end
    frame[:param_elem].each { |name, classes| bucket[:param_elem][name].merge(classes) }
    frame[:param_elem_shapes].each { |name, shapes| bucket[:param_elem_shapes][name].merge(shapes) }
    frame[:param_kv].each do |name, kv|
      bucket[:param_kv][name][0].merge(kv[0])
      bucket[:param_kv][name][1].merge(kv[1])
    end
    frame[:param_kv_shapes].each do |name, kv|
      bucket[:param_kv_shapes][name][0].merge(kv[0])
      bucket[:param_kv_shapes][name][1].merge(kv[1])
    end
  end

  def self.commit_params_observed(bucket, frame)
    frame[:params].each { |name, classes| bucket[:params_by_name][name].merge(classes) }
    frame[:param_sites].each do |name, sites|
      sites.each { |site, count| bucket[:param_sites][name][site] += count }
    end
    frame[:param_traces].each do |name, traces|
      traces.each { |trace, count| bucket[:param_traces][name][trace] += count }
    end
    frame[:param_elem].each { |name, classes| bucket[:param_elem][name].merge(classes) }
    frame[:param_elem_shapes].each { |name, shapes| bucket[:param_elem_shapes][name].merge(shapes) }
    frame[:param_kv].each do |name, kv|
      bucket[:param_kv][name][0].merge(kv[0])
      bucket[:param_kv][name][1].merge(kv[1])
    end
    frame[:param_kv_shapes].each do |name, kv|
      bucket[:param_kv_shapes][name][0].merge(kv[0])
      bucket[:param_kv_shapes][name][1].merge(kv[1])
    end
  end

  def self.callsite_for(tp)
    "#{abs_path(tp.path)}:#{tp.lineno}"
  end

  def self.callstack_for(tp)
    [callsite_for(tp)]
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

  def self.install_tlet_hook
    return unless defined?(T) && T.respond_to?(:let)
    return if T.singleton_class.method_defined?(:__nil_kill_orig_let)
    T.singleton_class.alias_method(:__nil_kill_orig_let, :let)
    T.singleton_class.define_method(:let) do |value, type, **kw|
      loc = caller_locations(1, 1)&.first
      if loc && NilKillRuntimeTrace.target_path?(loc.absolute_path || loc.path)
        raw = loc.absolute_path || loc.path
        path = File.expand_path(raw, ROOT)
        # Under source instrumentation loc.lineno is the shifted
        # instrumented line; the plan is keyed by the real src line.
        src_ln = NilKillRuntimeTrace.src_line(raw, loc.lineno)
        next T.send(:__nil_kill_orig_let, value, type, **kw) unless NilKillRuntimeTrace.sample_tlet?(path, src_ln)
        key = [path, src_ln]
        NilKillRuntimeTrace.with_collection_hooks_disabled do
          NilKillRuntimeTrace.lock.synchronize do
            rec = (NilKillRuntimeTrace.tlets[key] ||= { calls: 0, classes: NKSet.new })
            rec[:calls] += 1
            rec[:classes] << NilKillRuntimeTrace.class_name(value)
          end
        end
      end
      T.send(:__nil_kill_orig_let, value, type, **kw)
    end
  end

  def self.install_struct_hook
    return if Struct.singleton_class.method_defined?(:__nil_kill_orig_new)
    Struct.singleton_class.alias_method(:__nil_kill_orig_new, :new)
    Struct.singleton_class.define_method(:new) do |*fields, **opts, &blk|
      loc = caller_locations(1, 1)&.first
      klass = __nil_kill_orig_new(*fields, **opts, &blk)
      path = loc && File.expand_path(loc.absolute_path || loc.path, ROOT)
      if path && NilKillRuntimeTrace.target_path?(path) && klass.is_a?(Class) && klass < Struct
        klass.instance_variable_set(:@__nil_kill_struct_path, path)
        klass.instance_variable_set(:@__nil_kill_struct_line, loc.lineno)
        NilKillRuntimeTrace.attach_struct(klass)
      end
      klass
    end

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
  end

  def self.install_open_struct_hook
    require "ostruct"
    return if OpenStruct.instance_variable_get(:@__nil_kill_attached)
    OpenStruct.instance_variable_set(:@__nil_kill_attached, true)
    OpenStruct.prepend(Module.new do
      define_method(:initialize) do |hash = nil|
        super(hash)
        NilKillRuntimeTrace.record_open_struct(self)
      end

      define_method(:[]=) do |name, value|
        result = super(name, value)
        NilKillRuntimeTrace.record_open_struct_field(self, name, value)
        result
      end
    end)
  rescue LoadError
    nil
  end

  def self.install_tstruct_hook
    return unless defined?(T::Struct)
    return if T::Struct.instance_variable_get(:@__nil_kill_attached)
    T::Struct.instance_variable_set(:@__nil_kill_attached, true)

    T::Struct.prepend(Module.new do
      def initialize(*args, **kw, &blk)
        class_name = NilKillRuntimeTrace.safe_module_name(self.class) || "AnonymousTStruct"
        kw.each do |field, value|
          NilKillRuntimeTrace.record_struct_field(self.class, class_name, field, value)
        end
        super(*args, **kw, &blk)
      end
    end)
  end

  def self.install_collection_hook
    install_array_hook
    install_hash_hook
    install_set_hook
  end

  # NOTE: the parallel instrumented tree and its require/require_relative
  # redirect (instrumented_copy_for / resolve_required_source /
  # install_instrumented_require_hook) were DELETED. In-place
  # instrumentation puts the single wrapped copy at the real src path,
  # so every load mechanism loads instrumented code with no redirect --
  # which is exactly what made collect_ran_untraced non-convergent.

  def self.install_array_hook
    return if Array.instance_variable_get(:@__nil_kill_attached)
    Array.instance_variable_set(:@__nil_kill_attached, true)
    Array.prepend(Module.new do
      define_method(:<<) do |value|
        result = super(value)
        if @__nil_kill_traced
          NilKillRuntimeTrace.with_collection_hook_guard { NilKillRuntimeTrace.record_collection_mutation(self, elem: value) }
        end
        result
      end

      define_method(:push) do |*values|
        result = super(*values)
        if @__nil_kill_traced
          NilKillRuntimeTrace.with_collection_hook_guard { values.each { |value| NilKillRuntimeTrace.record_collection_mutation(self, elem: value) } }
        end
        result
      end

      define_method(:append) do |*values|
        result = super(*values)
        if @__nil_kill_traced
          NilKillRuntimeTrace.with_collection_hook_guard { values.each { |value| NilKillRuntimeTrace.record_collection_mutation(self, elem: value) } }
        end
        result
      end

      define_method(:unshift) do |*values|
        result = super(*values)
        if @__nil_kill_traced
          NilKillRuntimeTrace.with_collection_hook_guard { values.each { |value| NilKillRuntimeTrace.record_collection_mutation(self, elem: value) } }
        end
        result
      end

      define_method(:[]=) do |*args|
        value = args.last
        result = super(*args)
        if @__nil_kill_traced
          NilKillRuntimeTrace.with_collection_hook_guard { NilKillRuntimeTrace.record_collection_mutation(self, elem: value) }
        end
        result
      end

      define_method(:concat) do |other|
        result = super(other)
        if @__nil_kill_traced
          NilKillRuntimeTrace.with_collection_hook_guard { Array(other).first(NilKillRuntimeTrace::ELEMENT_SAMPLE).each { |value| NilKillRuntimeTrace.record_collection_mutation(self, elem: value) } }
        end
        result
      end
    end)
  end

  def self.install_hash_hook
    return if Hash.instance_variable_get(:@__nil_kill_attached)
    Hash.instance_variable_set(:@__nil_kill_attached, true)
    Hash.prepend(Module.new do
      define_method(:[]=) do |key, value|
        result = super(key, value)
        if @__nil_kill_traced
          NilKillRuntimeTrace.with_collection_hook_guard { NilKillRuntimeTrace.record_collection_mutation(self, key: key, val: value) }
        end
        result
      end

      define_method(:store) do |key, value|
        result = super(key, value)
        if @__nil_kill_traced
          NilKillRuntimeTrace.with_collection_hook_guard { NilKillRuntimeTrace.record_collection_mutation(self, key: key, val: value) }
        end
        result
      end

      define_method(:merge!) do |*others, **kw, &blk|
        result = super(*others, **kw, &blk)
        if @__nil_kill_traced
          NilKillRuntimeTrace.with_collection_hook_guard do
            others.each { |other| other.each { |key, value| NilKillRuntimeTrace.record_collection_mutation(self, key: key, val: value) } if other.respond_to?(:each) }
            kw.each { |key, value| NilKillRuntimeTrace.record_collection_mutation(self, key: key, val: value) }
          end
        end
        result
      end

      define_method(:update) do |*others, **kw, &blk|
        result = super(*others, **kw, &blk)
        if @__nil_kill_traced
          NilKillRuntimeTrace.with_collection_hook_guard do
            others.each { |other| other.each { |key, value| NilKillRuntimeTrace.record_collection_mutation(self, key: key, val: value) } if other.respond_to?(:each) }
            kw.each { |key, value| NilKillRuntimeTrace.record_collection_mutation(self, key: key, val: value) }
          end
        end
        result
      end
    end)
  end

  def self.install_set_hook
    require "set"
    return if Set.instance_variable_get(:@__nil_kill_attached)
    Set.instance_variable_set(:@__nil_kill_attached, true)
    Set.prepend(Module.new do
      define_method(:add) do |value|
        result = super(value)
        if @__nil_kill_traced
          NilKillRuntimeTrace.with_collection_hook_guard { NilKillRuntimeTrace.record_collection_mutation(self, elem: value) }
        end
        result
      end

      define_method(:<<) do |value|
        result = super(value)
        if @__nil_kill_traced
          NilKillRuntimeTrace.with_collection_hook_guard { NilKillRuntimeTrace.record_collection_mutation(self, elem: value) }
        end
        result
      end

      define_method(:merge) do |enum|
        result = super(enum)
        if @__nil_kill_traced
          NilKillRuntimeTrace.with_collection_hook_guard { enum.first(NilKillRuntimeTrace::ELEMENT_SAMPLE).each { |value| NilKillRuntimeTrace.record_collection_mutation(self, elem: value) } if enum.respond_to?(:first) }
        end
        result
      end
    end)
  rescue LoadError
    nil
  end

  def self.attach_struct(klass)
    return unless klass.is_a?(Class) && klass < Struct
    return if klass.instance_variable_get(:@__nil_kill_attached)
    path = klass.instance_variable_get(:@__nil_kill_struct_path)
    line = klass.instance_variable_get(:@__nil_kill_struct_line)
    unless path && line
      loc = source_location_for_class(klass)
      path, line = loc if loc
      klass.instance_variable_set(:@__nil_kill_struct_path, path) if path
      klass.instance_variable_set(:@__nil_kill_struct_line, line) if line
    end
    return unless path && target_path?(path)
    fields = klass.members
    return if fields.empty?
    klass.instance_variable_set(:@__nil_kill_attached, true)
    klass.prepend(Module.new do
      define_method(:initialize) do |*args, **kw, &blk|
        class_name = NilKillRuntimeTrace.safe_module_name(self.class) || "AnonymousStruct"
        args.each_with_index do |arg, idx|
          field = fields[idx]
          break unless field
          NilKillRuntimeTrace.record_struct_field(self.class, class_name, field, arg)
        end
        kw.each { |field, value| NilKillRuntimeTrace.record_struct_field(self.class, class_name, field, value) }
        super(*args, **kw, &blk)
      end
    end)
  end

  def self.attach_data(klass)
    return unless klass.is_a?(Class)
    return if klass.instance_variable_get(:@__nil_kill_attached)
    path = klass.instance_variable_get(:@__nil_kill_struct_path)
    line = klass.instance_variable_get(:@__nil_kill_struct_line)
    return unless path && line && target_path?(path)
    fields = klass.respond_to?(:members) ? klass.members : []
    return if fields.empty?
    klass.instance_variable_set(:@__nil_kill_attached, true)
    klass.prepend(Module.new do
      define_method(:initialize) do |*args, **kw, &blk|
        class_name = NilKillRuntimeTrace.safe_module_name(self.class) || "AnonymousData"
        args.each_with_index do |arg, idx|
          field = fields[idx]
          break unless field
          NilKillRuntimeTrace.record_struct_field(self.class, class_name, field, arg)
        end
        kw.each { |field, value| NilKillRuntimeTrace.record_struct_field(self.class, class_name, field, value) }
        super(*args, **kw, &blk)
      end
    end)
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

  def self.record_ivar_assignment(receiver, name, value, path, line)
    abs = File.expand_path(path, ROOT)
    if target_path?(abs)
      with_collection_hooks_disabled do
        @lock.synchronize do
          register_collection_owner(value, owner_kind: "ivar", name: name.to_s, path: abs, line: line)
          # Per-(declaring class, ivar) runtime class set. An accessor
          # contract like `.type_info` is backed by `@type_info`; the
          # Union Decomplexity report joins this to attribute the
          # producer types feeding its is_a?(Type) guards.
          cls = safe_module_name(receiver.class)
          if cls
            rec = (@ivar_runtime[[cls, name.to_s]] ||= { calls: 0, classes: NKSet.new })
            rec[:calls] += 1
            rec[:classes] << class_name(value)
          end
        end
      end
    end
    value
  end

  def self.record_struct_field(klass, klass_name, field, value)
    path = klass.instance_variable_get(:@__nil_kill_struct_path)
    line = klass.instance_variable_get(:@__nil_kill_struct_line)
    return unless path && line
    return unless sample_struct_field?(klass_name, field)
    # Normalize the caller path to an absolute real-src path (in-place
    # instrumentation keeps it at the real path; abs_path is now just a
    # cached expand) so the separate `infer` process ingests the row.
    path = abs_path(path)
    key = [klass_name, field.to_s, path, line]
    shape = container_shape(value)
    with_collection_hooks_disabled do
      @lock.synchronize do
        rec = (@structs[key] ||= { calls: 0, classes: NKSet.new, elem_classes: NKSet.new, key_classes: NKSet.new, value_classes: NKSet.new, array_calls: 0, hash_calls: 0 })
        rec[:calls] += 1
        rec[:classes] << class_name(value)
        if shape&.first == :array
          rec[:array_calls] += 1
          rec[:elem_classes].merge(shape[1])
          record_tuple("struct_field", path, line, "#{klass_name}.#{field}", value)
          register_collection_owner(value, owner_kind: "struct_field", name: "#{klass_name}.#{field}", path: path, line: line)
        elsif shape&.first == :hash
          rec[:hash_calls] += 1
          rec[:key_classes].merge(shape[1][0])
          rec[:value_classes].merge(shape[1][1])
          register_collection_owner(value, owner_kind: "struct_field", name: "#{klass_name}.#{field}", path: path, line: line)
        end
      end
    end
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

  def self.dump_hash_counts(counts)
    counts.transform_values(&:to_h)
  end

  def self.method_key_payload(key)
    {
      class: key[0],
      method: key[1],
      kind: key[2],
      path: key[3],
      line: key[4],
    }
  end

  def self.dump
    flush_pending_mutations!
    FileUtils.mkdir_p(OUT_DIR)
    pid = Process.pid
    File.open(File.join(OUT_DIR, "methods-#{pid}.jsonl"), "w") do |file|
      @methods.each do |key, rec|
        file.puts JSON.generate(
          class: key[0], method: key[1], kind: key[2], path: key[3], line: key[4],
          calls: rec[:calls],
          ok_calls: rec[:ok_calls],
          raised_calls: rec[:raised_calls],
          params_by_name: rec[:params_by_name].transform_values { |set| set.to_a.sort },
          params_ok: rec[:params_ok].transform_values { |set| set.to_a.sort },
          params_raised: rec[:params_raised].transform_values { |set| set.to_a.sort },
          param_sites: dump_hash_counts(rec[:param_sites]),
          param_sites_ok: rec[:param_sites_raised].empty? ? {} : dump_hash_counts(rec[:param_sites_ok]),
          param_sites_raised: dump_hash_counts(rec[:param_sites_raised]),
          param_traces: dump_hash_counts(rec[:param_traces]),
          param_traces_ok: rec[:param_traces_raised].empty? ? {} : dump_hash_counts(rec[:param_traces_ok]),
          param_traces_raised: dump_hash_counts(rec[:param_traces_raised]),
          param_elem: rec[:param_elem].transform_values { |set| set.to_a.sort },
          param_kv: rec[:param_kv].transform_values { |kv| [kv[0].to_a.sort, kv[1].to_a.sort] },
          param_elem_shapes: rec[:param_elem_shapes].transform_values { |set| set.to_a.sort.map { |shape| shape_payload(shape) } },
          param_kv_shapes: rec[:param_kv_shapes].transform_values { |kv| [kv[0].to_a.sort.map { |shape| shape_payload(shape) }, kv[1].to_a.sort.map { |shape| shape_payload(shape) }] },
          returns: rec[:returns].to_a.sort,
          return_elem: rec[:return_elem].to_a.sort,
          return_kv: [rec[:return_kv][0].to_a.sort, rec[:return_kv][1].to_a.sort],
          return_elem_shapes: rec[:return_elem_shapes].to_a.sort.map { |shape| shape_payload(shape) },
          return_kv_shapes: [rec[:return_kv_shapes][0].to_a.sort.map { |shape| shape_payload(shape) }, rec[:return_kv_shapes][1].to_a.sort.map { |shape| shape_payload(shape) }],
          raised: rec[:raised].to_a.sort,
        )
      end
    end
    File.open(File.join(OUT_DIR, "method-edges-#{pid}.jsonl"), "w") do |file|
      @method_edges.each do |(caller_key, callee_key), rec|
        file.puts JSON.generate(
          caller: method_key_payload(caller_key),
          callee: method_key_payload(callee_key),
          calls: rec[:calls],
          ok_calls: rec[:ok_calls],
          raised_calls: rec[:raised_calls],
        )
      end
    end
    File.open(File.join(OUT_DIR, "tlets-#{pid}.jsonl"), "w") do |file|
      @tlets.each do |(path, line), rec|
        file.puts JSON.generate(path: path, line: line, calls: rec[:calls], classes: rec[:classes].to_a.sort)
      end
    end
    File.open(File.join(OUT_DIR, "structs-#{pid}.jsonl"), "w") do |file|
      @structs.each do |(klass, field, path, line), rec|
        file.puts JSON.generate(
          class: klass, field: field, path: path, line: line, calls: rec[:calls],
          classes: rec[:classes].to_a.sort,
          elem_classes: rec[:elem_classes].to_a.sort,
          key_classes: rec[:key_classes].to_a.sort,
          value_classes: rec[:value_classes].to_a.sort,
          array_calls: rec[:array_calls],
          hash_calls: rec[:hash_calls],
        )
      end
    end
    File.open(File.join(OUT_DIR, "ivars-#{pid}.jsonl"), "w") do |file|
      @ivar_runtime.each do |(klass, name), rec|
        file.puts JSON.generate(class: klass, name: name, calls: rec[:calls], classes: rec[:classes].to_a.sort)
      end
    end
    File.open(File.join(OUT_DIR, "tuples-#{pid}.jsonl"), "w") do |file|
      @tuples.each do |(kind, path, line, slot, size, types), rec|
        file.puts JSON.generate(kind: kind, path: path, line: line, slot: slot, size: size, types: types,
          complete: rec[:complete], mixed: rec[:mixed], calls: rec[:calls])
      end
    end
    File.open(File.join(OUT_DIR, "collections-#{pid}.jsonl"), "w") do |file|
      @collections.each do |(owner_kind, name, path, line, kind), rec|
        file.puts JSON.generate(
          owner_kind: owner_kind, name: name, path: path, line: line, kind: kind, calls: rec[:calls],
          classes: rec[:classes].to_a.sort,
          elem_classes: rec[:elem_classes].to_a.sort,
          key_classes: rec[:key_classes].to_a.sort,
          value_classes: rec[:value_classes].to_a.sort,
          elem_shapes: rec[:elem_shapes].to_a.sort.map { |shape| shape_payload(shape) },
          key_shapes: rec[:key_shapes].to_a.sort.map { |shape| shape_payload(shape) },
          value_shapes: rec[:value_shapes].to_a.sort.map { |shape| shape_payload(shape) },
          mutation_sites: rec[:mutation_sites].sort_by { |site, count| [-count, site.to_s] }.to_h,
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
    require "coverage"
    return if Coverage.respond_to?(:running?) && Coverage.running?
    Coverage.start(lines: true)
    @coverage_owned = true
  rescue StandardError, LoadError
    @coverage_owned = false
  end

  # instrumented_line -> src_line per src-rel-path, written by
  # SourceInstrumenter#run_in_place to RUNTIME_DIR/.nk-linemap.json.
  # In-place wrapping keeps the file at its real path but still shifts
  # its line numbers (the injected wrapper adds lines), so Coverage's
  # line numbers must be translated back to src space or the join
  # against src def-ranges (collect_ran?) is systematically wrong.
  def self.coverage_line_map
    return @coverage_line_map if defined?(@coverage_line_map) && @coverage_line_map
    path = File.join(OUT_DIR, ".nk-linemap.json")
    @coverage_line_map = File.exist?(path) ? JSON.parse(File.read(path)) : {}
  rescue StandardError
    @coverage_line_map = {}
  end

  # Translate an INSTRUMENTED runtime line number back to its src line
  # via .nk-linemap.json. Any runtime hook that keys off the caller's
  # lineno (T.let, ...) is otherwise wrong under source instrumentation:
  # the wrapper injects lines, so the caller's lineno is shifted and
  # never matches the (real-src-line-keyed) trace plan. Methods avoid
  # this because the instrumenter injects the plan's src line as a
  # literal; line-keyed hooks need this translation. Identity when the
  # file was not instrumented (no map entry).
  def self.src_line(path, lineno)
    rel = Pathname.new(abs_path(path)).relative_path_from(Pathname.new(ROOT)).to_s rescue nil
    per_file = rel && coverage_line_map[rel]
    (per_file && per_file[lineno]) || lineno
  end

  def self.dump_coverage(pid)
    return unless @coverage_owned
    require "coverage"
    require "pathname"
    result = Coverage.result(stop: false, clear: false)
    lmap = coverage_line_map
    File.open(File.join(OUT_DIR, "coverage-#{pid}.jsonl"), "w") do |file|
      result.each do |abs, data|
        next unless target_path?(abs)
        src = abs_path(abs)
        rel = Pathname.new(src).relative_path_from(Pathname.new(ROOT)).to_s rescue src
        # Coverage.start(lines: true) -> per-file value is
        # { lines: [...] } (SYMBOL key); plain mode -> bare array.
        lines = data.is_a?(Hash) ? (data[:lines] || data["lines"]) : data
        per_file = lmap[rel] # nil => file uninstrumented, lines == src
        covered = []
        Array(lines).each_with_index do |hits, i|
          next unless hits && hits.to_i.positive?
          instr_line = i + 1
          src_line = per_file ? per_file[instr_line] : instr_line
          covered << src_line if src_line
        end
        covered = covered.uniq.sort
        next if covered.empty?
        file.puts JSON.generate(path: src, lines: covered)
      end
    end
  rescue StandardError
    nil
  end
end

if ENV["NIL_KILL_TRACE"] == "1"
  NilKillRuntimeTrace.start_coverage!
  tracepoint_fallback = NilKillRuntimeTrace.trace_plan&.fetch("tracepoint_methods", {})&.any?
  if NilKillRuntimeTrace.targeted_method_tracing? || tracepoint_fallback
    NilKillRuntimeTrace.install_targeted_definition_trace
  elsif ENV["NIL_KILL_TRACE_METHODS"] != "0"
    TracePoint.new(:call) { |tp| NilKillRuntimeTrace.record_call(tp) }.enable
    TracePoint.new(:return) { |tp| NilKillRuntimeTrace.record_return(tp) }.enable
    TracePoint.new(:raise) { |tp| NilKillRuntimeTrace.record_raise(tp) }.enable
  end
  begin
    require "sorbet-runtime"
  rescue LoadError
    nil
  end
  NilKillRuntimeTrace.install_tlet_hook
  NilKillRuntimeTrace.install_struct_hook
  NilKillRuntimeTrace.install_data_hook
  NilKillRuntimeTrace.install_open_struct_hook
  NilKillRuntimeTrace.install_tstruct_hook
  NilKillRuntimeTrace.install_collection_hook unless ENV["NIL_KILL_TRACE_COLLECTIONS"] == "0"
  TracePoint.new(:end) { NilKillRuntimeTrace.install_tlet_hook }.enable
  TracePoint.new(:end) do
    NilKillRuntimeTrace.install_data_hook
  end.enable
  at_exit do
    NilKillRuntimeTrace.dump
  end
end
