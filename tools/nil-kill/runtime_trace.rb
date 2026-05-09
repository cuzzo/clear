# typed: false
# frozen_string_literal: true

require "fileutils"
require "json"
require "set"

module NilKillRuntimeTrace
  ROOT = File.expand_path("../..", __dir__)
  OUT_DIR = File.expand_path(File.join(ROOT, "tmp", "nil-kill", "runtime"))
  TARGETS = ENV.fetch("NIL_KILL_TARGETS", "src").split(File::PATH_SEPARATOR).map do |path|
    File.expand_path(path, ROOT)
  end
  ELEMENT_SAMPLE = ENV.fetch("NIL_KILL_ELEMENT_SAMPLE", "20").to_i

  @methods = {}
  @tlets = {}
  @structs = {}
  @tuples = {}
  @frames = Hash.new { |h, k| h[k] = [] }
  @lock = Mutex.new

  class << self
    attr_reader :methods, :tlets, :structs, :tuples, :frames, :lock
  end

  def self.target_path?(path)
    abs = File.expand_path(path.to_s, ROOT)
    TARGETS.any? { |target| abs == target || abs.start_with?(target + File::SEPARATOR) }
  end

  def self.class_name(value)
    return "NilClass" if value.nil?
    cls = value.class rescue nil
    return "T.untyped" unless cls
    cls.name || "T.untyped"
  end

  def self.container_shape(value)
    case value
    when Array, Set
      [:array, value.first(ELEMENT_SAMPLE).map { |item| class_name(item) }.to_set]
    when Hash
      keys = Set.new
      vals = Set.new
      value.first(ELEMENT_SAMPLE).each do |key, val|
        keys << class_name(key)
        vals << class_name(val)
      end
      [:hash, [keys, vals]]
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
      return [target.name, "class"] if target.is_a?(Module) && target.name
      nil
    else
      defined_class.name && [defined_class.name, "instance"]
    end
  end

  def self.bucket(tp)
    owner = method_owner(tp.defined_class)
    return nil unless owner
    key = [owner[0], tp.method_id.to_s, owner[1], File.expand_path(tp.path, ROOT), tp.lineno]
    @methods[key] ||= {
      calls: 0,
      ok_calls: 0,
      raised_calls: 0,
      params_by_name: Hash.new { |h, k| h[k] = Set.new },
      params_ok: Hash.new { |h, k| h[k] = Set.new },
      params_raised: Hash.new { |h, k| h[k] = Set.new },
      param_sites: Hash.new { |h, k| h[k] = Hash.new(0) },
      param_sites_ok: Hash.new { |h, k| h[k] = Hash.new(0) },
      param_sites_raised: Hash.new { |h, k| h[k] = Hash.new(0) },
      param_elem: Hash.new { |h, k| h[k] = Set.new },
      param_kv: Hash.new { |h, k| h[k] = [Set.new, Set.new] },
      returns: Set.new,
      return_elem: Set.new,
      return_kv: [Set.new, Set.new],
      raised: Set.new,
    }
  end

  def self.record_call(tp)
    return unless target_path?(tp.path)
    params = tp.parameters rescue nil
    return unless params
    b = bucket(tp)
    return unless b
    binding = tp.binding
    frame = {
      key: [method_owner(tp.defined_class), tp.method_id.to_s, File.expand_path(tp.path, ROOT)],
      bucket: b,
      params: Hash.new { |h, k| h[k] = Set.new },
      param_sites: Hash.new { |h, k| h[k] = Hash.new(0) },
      param_elem: Hash.new { |h, k| h[k] = Set.new },
      param_kv: Hash.new { |h, k| h[k] = [Set.new, Set.new] },
      callsite: callsite_for(tp),
    }
    @lock.synchronize do
      b[:calls] += 1
      params.each do |kind, name|
        next unless name
        next if %i[rest keyrest block].include?(kind)
        value = binding.local_variable_get(name) rescue nil
        cls = class_name(value)
        frame[:params][name.to_s] << cls
        frame[:param_sites][name.to_s][site_key(frame[:callsite], cls)] += 1 if frame[:callsite]
        shape = container_shape(value)
        next unless shape
        if shape[0] == :array
          frame[:param_elem][name.to_s].merge(shape[1])
          record_tuple("param", tp.path, tp.lineno, name.to_s, value)
        else
          frame[:param_kv][name.to_s][0].merge(shape[1][0])
          frame[:param_kv][name.to_s][1].merge(shape[1][1])
        end
      end
      @frames[Thread.current.object_id] << frame
    end
  end

  def self.record_return(tp)
    return unless target_path?(tp.path)
    frame = pop_frame(tp)
    b = frame ? frame[:bucket] : bucket(tp)
    return unless b
    value = tp.return_value
    @lock.synchronize do
      commit_params(b, frame, :ok) if frame
      b[:ok_calls] += 1
      b[:returns] << class_name(value)
      shape = container_shape(value)
      next unless shape
      if shape[0] == :array
        b[:return_elem].merge(shape[1])
        record_tuple("return", tp.path, tp.lineno, tp.method_id.to_s, value)
      else
        b[:return_kv][0].merge(shape[1][0])
        b[:return_kv][1].merge(shape[1][1])
      end
    end
  end

  def self.record_raise(tp)
    return unless target_path?(tp.path)
    frame = pop_frame(tp)
    b = frame ? frame[:bucket] : bucket(tp)
    return unless b
    @lock.synchronize do
      commit_params(b, frame, :raised) if frame
      b[:raised_calls] += 1
      b[:raised] << class_name(tp.raised_exception)
    end
  end

  def self.pop_frame(tp)
    owner = method_owner(tp.defined_class)
    return nil unless owner
    expected = [owner, tp.method_id.to_s, File.expand_path(tp.path, ROOT)]
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
    frame[:param_elem].each { |name, classes| bucket[:param_elem][name].merge(classes) }
    frame[:param_kv].each do |name, kv|
      bucket[:param_kv][name][0].merge(kv[0])
      bucket[:param_kv][name][1].merge(kv[1])
    end
  end

  def self.callsite_for(tp)
    caller_locations(2, 30).find do |loc|
      path = loc.absolute_path || loc.path
      path && target_path?(path) && File.expand_path(path, ROOT) != File.expand_path(__FILE__, ROOT)
    end
  end

  def self.site_key(loc, cls)
    path = File.expand_path(loc.absolute_path || loc.path, ROOT)
    "#{path}:#{loc.lineno}:#{cls}"
  end

  def self.install_tlet_hook
    return unless defined?(T) && T.respond_to?(:let)
    return if T.singleton_class.method_defined?(:__nil_kill_orig_let)
    T.singleton_class.alias_method(:__nil_kill_orig_let, :let)
    T.singleton_class.define_method(:let) do |value, type, **kw|
      loc = caller_locations(1, 1)&.first
      if loc && NilKillRuntimeTrace.target_path?(loc.absolute_path || loc.path)
        path = File.expand_path(loc.absolute_path || loc.path, ROOT)
        key = [path, loc.lineno]
        NilKillRuntimeTrace.lock.synchronize do
          rec = (NilKillRuntimeTrace.tlets[key] ||= { calls: 0, classes: Set.new })
          rec[:calls] += 1
          rec[:classes] << NilKillRuntimeTrace.class_name(value)
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
        value = const_get(name)
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
        class_name = self.class.name || "AnonymousStruct"
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
        class_name = self.class.name || "AnonymousData"
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
    loc = caller_locations(2, 20).find do |candidate|
      path = candidate.absolute_path || candidate.path
      path && target_path?(path) && File.expand_path(path, ROOT) != File.expand_path(__FILE__, ROOT)
    end
    return unless loc
    singleton_name = instance.class.name
    klass_name = singleton_name && singleton_name != "OpenStruct" ? singleton_name : "OpenStruct"
    shim = Object.new
    shim.instance_variable_set(:@__nil_kill_struct_path, File.expand_path(loc.absolute_path || loc.path, ROOT))
    shim.instance_variable_set(:@__nil_kill_struct_line, loc.lineno)
    record_struct_field(shim, klass_name, field, value)
  end

  def self.record_struct_field(klass, klass_name, field, value)
    path = klass.instance_variable_get(:@__nil_kill_struct_path)
    line = klass.instance_variable_get(:@__nil_kill_struct_line)
    return unless path && line
    key = [klass_name, field.to_s, path, line]
    shape = container_shape(value)
    @lock.synchronize do
      rec = (@structs[key] ||= { calls: 0, classes: Set.new, elem_classes: Set.new, key_classes: Set.new, value_classes: Set.new, array_calls: 0, hash_calls: 0 })
      rec[:calls] += 1
      rec[:classes] << class_name(value)
      if shape&.first == :array
        rec[:array_calls] += 1
        rec[:elem_classes].merge(shape[1])
        record_tuple("struct_field", path, line, "#{klass_name}.#{field}", value)
      elsif shape&.first == :hash
        rec[:hash_calls] += 1
        rec[:key_classes].merge(shape[1][0])
        rec[:value_classes].merge(shape[1][1])
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
    key = [kind, File.expand_path(path, ROOT), line, slot.to_s, complete ? value.size : ">=#{ELEMENT_SAMPLE}", types]
    rec = (@tuples[key] ||= { calls: 0, complete: complete, mixed: mixed })
    rec[:calls] += 1
    rec[:complete] &&= complete
    rec[:mixed] ||= mixed
  end

  def self.dump
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
          param_sites: rec[:param_sites].transform_values { |sites| sites.sort.to_h },
          param_sites_ok: rec[:param_sites_ok].transform_values { |sites| sites.sort.to_h },
          param_sites_raised: rec[:param_sites_raised].transform_values { |sites| sites.sort.to_h },
          param_elem: rec[:param_elem].transform_values { |set| set.to_a.sort },
          param_kv: rec[:param_kv].transform_values { |kv| [kv[0].to_a.sort, kv[1].to_a.sort] },
          returns: rec[:returns].to_a.sort,
          return_elem: rec[:return_elem].to_a.sort,
          return_kv: [rec[:return_kv][0].to_a.sort, rec[:return_kv][1].to_a.sort],
          raised: rec[:raised].to_a.sort,
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
    File.open(File.join(OUT_DIR, "tuples-#{pid}.jsonl"), "w") do |file|
      @tuples.each do |(kind, path, line, slot, size, types), rec|
        file.puts JSON.generate(kind: kind, path: path, line: line, slot: slot, size: size, types: types,
          complete: rec[:complete], mixed: rec[:mixed], calls: rec[:calls])
      end
    end
  end
end

if ENV["NIL_KILL_TRACE"] == "1"
  TracePoint.new(:call) { |tp| NilKillRuntimeTrace.record_call(tp) }.enable
  TracePoint.new(:return) { |tp| NilKillRuntimeTrace.record_return(tp) }.enable
  TracePoint.new(:raise) { |tp| NilKillRuntimeTrace.record_raise(tp) }.enable
  begin
    require "sorbet-runtime"
  rescue LoadError
    nil
  end
  NilKillRuntimeTrace.install_tlet_hook
  NilKillRuntimeTrace.install_struct_hook
  NilKillRuntimeTrace.install_data_hook
  NilKillRuntimeTrace.install_open_struct_hook
  TracePoint.new(:end) { NilKillRuntimeTrace.install_tlet_hook }.enable
  TracePoint.new(:end) do
    NilKillRuntimeTrace.install_data_hook
    ObjectSpace.each_object(Class) do |klass|
      NilKillRuntimeTrace.attach_struct(klass) if klass < Struct rescue nil
      NilKillRuntimeTrace.attach_data(klass) if defined?(Data) && klass < Data rescue nil
    end
  end.enable
  at_exit { NilKillRuntimeTrace.dump }
end
