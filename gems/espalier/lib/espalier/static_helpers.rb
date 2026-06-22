# typed: false
# frozen_string_literal: true

require "pathname"
require "set"

module Espalier
  ROOT = File.expand_path("../../../..", __dir__) unless const_defined?(:ROOT)

  HIGH = "high"
  REVIEW = "review"
  GAP = "gap"
  MAX_UNION_TYPES = 3
  CORE_CLASS_CONSTANTS = Set.new(%w[
    Array BasicObject Class Complex Encoding Enumerator Exception FalseClass Fiber Float Hash Integer Module NilClass
    Numeric Object Proc Range Rational Regexp String Struct Symbol Thread Time TrueClass
  ]).freeze

  module_function

  def target_dirs(root: ROOT)
    ENV.fetch("ESPALIER_TARGETS", ENV.fetch("NIL_KILL_TARGETS", "src"))
      .split(File::PATH_SEPARATOR)
      .map { |path| File.expand_path(path, root) }
  end

  def target_exclude_dirs(root: ROOT)
    ENV.fetch("ESPALIER_EXCLUDE_TARGETS", ENV.fetch("NIL_KILL_EXCLUDE_TARGETS", ""))
      .split(File::PATH_SEPARATOR)
      .reject(&:empty?)
      .map { |path| File.expand_path(path, root) }
  end

  def target_excluded?(path, root: ROOT)
    abs = File.expand_path(path, root)
    target_exclude_dirs(root: root).any? { |dir| abs == dir || abs.start_with?(dir + File::SEPARATOR) }
  end

  def rel(path, root: ROOT)
    Pathname.new(path).relative_path_from(Pathname.new(root)).to_s
  rescue StandardError
    path.to_s
  end

  def useful_type?(type)
    !type.to_s.empty? && type != "T.untyped"
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
end
