# typed: strict
require "sorbet-runtime"

module MIR
  module Placement
    extend T::Sig

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
