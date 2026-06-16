# typed: strict
require "sorbet-runtime"

require_relative "../ast/symbol_entry"

module OwnershipIdentity
  extend T::Sig

  class BindingId < T::Struct
    extend T::Sig

    const :name, String
    const :binding_id, Integer

    sig { params(name: String, symbol: SymbolEntry).returns(BindingId) }
    def self.from_symbol(name, symbol)
      new(name: name, binding_id: symbol.binding_id)
    end

    sig { returns(String) }
    def to_s
      "#{name}##{binding_id}"
    end
  end

  class PlaceId < T::Struct
    extend T::Sig

    const :path, String
    const :binding_name, T.nilable(String), default: nil
    const :binding_id, T.nilable(Integer), default: nil

    sig { params(path: T.any(String, Symbol, PlaceId)).returns(PlaceId) }
    def self.from_path(path)
      return path if path.is_a?(PlaceId)

      new(path: path.to_s)
    end

    sig { params(path: T.any(String, Symbol), symbol: T.nilable(SymbolEntry)).returns(PlaceId) }
    def self.from_symbol(path, symbol)
      return from_path(path) unless symbol

      name = path.to_s
      new(path: name, binding_name: name, binding_id: symbol.binding_id)
    end

    sig { returns(T.nilable(BindingId)) }
    def binding_identity
      name = binding_name
      id = binding_id
      return nil unless name && id

      BindingId.new(name: name, binding_id: id)
    end

    private

    sig { returns(T::Boolean) }
    def child?
      path.include?(".")
    end

    public

    sig { returns(T.nilable(PlaceId)) }
    def parent
      return nil unless child?

      PlaceId.from_path(path.rpartition(".").first)
    end

    sig { params(other: T.untyped).returns(T::Boolean) }
    def eql?(other)
      !!(other.is_a?(PlaceId) &&
        path == other.path &&
        binding_name == other.binding_name &&
        binding_id == other.binding_id)
    end

    sig { returns(Integer) }
    def hash
      [path, binding_name, binding_id].hash
    end
  end
end
