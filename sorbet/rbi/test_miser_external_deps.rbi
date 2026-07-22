# typed: true

module Minitest
  class Test
  end
  class SummaryReporter
    extend T::Sig
    sig { params(io: T.untyped).returns(T.untyped) }
    def initialize(io); end
    sig { void }
    def start; end
    sig { returns(T::Array[T.untyped]) }
    def results; end
    sig { void }
    def report; end
  end
end

module SQLite3
  class Exception < StandardError
  end
  class Database
    extend T::Sig
    sig { params(path: String, options: T.untyped).returns(T.untyped) }
    def initialize(path, **options); end
    sig { params(sql: String).returns(T.untyped) }
    def execute(sql); end
  end
end

module RSpec
  extend T::Sig
  sig { returns(T.untyped) }
  def self.configuration; end
end

module TestMiserCIPlan
  class Planner
  end
end

module Mutant
  VERSION = T.let("0.0.0", String)
  WORLD = T.let(T.untyped, T.untyped)

  module Config
    DEFAULT = T.let(T.untyped, T.untyped)
  end
  module Matcher
    module Config
      DEFAULT = T.let(T.untyped, T.untyped)
    end
  end
  module Mutation
    CODE_DELIMITER = T.let("\u0000", String)
    module Config
      DEFAULT = T.let(T.untyped, T.untyped)
    end
  end
  module Reporter
    class Null
    end
  end
  module Usage
    class Opensource
    end
  end
  module Integration
    class Config
      DEFAULT = T.let(T.untyped, T.untyped)
    end
  end
  module Repository
    class Diff < StandardError
      class Error < StandardError
      end
    end
  end
  module Isolation
    class Fork
      Parent = T.let(T.untyped, T.untyped)
      Child = T.let(T.untyped, T.untyped)
    end
  end
  module Bootstrap
    extend T::Sig
    sig { returns(T.untyped) }
    def self.call(*args); end
    sig { returns(T.untyped) }
    def self.call_test(*args); end
  end
  class Env
    extend T::Sig
    sig { params(world: T.untyped, config: T.untyped).returns(T.untyped) }
    def self.empty(world, config); end
  end
  class Error < StandardError
  end
  module Integration
    class Minitest
    end
  end
end
