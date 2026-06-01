# typed: strict
require "sorbet-runtime"

require_relative "mir"
require_relative "cleanup_entry"
require_relative "placement"
require_relative "../ast/type"

module MIR
  class MaterializationPacket < T::Struct
    extend T::Sig

    const :alloc_mark, T.nilable(MIR::AllocMark)
    const :value_stmt, T.nilable(MIR::Stmt)
    const :cleanup_stmt, T.nilable(MIR::Stmt)

    sig { params(value_stmt: MIR::Stmt).returns(MaterializationPacket) }
    def self.value_only(value_stmt)
      new(alloc_mark: nil, value_stmt: value_stmt, cleanup_stmt: nil)
    end

    sig { params(alloc_mark: MIR::AllocMark, cleanup_stmt: T.nilable(MIR::Stmt)).returns(MaterializationPacket) }
    def self.markers(alloc_mark, cleanup_stmt = nil)
      new(alloc_mark: alloc_mark, value_stmt: nil, cleanup_stmt: cleanup_stmt)
    end

    sig do
      params(
        alloc_mark: MIR::AllocMark,
        value_stmt: MIR::Stmt,
        cleanup_stmt: T.nilable(MIR::Stmt),
      ).returns(MaterializationPacket)
    end
    def self.owned(alloc_mark, value_stmt, cleanup_stmt = nil)
      new(alloc_mark: alloc_mark, value_stmt: value_stmt, cleanup_stmt: cleanup_stmt)
    end

    sig { returns(T::Array[MIR::Stmt]) }
    def statements
      out = T.let([], T::Array[MIR::Stmt])
      out << T.must(alloc_mark) if alloc_mark
      out << T.must(value_stmt) if value_stmt
      out << T.must(cleanup_stmt) if cleanup_stmt
      out
    end
  end

  class BindingMaterialization < T::Struct
    extend T::Sig

    const :name, String
    const :expr, MIR::Node
    const :alloc, Symbol
    const :type_info, Type
    const :mutable, T::Boolean
    const :annotation, T.nilable(String), default: nil
    const :suppression, T.nilable(String), default: nil
    const :cleanup_entry, T.nilable(CleanupEntry), default: nil
    const :cleanup_mode, Symbol, default: :normal
    const :scope, T.nilable(Symbol), default: nil

    sig { returns(MIR::AllocMark) }
    def alloc_mark
      MIR::AllocMark.new(name, alloc, type_info, scope || MIR::Placement.alloc_scope(alloc))
    end

    sig { returns(MIR::Let) }
    def let_node
      MIR::Let.new(name, expr, mutable, annotation, suppression)
    end

    sig { returns(T.nilable(MIR::Stmt)) }
    def cleanup_stmt
      entry = cleanup_entry
      return nil unless entry

      cleanup_mode == :err ? MIR::ErrCleanup.new(name, entry) : MIR::Cleanup.new(name, entry)
    end

    sig { returns(MaterializationPacket) }
    def packet
      MaterializationPacket.owned(alloc_mark, let_node, cleanup_stmt)
    end

    sig { returns(T::Array[MIR::Stmt]) }
    def statements
      packet.statements
    end
  end
end
