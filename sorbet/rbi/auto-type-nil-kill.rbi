# typed: true

module NilKill
  ROOT = T.let(T.unsafe(nil), String)
  TMP_DIR = T.let(T.unsafe(nil), String)
  HIGH = T.let(T.unsafe(nil), String)
  REVIEW = T.let(T.unsafe(nil), String)

  sig { void }
  def self.ensure_src_restored!; end

  sig { returns(T::Array[String]) }
  def self.target_files; end

  sig { params(path: T.any(String, Pathname)).returns(String) }
  def self.rel(path); end

  module Syntax
    class Node; end
    class ArrayNode < Node; end
    class CallNode < Node; end
    class ClassNode < Node; end
    class ClassVariableWriteNode < Node; end
    class ConstantWriteNode < Node; end
    class DefNode < Node; end
    class FalseNode < Node; end
    class GlobalVariableWriteNode < Node; end
    class HashNode < Node; end
    class InstanceVariableWriteNode < Node; end
    class IntegerNode < Node; end
    class KeywordHashNode < Node; end
    class LocalVariableWriteNode < Node; end
    class ModuleNode < Node; end
    class NilNode < Node; end
    class StringNode < Node; end
    class SymbolNode < Node; end
    class TrueNode < Node; end

    sig { params(source: String).returns(T.untyped) }
    def self.parse(source); end
  end

  class Store
    sig { returns(T::Hash[String, T.untyped]) }
    def self.read; end
  end

  class Infer
    sig { params(argv: T::Array[String]).void }
    def initialize(argv); end

    sig { void }
    def run; end
  end

  class SpecDependencyIndex
    sig { returns(SpecDependencyIndex) }
    def self.instance; end

    sig { params(paths: T::Array[String]).returns(T::Array[String]) }
    def specs_depending_on(paths); end
  end

  class Z3Solver
    sig { params(evidence: T::Hash[String, T.untyped], files: T::Array[String]).void }
    def initialize(evidence, files); end

    sig { params(actions: T::Array[T::Hash[String, T.untyped]]).returns(T::Boolean) }
    def consistent?(actions); end

    sig { params(action: T::Hash[String, T.untyped]).returns(T.nilable(String)) }
    def preflight_rejection(action); end

    sig { params(action: T::Hash[String, T.untyped]).returns(T::Boolean) }
    def provably_dead_safe_nav?(action); end

    sig { params(evidence: T::Hash[String, T.untyped]).returns(T::Array[T::Hash[String, T.untyped]]) }
    def infer_unobserved_params(evidence); end
  end
end
