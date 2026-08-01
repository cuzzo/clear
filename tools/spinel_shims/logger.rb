# frozen_string_literal: true

# Minimal Logger for Spinel. The compiler uses a single global logger with a
# level and the four severity methods; none of stdlib Logger's formatting,
# rotation or IO plumbing is reached.
class Logger
  DEBUG = 0
  INFO = 1
  WARN = 2
  ERROR = 3
  FATAL = 4

  attr_accessor :level

  def initialize(io = nil, level: INFO)
    @io = io
    @level = level
  end

  def debug(message = nil) = emit(DEBUG, "DEBUG", message)
  def info(message = nil)  = emit(INFO,  "INFO",  message)
  def warn(message = nil)  = emit(WARN,  "WARN",  message)
  def error(message = nil) = emit(ERROR, "ERROR", message)
  def fatal(message = nil) = emit(FATAL, "FATAL", message)

  def emit(severity, label, message)
    return nil if severity < @level

    warn_text = message.nil? ? (block_given? ? yield : "") : message
    $stderr.puts("#{label}: #{warn_text}")
    nil
  end
end
