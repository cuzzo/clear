# typed: true
require "sorbet-runtime"

module LSP
  # Stderr logger. LSP clients display the server's stderr — never
  # write log output to stdout (that's reserved for JSON-RPC frames).
  class Logger
      extend T::Sig

    LEVELS = { debug: 0, info: 1, warn: 2, error: 3 }.freeze

    def initialize(level: :info, io: $stderr)
      @level = LEVELS.fetch(level)
      @io    = io
    end

    sig { params(msg: T.untyped).returns(T.untyped) }
    def debug(msg); log(:debug, msg); end
    sig { params(msg: T.untyped).returns(T.untyped) }
    def info(msg);  log(:info,  msg); end
    def warn(msg);  log(:warn,  msg); end
    sig { params(msg: T.untyped).returns(IO) }
    def error(msg); log(:error, msg); end

    private

    def log(level, msg)
      return if LEVELS.fetch(level) < @level
      ts = Time.now.strftime("%H:%M:%S.%3N")
      @io.write("[#{ts}] [clear-lsp/#{level}] #{msg}\n")
      @io.flush
    end
  end
end
