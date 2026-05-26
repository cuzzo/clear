# typed: strict
require "sorbet-runtime"
require_relative "../ast/type"

module MIR
  module Placement
    extend T::Sig

    class BindingFact < T::Struct
      extend T::Sig

      const :name, String
      const :type_info, Type
      const :storage, Symbol
      const :alloc, Symbol
      const :scope, Symbol
      const :heap_return, T::Boolean
      const :escape_reason, T.nilable(Symbol)

      sig { returns(T::Boolean) }
      def heap?
        alloc == :heap
      end

      sig { returns(T::Boolean) }
      def frame?
        alloc == :frame
      end
    end

    sig { params(value: T.nilable(Symbol), default: Symbol).returns(Symbol) }
    def self.alloc(value, default = :heap)
      return :heap if value == :heap
      return :frame if value == :frame

      default
    end

    sig { params(value: T.nilable(Symbol)).returns(Symbol) }
    def self.cleanup_scope(value)
      alloc(value, :heap) == :heap ? :heap : :iteration
    end

    sig { params(storage: T.nilable(Symbol), cleanup_alloc: T.nilable(Symbol), default: Symbol).returns(Symbol) }
    def self.binding_alloc(storage:, cleanup_alloc:, default: :frame)
      return :heap if storage == :heap
      alloc(cleanup_alloc, default)
    end

    sig { params(value: T.nilable(Symbol), rt_name: T.nilable(String)).returns(String) }
    def self.zig_allocator(value, rt_name)
      rt = rt_name || "rt"
      case alloc(value, :heap)
      when :heap
        "#{rt}.heapAlloc()"
      else
        "#{rt}.frameAlloc()"
      end
    end
  end
end
