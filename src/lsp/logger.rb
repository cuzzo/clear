# typed: strict
require "sorbet-runtime"

module LSP
  # Stderr logger. LSP clients display the server's stderr — never
  # write log output to stdout (that's reserved for JSON-RPC frames).
  class Logger
      extend T::Sig

    LEVELS = T.let({ debug: 0, info: 1, warn: 2, error: 3 }.freeze, T::Hash[Symbol, Integer])

    sig { params(level: Symbol, io: IO).void }
    def initialize(level: :info, io: $stderr)
      @level = T.let(LEVELS.fetch(level), Integer)
      @io    = T.let(io, IO)
    end

    sig { params(msg: String).returns(T.untyped) }
    def debug(msg); log(:debug, msg); end
    sig { params(msg: String).returns(T.untyped) }
    def info(msg);  log(:info,  msg); end
    sig { params(msg: String).returns(T.untyped) }
    def warn(msg);  log(:warn,  msg); end
    sig { params(msg: String).returns(IO) }
    def error(msg); T.must(log(:error, msg)); end

    private

    sig { params(level: Symbol, msg: String).returns(T.nilable(IO)) }
    def log(level, msg)
      return if LEVELS.fetch(level) < @level
      ts = Time.now.strftime("%H:%M:%S.%3N")
      @io.write("[#{ts}] [clear-lsp/#{level}] #{msg}\n")
      @io.flush
    end
  end
end
