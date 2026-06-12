# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

# Typed view of one `args:` entry from std_lib.rb. The stdlib authoring
# DSL remains simple Hash/Symbol data; the registry converter turns it
# into this closed shape before annotator consumers inspect it.
class IntrinsicArgSpec < T::Struct
  extend T::Sig

  const :name, T.nilable(String), default: nil
  const :type, Symbol
  const :sync, T.nilable(Symbol), default: nil
  const :ownership, T.nilable(Symbol), default: nil
  const :mutable, T::Boolean, default: false
  const :takes, T::Boolean, default: false

  sig { params(raw: T.untyped).returns(IntrinsicArgSpec) }
  def self.from_registry(raw)
    if raw.is_a?(Hash)
      type_value = raw[:type] || :Any
      return new(
        name: normalize_name(raw[:name]),
        type: type_value.to_sym,
        sync: normalize_symbol(raw[:sync]),
        ownership: normalize_symbol(raw[:ownership]),
        mutable: raw[:mutable] == true,
        takes: raw[:takes] == true,
      )
    end

    new(type: raw.to_sym)
  end

  sig { params(raw: T.untyped).returns(T::Array[IntrinsicArgSpec]) }
  def self.list_from_registry(raw)
    return [] unless raw.is_a?(Array)

    raw.map { |entry| from_registry(entry) }
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

  sig { params(value: T.untyped).returns(T.nilable(String)) }
  def self.normalize_name(value)
    return nil if value.nil?

    value.to_s
  end
  private_class_method :normalize_name

  sig { params(value: T.untyped).returns(T.nilable(Symbol)) }
  def self.normalize_symbol(value)
    return nil if value.nil?

    value.to_sym
  end
  private_class_method :normalize_symbol
end
