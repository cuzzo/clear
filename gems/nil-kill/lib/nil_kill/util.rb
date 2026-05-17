# typed: false
# frozen_string_literal: true

module NilKill
  HIGH = "high"
  REVIEW = "review"
  GAP = "gap"
  MAX_UNION_TYPES = 3
  MAX_SHAPE_UNION_TYPES = MAX_UNION_TYPES
  MAX_SHAPE_TYPE_LENGTH = 240
  CORE_CLASS_CONSTANTS = Set.new(%w[
    Array BasicObject Class Complex Encoding Enumerator Exception FalseClass Fiber Float Hash Integer Module NilClass
    Numeric Object Proc Range Rational Regexp String Struct Symbol Thread Time TrueClass
  ]).freeze

  module_function

  def rel(path)
    Pathname.new(path).relative_path_from(Pathname.new(ROOT)).to_s
  rescue StandardError
    path.to_s
  end

  # ---- In-place instrumentation lifecycle -----------------------------
  # `collect` wraps the real src/ in place (one copy, at the real path,
  # always instrumented -> every load mechanism / subprocess / re-exec
  # loads instrumented code). The pristine tree is snapshotted and
  # restored automatically, including after a crash, via this sentinel.

  INPLACE_SENTINEL_NAME = ".nk-inplace-active.json"

  # Computed at call time (the spec suite resets RUNTIME_DIR per example).
  def inplace_sentinel_path
    File.join(RUNTIME_DIR, INPLACE_SENTINEL_NAME)
  end

  # Written BEFORE the first src byte is overwritten and deleted LAST
  # after restore, with the FULL candidate file list (not a post-wrap
  # manifest) so a crash mid-wrap is still fully healed. Its presence
  # at the top of any nil-kill run means a collect was instrumenting
  # src and did not finish -> heal before anything else touches src.
  def write_inplace_sentinel!(snapshot_dir, files)
    FileUtils.mkdir_p(File.dirname(inplace_sentinel_path))
    File.write(inplace_sentinel_path,
      JSON.generate("snapshot_dir" => snapshot_dir, "files" => Array(files), "pid" => Process.pid))
  end

  # Idempotent. Restores every snapshotted file to its pristine bytes
  # (atomic per file: sibling tmp + rename), then deletes the sentinel.
  # Files not yet wrapped at crash time have no snapshot and are
  # already pristine -> skipped. Safe to call from an ensure, a signal
  # trap, AND the next process's startup: whoever runs first heals, the
  # rest no-op (sentinel gone).
  def restore_inplace_snapshot!
    sentinel = inplace_sentinel_path
    return false unless File.file?(sentinel)
    meta = begin
      JSON.parse(File.read(sentinel))
    rescue StandardError
      nil
    end
    return false unless meta
    snapshot_dir = meta["snapshot_dir"].to_s
    Array(meta["files"]).each do |relp|
      snap = File.join(snapshot_dir, relp)
      dest = File.expand_path(relp, ROOT)
      next unless File.file?(snap)
      tmp = "#{dest}.nk-restore-#{Process.pid}"
      begin
        File.binwrite(tmp, File.binread(snap))
        File.rename(tmp, dest)
      rescue StandardError
        File.delete(tmp) if File.file?(tmp)
      end
    end
    File.delete(sentinel) if File.file?(sentinel)
    true
  rescue StandardError
    false
  end

  # Self-heal: a prior collect that crashed mid-instrumentation left
  # the sentinel on disk and src/ holding wrapped copies. Restore
  # before any subcommand reads src. Loud -- a stale wrapped tree would
  # otherwise silently poison infer/report/loop.
  def ensure_src_restored!
    return unless File.file?(inplace_sentinel_path)
    warn "nil-kill: a previous `collect` left src/ instrumented (crash?). Restoring pristine sources..."
    restore_inplace_snapshot!
  end

  def target_dirs
    ENV.fetch("NIL_KILL_TARGETS", "src").split(File::PATH_SEPARATOR).map { |path| File.expand_path(path, ROOT) }
  end

  def target_exclude_dirs
    ENV.fetch("NIL_KILL_EXCLUDE_TARGETS", "").split(File::PATH_SEPARATOR).reject(&:empty?).map { |path| File.expand_path(path, ROOT) }
  end

  def target_files
    target_dirs.flat_map { |dir| File.directory?(dir) ? Dir.glob(File.join(dir, "**", "*.rb")) : [dir] }
      .select { |p| File.file?(p) && !target_excluded?(p) }
      .sort
  end

  # Every .rb file the usage-detection passes (e.g. `unused_return_methods`)
  # should walk to decide whether a method is actually called. Has to include
  # spec/, tools/, etc., not just `target_dirs`: a method only used by a spec
  # is still used; narrowing it to `void` would replace its return value with
  # a Void marker at runtime and break callers.
  #
  # Scoping rule: when `NIL_KILL_TARGETS` is set explicitly (the spec-suite
  # `isolated_env` pattern, or any narrow-scope production run), respect that
  # scope -- usage scanning is bounded by the same world as type inference.
  # Otherwise fall back to a broad host-project scan that excludes vendored
  # gems and tmp/build output.
  PROJECT_RUBY_EXCLUDES = %w[vendor tmp gems/tmp gems/nil-kill/vendor gems/nil-kill/tmp .bundle].freeze

  def usage_scan_files
    return target_files if ENV.key?("NIL_KILL_TARGETS")
    excluded_prefixes = PROJECT_RUBY_EXCLUDES.map { |p| File.expand_path(p, ROOT) + File::SEPARATOR }
    Dir.glob(File.join(ROOT, "**", "*.rb"))
      .reject { |p| excluded_prefixes.any? { |prefix| p.start_with?(prefix) } }
      .select { |p| File.file?(p) }
      .sort
  end

  def target_path?(path)
    abs = File.expand_path(path, ROOT)
    target_dirs.any? { |dir| abs == dir || abs.start_with?(dir + File::SEPARATOR) } && !target_excluded?(abs)
  end

  def target_excluded?(path)
    abs = File.expand_path(path, ROOT)
    target_exclude_dirs.any? { |dir| abs == dir || abs.start_with?(dir + File::SEPARATOR) }
  end

  def sorbet_type(classes, allow_nilable: true)
    classes = Array(classes).compact.reject(&:empty?)
    return "T.untyped" if classes.empty?
    has_nil = classes.include?("NilClass")
    others = classes.reject { |c| c == "NilClass" || c.include?("#") || c.start_with?("Sorbet::Private::") }
    return "T.untyped" if others.empty?
    base =
      if others.all? { |c| c == "TrueClass" || c == "FalseClass" }
        "T::Boolean"
      elsif others.size == 1
        others.first
      elsif ENV.fetch("NIL_KILL_UNION_POLICY", "any") == "any" && others.size <= MAX_UNION_TYPES
        "T.any(#{others.sort.join(", ")})"
      else
        "T.untyped"
      end
    return "T.untyped" if base == "T.untyped"
    has_nil && allow_nilable ? "T.nilable(#{base})" : base
  end

  def useful_type?(type)
    !type.to_s.empty? && type != "T.untyped"
  end

  # Strip parametric stdlib container wrappers so a class-keyed lookup can
  # match the bare class name. T::Array[Foo] -> "Array", T::Hash[K, V] ->
  # "Hash", etc. Returns nil for non-container types so callers can detect
  # "no stripping applies" without doing the regex themselves.
  def strip_to_stdlib_owner(type)
    case type.to_s
    when /\AT::Array\b/ then "Array"
    when /\AT::Hash\b/ then "Hash"
    when /\AT::Set\b/ then "Set"
    when /\AT::Enumerable\b/ then "Enumerable"
    when /\AT::Range\b/ then "Range"
    when /\AT::Enumerator\b/ then "Enumerator"
    else nil
    end
  end

  def weak_type?(type)
    type.to_s.include?("T.untyped") ||
      type.to_s.match?(/\AT::(?:Array|Hash|Enumerable|Set)\b.*\[T\.untyped/)
  end

  def strong_trace_type?(type)
    useful_type?(type) && !weak_type?(type)
  end

  def static_sorbet_type(types)
    types = Array(types).compact.reject(&:empty?)
    return "T.untyped" if types.empty?
    has_nil = false
    others = []
    types.each do |type|
      if type == "NilClass"
        has_nil = true
      elsif type.start_with?("T.nilable(") && type.end_with?(")")
        has_nil = true
        others << type[10..-2]
      else
        others << normalize_static_sorbet_type(type)
      end
    end
    others = others.uniq.sort
    if others.include?("T.noreturn")
      return has_nil ? "NilClass" : "T.noreturn" if others == ["T.noreturn"]
      others.delete("T.noreturn")
    end
    return "NilClass" if others.empty? && has_nil
    return "T.untyped" if others.empty?
    base =
      if others.all? { |type| type == "TrueClass" || type == "FalseClass" || type == "T::Boolean" }
        "T::Boolean"
      elsif others.size == 1
        others.first
      elsif ENV.fetch("NIL_KILL_UNION_POLICY", "untyped") == "any" && others.size <= MAX_UNION_TYPES
        "T.any(#{others.join(", ")})"
      else
        "T.untyped"
      end
    return "T.untyped" if base == "T.untyped"
    has_nil ? "T.nilable(#{base})" : base
  end

  def normalize_static_sorbet_type(type)
    case type.to_s
    when "Array" then "T::Array[T.untyped]"
    when "Hash" then "T::Hash[T.untyped, T.untyped]"
    when "Set" then "T::Set[T.untyped]"
    else type.to_s
    end
  end

  def extract_call_args(source, name)
    idx = source.to_s.index("#{name}(")
    return nil unless idx
    start = idx + name.length + 1
    depth = 1
    i = start
    while i < source.length
      case source[i]
      when "(" then depth += 1
      when ")"
        depth -= 1
        return source[start...i] if depth.zero?
      end
      i += 1
    end
    nil
  end

  def split_top_level(source)
    parts = []
    start = 0
    depth = 0
    source.to_s.each_char.with_index do |char, idx|
      case char
      when "(", "[", "{"
        depth += 1
      when ")", "]", "}"
        depth -= 1 if depth.positive?
      when ","
        if depth.zero?
          parts << source[start...idx].strip
          start = idx + 1
        end
      end
    end
    parts << source[start..].to_s.strip
    parts.reject(&:empty?)
  end

  def broad_union_type?(type, max: MAX_UNION_TYPES)
    source = type.to_s
    idx = 0
    total = 0
    while (start = source.index("T.any(", idx))
      args_start = start + "T.any(".length
      depth = 1
      i = args_start
      while i < source.length
        case source[i]
        when "("
          depth += 1
        when ")"
          depth -= 1
          break if depth.zero?
        end
        i += 1
      end
      return true if depth.positive?
      size = split_top_level(source[args_start...i]).size
      return true if size > max
      total += size
      return true if total > max
      idx = start + 1
    end
    false
  end

  def extract_param_entries(sig)
    params = extract_call_args(sig, "params")
    return [] unless params
    split_top_level(params).filter_map do |entry|
      name, type = entry.split(/:\s*/, 2)
      next unless name && type
      [name.strip, type.strip]
    end
  end

  def extract_return_type(sig)
    extract_call_args(sig, "returns")
  end

  def strip_nilable_type(type)
    type = type.to_s.strip
    return type unless type.start_with?("T.nilable(")
    extract_call_args(type, "T.nilable") || type
  end

  def conservative_element_type(classes)
    classes = Array(classes).compact.reject(&:empty?)
    has_nil = classes.include?("NilClass")
    others = classes.reject { |c| c == "NilClass" || c.include?("#") || c.start_with?("Sorbet::Private::") }
    return nil if others.empty?
    return "T::Boolean" if others.sort == %w[FalseClass TrueClass]
    return nil unless others.size == 1
    klass = others.first
    return nil if klass.start_with?("AST::") || klass.start_with?("MIR::")
    has_nil ? "T.nilable(#{klass})" : klass
  end

  def parse_shape(shape)
    shape.is_a?(String) ? JSON.parse(shape) : shape
  rescue JSON::ParserError
    { "kind" => "class", "name" => shape.to_s }
  end

  def shape_type(shape)
    shape = parse_shape(shape)
    return nil unless shape.is_a?(Hash)
    case shape["kind"]
    when "class"
      klass = shape["name"].to_s
      return nil if klass.empty? || klass == "T.untyped" || klass.include?("#") || klass.start_with?("Sorbet::Private::")
      return nil if klass.start_with?("AST::") || klass.start_with?("MIR::")
      klass
    when "array"
      elem = shape_union_type(shape["elements"])
      elem ? "T::Array[#{elem}]" : nil
    when "set"
      elem = shape_union_type(shape["elements"])
      elem ? "T::Set[#{elem}]" : nil
    when "hash"
      key = shape_union_type(shape["keys"])
      value = shape_union_type(shape["values"])
      key && value ? "T::Hash[#{key}, #{value}]" : nil
    end
  end

  def shape_union_type(shapes)
    parsed_shapes = Array(shapes).filter_map do |shape|
      parsed = parse_shape(shape)
      parsed if parsed.is_a?(Hash)
    end
    return nil if parsed_shapes.empty?

    kinds = parsed_shapes.map { |shape| shape["kind"] }.uniq
    if kinds.one?
      case kinds.first
      when "array"
        elem = shape_union_type(parsed_shapes.flat_map { |shape| Array(shape["elements"]) })
        return elem ? "T::Array[#{elem}]" : nil
      when "set"
        elem = shape_union_type(parsed_shapes.flat_map { |shape| Array(shape["elements"]) })
        return elem ? "T::Set[#{elem}]" : nil
      when "hash"
        key = shape_union_type(parsed_shapes.flat_map { |shape| Array(shape["keys"]) })
        value = shape_union_type(parsed_shapes.flat_map { |shape| Array(shape["values"]) })
        value = "T.untyped" if value.to_s.include?("T.any(")
        return key && value ? "T::Hash[#{key}, #{value}]" : nil
      end
    end

    types = parsed_shapes.filter_map { |shape| shape_type(shape) }.uniq.sort
    has_nil = types.delete("NilClass")
    return nil if types.empty?
    return "T.untyped" if types.size > MAX_SHAPE_UNION_TYPES
    type = types == %w[FalseClass TrueClass] ? "T::Boolean" : (types.one? ? types.first : "T.any(#{types.join(", ")})")
    type = "T.nilable(#{type})" if has_nil
    return "T.untyped" if type.length > MAX_SHAPE_TYPE_LENGTH
    return "T.untyped" if broad_union_type?(type)
    type
  end

  def acceptable_shape_candidate?(type)
    type.to_s.length <= MAX_SHAPE_TYPE_LENGTH && !broad_union_type?(type)
  end

  def confidence(calls)
    calls.to_i >= ENV.fetch("NIL_KILL_MIN_CALLS", "20").to_i ? HIGH : REVIEW
  end

  def rbi_return_type(method_name, receiver_type = nil)
    rbi_return_index.return_type(method_name, receiver_type)
  end

  def rbi_return_index
    @rbi_return_index ||= RbiReturnIndex.build
  end

  def display_union(classes, allow_nilable: true)
    classes = Array(classes).compact.reject(&:empty?)
    has_nil = classes.include?("NilClass")
    others = classes.reject { |c| c == "NilClass" || c.include?("#") || c.start_with?("Sorbet::Private::") }
    base = others.size == 1 ? others.first : "T.any(#{others.sort.join(", ")})"
    has_nil && allow_nilable ? "T.nilable(#{base})" : base
  end
end
