# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

# Typed view of one `args:` entry from std_lib.rb. The stdlib authoring
# DSL remains simple Hash/Symbol data; the registry converter turns it
# into this closed shape before annotator consumers inspect it.
class IntrinsicArgSpec < T::Struct
  extend T::Sig
  RegistryValue = T.type_alias { T.untyped }
  RawEntry = T.type_alias { T::Hash[Symbol, RegistryValue] }
  RawArgSpecEntry = T.type_alias { T.any(Symbol, String, RawEntry) }
  RawArgSpec = T.type_alias { T.nilable(T.any(Symbol, String, RawEntry, T::Array[RawArgSpecEntry])) }

  const :name, T.nilable(String), default: nil
  const :type, Symbol
  const :sync, T.nilable(Symbol), default: nil
  const :ownership, T.nilable(Symbol), default: nil
  const :mutable, T::Boolean, default: false
  const :takes, T::Boolean, default: false

  sig { params(raw: RawArgSpecEntry).returns(IntrinsicArgSpec) }
  def self.from_registry(raw)
    if raw.is_a?(Hash)
      return IntrinsicArgSpec.new(
        name: normalize_name(raw[:name]),
        type: normalize_type(raw[:type]),
        sync: normalize_symbol(raw[:sync]),
        ownership: normalize_symbol(raw[:ownership]),
        mutable: raw[:mutable] == true,
        takes: raw[:takes] == true,
      )
    end

    return IntrinsicArgSpec.new(type: normalize_type(raw)) if raw.is_a?(Symbol)

    IntrinsicArgSpec.new(type: :Any)
  end

  sig { params(raw: RawArgSpec).returns(T::Array[IntrinsicArgSpec]) }
  def self.list_from_registry(raw)
    if raw.is_a?(Array)
      return raw.map { |entry| from_registry(entry) }
    end

    []
  end

  sig { params(raw: RawArgSpec).returns(T::Boolean) }
  def self.fixed_list_from_registry?(raw)
    return false if raw.nil?

    raw.is_a?(Array)
  end

  sig { params(raw: RawArgSpec).returns(T::Boolean) }
  def self.varargs_from_registry?(raw)
    return false if raw.nil?
    if raw.is_a?(Symbol)
      return raw == :Varargs
    end

    false
  end

  sig { returns(T::Boolean) }
  def unconstrained_any?
    type == :Any && sync.nil? && ownership.nil?
  end

  sig { returns(T::Boolean) }
  def capability_constrained?
    !sync.nil? || !ownership.nil?
  end

  sig { returns(String) }
  def display_type
    type.to_s
  end

  sig { params(value: T.nilable(T.any(String, Symbol))).returns(T.nilable(String)) }
  def self.normalize_name(value)
    return nil if value.nil?
    return value if value.is_a?(String)

    value.to_s
  end
  private_class_method :normalize_name

  sig { params(value: T.nilable(T.any(String, Symbol))).returns(Symbol) }
  def self.normalize_type(value)
    return :Any if value.nil?
    return value if value.is_a?(Symbol)
    return value.to_sym if value.is_a?(String)

    :Any
  end
  private_class_method :normalize_type

  sig { params(value: T.nilable(T.any(String, Symbol))).returns(T.nilable(Symbol)) }
  def self.normalize_symbol(value)
    return nil if value.nil?
    return value if value.is_a?(Symbol)
    return value.to_sym if value.is_a?(String)

    nil
  end
  private_class_method :normalize_symbol
end
