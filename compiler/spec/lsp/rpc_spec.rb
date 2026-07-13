require "rspec"
require "stringio"
require_relative "../../ruby/lsp/rpc" unless defined?(LSP::RPC::FramingError)

# Round-trip tests for LSP::RPC. The framing is the foundation — if
# this fails, every higher-layer feature breaks.
RSpec.describe LSP::RPC do
  describe ".write_message + .read_message round-trip" do
    it "encodes and decodes a simple request" do
      io = StringIO.new
      LSP::RPC.write_message(io, { jsonrpc: "2.0", id: 1, method: "initialize", params: {} })
      io.rewind
      msg = LSP::RPC.read_message(io)
      expect(msg).to eq({
        "jsonrpc" => "2.0",
        "id"      => 1,
        "method"  => "initialize",
        "params"  => {},
      })
    end

    it "round-trips multi-byte UTF-8 in the body" do
      io = StringIO.new
      payload = { jsonrpc: "2.0", id: 7, result: "héllo — wörld" }
      LSP::RPC.write_message(io, payload)
      io.rewind
      msg = LSP::RPC.read_message(io)
      expect(msg["result"]).to eq("héllo — wörld")
    end

    it "writes a properly-formatted Content-Length header" do
      io = StringIO.new
      LSP::RPC.write_message(io, { jsonrpc: "2.0", id: 1, result: "ok" })
      io.rewind
      raw = io.read
      expect(raw).to start_with("Content-Length: ")
      expect(raw).to include("\r\n\r\n")
      header, body = raw.split("\r\n\r\n", 2)
      length = header[/Content-Length: (\d+)/, 1].to_i
      expect(body.bytesize).to eq(length)
    end

    it "handles consecutive frames in one stream" do
      io = StringIO.new
      LSP::RPC.write_message(io, { id: 1, method: "a" })
      LSP::RPC.write_message(io, { id: 2, method: "b" })
      io.rewind
      first  = LSP::RPC.read_message(io)
      second = LSP::RPC.read_message(io)
      expect(first["id"]).to eq(1)
      expect(second["id"]).to eq(2)
    end
  end

  describe ".read_message" do
    it "returns nil at EOF before any header" do
      io = StringIO.new("")
      expect(LSP::RPC.read_message(io)).to be_nil
    end

    it "raises FramingError when Content-Length is missing" do
      io = StringIO.new("X-Other: 1\r\n\r\n{}")
      expect {
        LSP::RPC.read_message(io)
      }.to raise_error(LSP::RPC::FramingError, /missing Content-Length/)
    end

    it "raises FramingError when Content-Length isn't numeric" do
      io = StringIO.new("Content-Length: not-a-number\r\n\r\n{}")
      expect {
        LSP::RPC.read_message(io)
      }.to raise_error(LSP::RPC::FramingError, /invalid Content-Length/)
    end

    it "raises FramingError when Content-Length is negative" do
      io = StringIO.new("Content-Length: -5\r\n\r\n{}")
      expect {
        LSP::RPC.read_message(io)
      }.to raise_error(LSP::RPC::FramingError, /negative Content-Length/)
    end

    it "raises FramingError when the body is truncated" do
      # Content-Length advertises 100 bytes; only 5 are actually present.
      io = StringIO.new("Content-Length: 100\r\n\r\nshort")
      expect {
        LSP::RPC.read_message(io)
      }.to raise_error(LSP::RPC::FramingError, /truncated body/)
    end

    it "raises FramingError on malformed JSON" do
      raw = "not valid json"
      io = StringIO.new("Content-Length: #{raw.bytesize}\r\n\r\n#{raw}")
      expect {
        LSP::RPC.read_message(io)
      }.to raise_error(LSP::RPC::FramingError, /JSON parse error/)
    end

    it "raises FramingError on a malformed header line" do
      io = StringIO.new("not-a-header-just-a-string\r\n\r\n{}")
      expect {
        LSP::RPC.read_message(io)
      }.to raise_error(LSP::RPC::FramingError, /malformed header/)
    end

    it "raises FramingError on EOF mid-header" do
      io = StringIO.new("Content-Length: 5\r\n")  # no blank line ending headers
      expect {
        LSP::RPC.read_message(io)
      }.to raise_error(LSP::RPC::FramingError, /unexpected EOF/)
    end

    it "is case-insensitive on header names" do
      raw = '{"id":1}'
      io = StringIO.new("CONTENT-LENGTH: #{raw.bytesize}\r\n\r\n#{raw}")
      msg = LSP::RPC.read_message(io)
      expect(msg["id"]).to eq(1)
    end
  end
end
