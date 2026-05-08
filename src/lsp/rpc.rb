require "json"

module LSP
  # JSON-RPC framing for LSP. The protocol wraps every message in a
  # tiny HTTP-like envelope:
  #
  #     Content-Length: <N>\r\n
  #     \r\n
  #     <N bytes of UTF-8 JSON>
  #
  # We read messages by parsing the header, reading exactly N bytes,
  # and JSON-decoding. We write the inverse. Stdout MUST be unbuffered
  # for the client to see frames promptly — the Server sets that.
  #
  # No other output may go to stdout. Logging goes to stderr (the LSP
  # convention; corruption of the stdout frame disconnects the client).
  module RPC
    # Raised when the framing is malformed (missing Content-Length,
    # truncated body, non-JSON payload). The server treats these as
    # fatal — there's no way to recover an out-of-sync stream.
    class FramingError < StandardError; end

    module_function

    # Read the next LSP message from `io`. Returns the parsed Hash, or
    # nil at EOF (clean shutdown). Raises FramingError on malformed
    # frames.
    def read_message(io)
      headers = read_headers(io)
      return nil if headers.nil?  # EOF before any header line

      length_str = headers["content-length"]
      raise FramingError, "missing Content-Length header" if length_str.nil?
      length = Integer(length_str) rescue nil
      raise FramingError, "invalid Content-Length: #{length_str.inspect}" if length.nil?
      raise FramingError, "negative Content-Length: #{length}" if length.negative?

      body = io.read(length)
      raise FramingError, "truncated body (expected #{length} bytes)" if body.nil? || body.bytesize < length

      JSON.parse(body)
    rescue JSON::ParserError => e
      raise FramingError, "JSON parse error: #{e.message}"
    end

    # Write `msg` (a Hash) as an LSP frame to `io`.
    def write_message(io, msg)
      body = JSON.generate(msg)
      io.write("Content-Length: #{body.bytesize}\r\n\r\n#{body}")
      io.flush
    end

    # ---- internals ----

    # Read header lines from `io` until a blank line. Returns a Hash
    # of lowercased header names → values, or nil at EOF before any
    # header line was read.
    def read_headers(io)
      headers = {}
      first = true
      loop do
        line = io.gets
        return nil if line.nil? && first
        raise FramingError, "unexpected EOF in headers" if line.nil?
        line = line.chomp
        break if line.empty?
        first = false
        name, value = line.split(":", 2)
        raise FramingError, "malformed header: #{line.inspect}" if value.nil?
        headers[name.strip.downcase] = value.strip
      end
      headers
    end
  end
end
