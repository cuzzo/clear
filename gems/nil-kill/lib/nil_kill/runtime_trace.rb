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

  # NOTE: the parallel instrumented tree and its require/require_relative
  # redirect (instrumented_copy_for / resolve_required_source /
  # install_instrumented_require_hook) were DELETED. In-place
  # instrumentation puts the single wrapped copy at the real src path,
  # so every load mechanism loads instrumented code with no redirect --
  # which is exactly what made collect_ran_untraced non-convergent.

  # The collector writes what it saw and nothing else; turning that into rows
  # is the collector process's job, not the traced program's.
  def self.dump
    FileUtils.mkdir_p(OUT_DIR)
    pid = Process.pid
    dump_native_runtime_scip(pid)
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
  begin
    require "ostruct"
  rescue LoadError
    nil
  end
  NilKillTraceNative.install_open_struct_hook
  NilKillTraceNative.install_tstruct_hook
  NilKillTraceNative.install_collection_hook unless ENV["NIL_KILL_TRACE_COLLECTIONS"] == "0"
  # Sorbet may be required after the collector starts, so `T` is looked for
  # again whenever a class or module body finishes.
  TracePoint.new(:end) { NilKillTraceNative.install_tlet_hook }.enable
  at_exit do
    NilKillRuntimeTrace.dump
  end
end
