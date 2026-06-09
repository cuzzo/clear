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

    sig { params(path: T.any(String, Symbol, PlaceId)).returns(PlaceId) }
    def self.from_path(path)
      return path if path.is_a?(PlaceId)

      new(path: path.to_s)
    end

    sig { returns(String) }
    def to_s
      path
    end

    sig { returns(T::Boolean) }
    def child?
      path.include?(".")
    end

    sig { returns(T.nilable(PlaceId)) }
    def parent
      return nil unless child?

      PlaceId.from_path(path.rpartition(".").first)
    end

    sig { params(other: Object).returns(T::Boolean) }
    def ==(other)
      case other
      when PlaceId
        path == other.path
      when String, Symbol
        path == other.to_s
      else
        false
      end
    end

    sig { params(other: Object).returns(T::Boolean) }
    def eql?(other)
      self == other
    end

    sig { returns(Integer) }
    def hash
      path.hash
    end
  end
end
