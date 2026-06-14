require "rspec"
require "stringio"
require_relative "../../src/lsp/server" unless defined?(LSP::Server)

# Lifecycle tests for LSP::Server. Drives the server with canned
# stdin frames and asserts on the responses written to stdout.
# The server exits on `exit` notification or stdin EOF; we stub
# `Kernel.exit` to keep the spec process alive.
RSpec.describe LSP::Server do
  let(:stdin)  { StringIO.new }
  let(:stdout) { StringIO.new }

  # Tests use a tiny debounce so they don't block. Production runs at
  # the default 500ms.
  def server(debounce_ms: 5)
    LSP::Server.new(stdin: stdin, stdout: stdout, log_level: :error, debounce_ms: debounce_ms)
  end

  def write(io, msg)
    body = JSON.generate(msg)
    io.write("Content-Length: #{body.bytesize}\r\n\r\n#{body}")
  end

  def read_responses(io)
    io.rewind
    out = []
    until io.eof?
      msg = LSP::RPC.read_message(io)
      break if msg.nil?
      out << msg
    end
    out
  end

  describe "initialize / initialized handshake" do
    it "responds to `initialize` with a capabilities envelope" do
      write(stdin, jsonrpc: "2.0", id: 1, method: "initialize", params: {})
      stdin.rewind

      # Stub exit so we can drive a clean shutdown afterwards.
      allow_any_instance_of(LSP::Server).to receive(:handle_exit) { throw :stop }

      catch(:stop) { server.run }

      responses = read_responses(stdout)
      expect(responses.first["id"]).to eq(1)
      expect(responses.first["result"]).to include("capabilities")
      expect(responses.first["result"]["serverInfo"]["name"]).to eq("clear-lsp")
    end

    it "accepts an `initialized` notification (no response)" do
      write(stdin, jsonrpc: "2.0", id: 1, method: "initialize", params: {})
      write(stdin, jsonrpc: "2.0", method: "initialized", params: {})
      stdin.rewind

      server.run  # stdin EOF → loop exits naturally

      responses = read_responses(stdout)
      # Only the `initialize` response — `initialized` is a notification.
      expect(responses.size).to eq(1)
      expect(responses.first["id"]).to eq(1)
    end
  end

  describe "shutdown / exit handshake" do
    it "responds to `shutdown` with a null result" do
      write(stdin, jsonrpc: "2.0", id: 1, method: "initialize", params: {})
      write(stdin, jsonrpc: "2.0", id: 2, method: "shutdown", params: nil)
      stdin.rewind

      server.run

      responses = read_responses(stdout)
      shutdown_resp = responses.find { |r| r["id"] == 2 }
      expect(shutdown_resp).not_to be_nil
      expect(shutdown_resp).to have_key("result")
      expect(shutdown_resp["result"]).to be_nil
    end

    it "exits with code 0 after `shutdown` then `exit`" do
      write(stdin, jsonrpc: "2.0", id: 1, method: "shutdown", params: nil)
      write(stdin, jsonrpc: "2.0", method: "exit", params: nil)
      stdin.rewind

      expect { server.run }.to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }
    end

    it "exits with code 1 when `exit` arrives without prior `shutdown`" do
      write(stdin, jsonrpc: "2.0", method: "exit", params: nil)
      stdin.rewind

      expect { server.run }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
    end
  end

  describe "unknown methods" do
    it "responds with -32601 (Method not found) to unknown requests" do
      write(stdin, jsonrpc: "2.0", id: 99, method: "completelyUnknownThing", params: {})
      stdin.rewind

      server.run  # stdin EOF after the one message

      responses = read_responses(stdout)
      err = responses.first
      expect(err["id"]).to eq(99)
      expect(err["error"]["code"]).to eq(-32601)
      expect(err["error"]["message"]).to include("completelyUnknownThing")
    end

    it "silently drops unknown notifications (no response)" do
      write(stdin, jsonrpc: "2.0", method: "$/cancelRequest", params: { id: 5 })
      stdin.rewind

      server.run

      responses = read_responses(stdout)
      expect(responses).to be_empty
    end
  end

  describe "framing errors" do
    it "exits with code 1 on a malformed header" do
      stdin.write("not a header\r\n\r\n{}")
      stdin.rewind

      expect { server.run }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
    end

    it "exits with code 1 on an unexpected exception during dispatch" do
      # Force the dispatcher to raise something that isn't a FramingError.
      write(stdin, jsonrpc: "2.0", id: 1, method: "initialize", params: {})
      stdin.rewind

      srv = server
      allow(srv).to receive(:dispatch).and_raise(RuntimeError, "boom")
      expect { srv.run }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
    end
  end

  describe "EOF handling" do
    it "exits cleanly when stdin closes with no pending messages" do
      stdin.rewind  # empty stdin
      expect { server.run }.not_to raise_error
    end
  end

  describe "textDocument lifecycle" do
    let(:uri) { "file:///tmp/test.cht" }

    def open_doc(text, version: 1)
      write(stdin, jsonrpc: "2.0", method: "textDocument/didOpen", params: {
        textDocument: { uri: uri, languageId: "clear", version: version, text: text },
      })
    end

    it "publishes diagnostics on didOpen for source with errors" do
      open_doc("FN main() RETURNS Void ->\n  _ = doesNotExist;\nEND\n")
      stdin.rewind
      server.run

      responses = read_responses(stdout)
      publish = responses.find { |r| r["method"] == "textDocument/publishDiagnostics" }
      expect(publish).not_to be_nil
      expect(publish["params"]["uri"]).to eq(uri)
      expect(publish["params"]["diagnostics"]).not_to be_empty
      diag = publish["params"]["diagnostics"].first
      expect(diag["severity"]).to eq(1)
      expect(diag["source"]).to eq("clear")
      expect(diag["message"]).to match(/Undefined variable/)
    end

    it "publishes an empty diagnostics array for clean source" do
      open_doc("FN main() RETURNS Void -> END\n")
      stdin.rewind
      server.run

      responses = read_responses(stdout)
      publish = responses.find { |r| r["method"] == "textDocument/publishDiagnostics" }
      expect(publish).not_to be_nil
      expect(publish["params"]["diagnostics"]).to eq([])
    end

    it "republishes after didChange (debounced full sync)" do
      open_doc("FN main() RETURNS Void -> END\n")
      write(stdin, jsonrpc: "2.0", method: "textDocument/didChange", params: {
        textDocument: { uri: uri, version: 2 },
        contentChanges: [{ text: "FN main() RETURNS Void ->\n  _ = doesNotExist;\nEND\n" }],
      })
      stdin.rewind
      srv = server
      srv.run
      srv.flush_pending!

      responses = read_responses(stdout)
      publishes = responses.select { |r| r["method"] == "textDocument/publishDiagnostics" }
      # Two publishes — one for didOpen (immediate, clean), one for
      # didChange (after debounce, broken).
      expect(publishes.size).to eq(2)
      expect(publishes[0]["params"]["diagnostics"]).to eq([])
      expect(publishes[1]["params"]["diagnostics"]).not_to be_empty
    end

    it "republishes after didSave" do
      open_doc("FN main() RETURNS Void -> END\n")
      write(stdin, jsonrpc: "2.0", method: "textDocument/didSave", params: {
        textDocument: { uri: uri },
      })
      stdin.rewind
      server.run

      responses = read_responses(stdout)
      publishes = responses.select { |r| r["method"] == "textDocument/publishDiagnostics" }
      expect(publishes.size).to eq(2)  # didOpen + didSave
    end

    it "clears diagnostics on didClose" do
      open_doc("FN main() RETURNS Void ->\n  _ = doesNotExist;\nEND\n")
      write(stdin, jsonrpc: "2.0", method: "textDocument/didClose", params: {
        textDocument: { uri: uri },
      })
      stdin.rewind
      server.run

      responses = read_responses(stdout)
      last_publish = responses.select { |r| r["method"] == "textDocument/publishDiagnostics" }.last
      expect(last_publish["params"]["diagnostics"]).to eq([])
    end

    it "ignores didChange for an unopened document" do
      write(stdin, jsonrpc: "2.0", method: "textDocument/didChange", params: {
        textDocument: { uri: "file:///nope.cht", version: 1 },
        contentChanges: [{ text: "x" }],
      })
      stdin.rewind

      # Should not crash; no publishDiagnostics for the unknown uri.
      expect { server.run }.not_to raise_error
    end

    it "ignores didChange with empty contentChanges" do
      open_doc("FN main() RETURNS Void -> END\n")
      write(stdin, jsonrpc: "2.0", method: "textDocument/didChange", params: {
        textDocument: { uri: uri, version: 2 },
        contentChanges: [],
      })
      stdin.rewind
      server.run
      # No crash; one publish from didOpen only.
      publishes = read_responses(stdout).select { |r| r["method"] == "textDocument/publishDiagnostics" }
      expect(publishes.size).to eq(1)
    end

    it "rapid didChange notifications coalesce to one analysis" do
      # Three rapid edits of the same document — only the last text
      # should be analysed and published. Use a longer debounce so
      # the messages all arrive before the first timer fires.
      open_doc("FN main() RETURNS Void -> END\n")
      3.times do |i|
        write(stdin, jsonrpc: "2.0", method: "textDocument/didChange", params: {
          textDocument: { uri: uri, version: i + 2 },
          contentChanges: [{ text: "# edit #{i}\nFN main() RETURNS Void -> END\n" }],
        })
      end
      stdin.rewind

      srv = server(debounce_ms: 50)
      srv.run            # processes all 3 didChange synchronously
      srv.flush_pending! # waits for the single pending timer

      publishes = read_responses(stdout).select { |r| r["method"] == "textDocument/publishDiagnostics" }
      # didOpen (immediate) + exactly one debounced analysis.
      expect(publishes.size).to eq(2)
    end

    it "didSave cancels any pending debounced timer and analyses immediately" do
      open_doc("FN main() RETURNS Void -> END\n")
      write(stdin, jsonrpc: "2.0", method: "textDocument/didChange", params: {
        textDocument: { uri: uri, version: 2 },
        contentChanges: [{ text: "FN main() RETURNS Void ->\n  _ = doesNotExist;\nEND\n" }],
      })
      write(stdin, jsonrpc: "2.0", method: "textDocument/didSave", params: {
        textDocument: { uri: uri },
      })
      stdin.rewind

      # Use a long debounce so the didChange timer would NOT fire
      # before didSave cancels it. If cancellation works, exactly
      # 2 publishes (didOpen + didSave); the didChange's timer
      # never gets to publish.
      srv = server(debounce_ms: 5000)
      srv.run
      srv.flush_pending!

      publishes = read_responses(stdout).select { |r| r["method"] == "textDocument/publishDiagnostics" }
      expect(publishes.size).to eq(2)
      # The save reflects the post-didChange text — it should publish
      # the broken-source diagnostic.
      expect(publishes.last["params"]["diagnostics"]).not_to be_empty
    end

    it "didClose cancels any pending debounced timer" do
      open_doc("FN main() RETURNS Void -> END\n")
      write(stdin, jsonrpc: "2.0", method: "textDocument/didChange", params: {
        textDocument: { uri: uri, version: 2 },
        contentChanges: [{ text: "broken syntax that would error" }],
      })
      write(stdin, jsonrpc: "2.0", method: "textDocument/didClose", params: {
        textDocument: { uri: uri },
      })
      stdin.rewind

      srv = server(debounce_ms: 5000)
      srv.run
      srv.flush_pending!

      publishes = read_responses(stdout).select { |r| r["method"] == "textDocument/publishDiagnostics" }
      # didOpen + didClose's empty publish; the didChange's timer never fires.
      expect(publishes.size).to eq(2)
      expect(publishes.last["params"]["diagnostics"]).to eq([])
    end

    it "logs and recovers when analysis raises an unexpected exception" do
      open_doc("FN main() RETURNS Void -> END\n")
      stdin.rewind

      # Force the diagnostics layer to blow up so we exercise the
      # rescue in analyze_and_publish.
      allow(LSP::Diagnostics).to receive(:from_result).and_raise(RuntimeError, "synthetic")

      expect { server.run }.not_to raise_error
      # No publishDiagnostics — the rescue swallowed it.
      publishes = read_responses(stdout).select { |r| r["method"] == "textDocument/publishDiagnostics" }
      expect(publishes).to be_empty
    end
  end

  describe "initialize advertises capabilities" do
    it "declares textDocumentSync = 1 (full sync)" do
      write(stdin, jsonrpc: "2.0", id: 1, method: "initialize", params: {})
      stdin.rewind
      server.run

      caps = read_responses(stdout).first["result"]["capabilities"]
      expect(caps["textDocumentSync"]).to eq(1)
    end

    it "declares codeActionProvider with quickfix and refactor kinds" do
      write(stdin, jsonrpc: "2.0", id: 1, method: "initialize", params: {})
      stdin.rewind
      server.run

      caps = read_responses(stdout).first["result"]["capabilities"]
      expect(caps["codeActionProvider"]["codeActionKinds"]).to include("quickfix", "refactor")
    end

    it "declares hoverProvider = true" do
      write(stdin, jsonrpc: "2.0", id: 1, method: "initialize", params: {})
      stdin.rewind
      server.run

      caps = read_responses(stdout).first["result"]["capabilities"]
      expect(caps["hoverProvider"]).to be true
    end
  end

  describe "textDocument/hover" do
    let(:uri) { "file:///tmp/test.cht" }

    it "renders hover content for a position with an overlapping diagnostic" do
      write(stdin, jsonrpc: "2.0", method: "textDocument/didOpen", params: {
        textDocument: { uri: uri, languageId: "clear", version: 1, text: "FN main() RETURNS Void ->\n  _ = doesNotExist;\nEND\n" },
      })
      # Cursor on line 1 (0-based), inside `doesNotExist`.
      write(stdin, jsonrpc: "2.0", id: 2, method: "textDocument/hover", params: {
        textDocument: { uri: uri },
        position:     { line: 1, character: 8 },
      })
      stdin.rewind
      server.run

      hover_resp = read_responses(stdout).find { |r| r["id"] == 2 }
      expect(hover_resp).not_to be_nil
      result = hover_resp["result"]
      expect(result).not_to be_nil
      expect(result["contents"]["kind"]).to eq("markdown")
      # Hover renders the registry summary for known codes; for
      # UNDEFINED_VAR that's "The named binding does not exist in scope."
      expect(result["contents"]["value"]).to include("UNDEFINED_VAR")
    end

    it "returns null when no diagnostic overlaps the cursor" do
      write(stdin, jsonrpc: "2.0", method: "textDocument/didOpen", params: {
        textDocument: { uri: uri, languageId: "clear", version: 1, text: "FN main() RETURNS Void -> END\n" },
      })
      write(stdin, jsonrpc: "2.0", id: 2, method: "textDocument/hover", params: {
        textDocument: { uri: uri },
        position:     { line: 0, character: 5 },
      })
      stdin.rewind
      server.run

      hover_resp = read_responses(stdout).find { |r| r["id"] == 2 }
      expect(hover_resp["result"]).to be_nil
    end
  end

  describe "textDocument/codeAction" do
    let(:uri) { "file:///tmp/test.cht" }

    # Source that has a Tier 1 :auto fix (WITH_RESTRICT_NEEDS_MUTABLE).
    let(:src_with_fix) {
      <<~CLEAR
        FN main() RETURNS Void ->
          x = 5;
          WITH RESTRICT x { _ = x; }
        END
      CLEAR
    }

    def open_doc(text)
      write(stdin, jsonrpc: "2.0", method: "textDocument/didOpen", params: {
        textDocument: { uri: uri, languageId: "clear", version: 1, text: text },
      })
    end

    def request_action(id, range)
      write(stdin, jsonrpc: "2.0", id: id, method: "textDocument/codeAction", params: {
        textDocument: { uri: uri },
        range:        range,
        context:      { diagnostics: [] },
      })
    end

    it "returns the fixable findings overlapping the request range" do
      open_doc(src_with_fix)
      # The WITH RESTRICT diagnostic lands on line 3 (0-based 2).
      request_action(2, {
        start: { line: 2, character: 0 },
        end:   { line: 2, character: 100 },
      })
      stdin.rewind
      server.run

      responses = read_responses(stdout)
      action_resp = responses.find { |r| r["id"] == 2 }
      expect(action_resp).not_to be_nil
      actions = action_resp["result"]
      expect(actions.size).to be >= 1

      first = actions.first
      expect(first["kind"]).to eq("quickfix")
      expect(first["title"]).to match(/MUTABLE/)
      expect(first["isPreferred"]).to be true

      edit = first["edit"]["documentChanges"].first["edits"].first
      expect(edit["newText"]).to eq("MUTABLE ")
    end

    it "returns an empty array when the range doesn't overlap any finding" do
      open_doc(src_with_fix)
      # Request at line 0 — the diagnostics are on later lines.
      request_action(2, {
        start: { line: 0, character: 0 },
        end:   { line: 0, character: 5 },
      })
      stdin.rewind
      server.run

      action_resp = read_responses(stdout).find { |r| r["id"] == 2 }
      expect(action_resp["result"]).to eq([])
    end

    it "returns an empty array when the document isn't open" do
      request_action(2, {
        start: { line: 0, character: 0 },
        end:   { line: 0, character: 100 },
      })
      stdin.rewind
      server.run

      action_resp = read_responses(stdout).find { |r| r["id"] == 2 }
      expect(action_resp["result"]).to eq([])
    end
  end
end
