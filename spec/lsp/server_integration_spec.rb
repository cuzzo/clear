require "rspec"
require "json"
require "open3"
require "timeout"

# End-to-end driver for `bin/clear-lsp`. Spawns the actual binary
# under `bundle exec` (the compiler uses `require 'bundler/setup'`),
# pipes JSON-RPC frames in, and asserts on the responses written
# back. Tagged `:integration` so it doesn't run during normal
# `bundle exec rspec spec/` invocations — kick it off explicitly:
#
#     bundle exec rspec spec/lsp/server_integration_spec.rb --tag integration
#
# Each example is wrapped in a 5-second timeout so a hung server
# fails fast rather than blocking the suite.
RSpec.describe "clear-lsp end-to-end (binary)", :integration do
  REPO_ROOT = File.expand_path("../../..", __FILE__)
  BIN_PATH  = File.join(REPO_ROOT, "bin", "clear-lsp")

  def frame(msg)
    body = JSON.generate(msg)
    "Content-Length: #{body.bytesize}\r\n\r\n#{body}"
  end

  def parse_frames(raw)
    out = []
    while raw && !raw.empty?
      header_end = raw.index("\r\n\r\n")
      break if header_end.nil?
      length = raw[0...header_end][/Content-Length: (\d+)/i, 1].to_i
      body_start = header_end + 4
      body = raw[body_start, length]
      break unless body && body.bytesize == length
      out << JSON.parse(body)
      raw = raw[(body_start + length)..]
    end
    out
  end

  def drive(input_messages)
    drive_with_args([], input_messages)
  end

  def drive_with_args(extra_args, input_messages)
    input = input_messages.map { |m| frame(m) }.join
    Timeout.timeout(5) do
      stdout, stderr, status = Open3.capture3(
        "bundle", "exec", BIN_PATH, *extra_args,
        stdin_data: input,
        chdir:      REPO_ROOT,
      )
      [parse_frames(stdout), stderr, status]
    end
  end

  it "completes the initialize/shutdown handshake" do
    frames, _stderr, status = drive([
      { jsonrpc: "2.0", id: 1, method: "initialize", params: {} },
      { jsonrpc: "2.0", method: "initialized", params: {} },
      { jsonrpc: "2.0", id: 2, method: "shutdown", params: nil },
      { jsonrpc: "2.0", method: "exit", params: nil },
    ])
    expect(status.exitstatus).to eq(0)

    init  = frames.find { |f| f["id"] == 1 }
    expect(init["result"]["serverInfo"]["name"]).to eq("clear-lsp")
    caps = init["result"]["capabilities"]
    expect(caps["textDocumentSync"]).to eq(1)
    expect(caps["hoverProvider"]).to be true
    expect(caps["codeActionProvider"]["codeActionKinds"]).to include("quickfix", "refactor")

    shutdown = frames.find { |f| f["id"] == 2 }
    expect(shutdown).to have_key("result")
  end

  it "publishes diagnostics on didOpen for source with errors" do
    src = "FN main() RETURNS Void ->\n  _ = doesNotExist;\nEND\n"
    frames, _stderr, status = drive([
      { jsonrpc: "2.0", id: 1, method: "initialize", params: {} },
      { jsonrpc: "2.0", method: "initialized", params: {} },
      { jsonrpc: "2.0", method: "textDocument/didOpen", params: {
        textDocument: { uri: "file:///t.cht", languageId: "clear", version: 1, text: src },
      } },
      { jsonrpc: "2.0", id: 2, method: "shutdown", params: nil },
      { jsonrpc: "2.0", method: "exit", params: nil },
    ])
    expect(status.exitstatus).to eq(0)

    publish = frames.find { |f| f["method"] == "textDocument/publishDiagnostics" }
    expect(publish).not_to be_nil
    diagnostics = publish["params"]["diagnostics"]
    expect(diagnostics.size).to be >= 1
    diag = diagnostics.first
    expect(diag["severity"]).to eq(1)
    expect(diag["source"]).to eq("clear")
    expect(diag["code"]).to eq("UNDEFINED_VAR")
    # `doesNotExist` lives on line 1 (0-based) starting at character 6.
    expect(diag["range"]["start"]["line"]).to eq(1)
    expect(diag["range"]["start"]["character"]).to eq(6)
  end

  it "returns code actions for a fixable finding" do
    src = <<~CLEAR
      FN main() RETURNS Void ->
        x = 5;
        WITH RESTRICT x { _ = x; }
      END
    CLEAR
    frames, _stderr, status = drive([
      { jsonrpc: "2.0", id: 1, method: "initialize", params: {} },
      { jsonrpc: "2.0", method: "initialized", params: {} },
      { jsonrpc: "2.0", method: "textDocument/didOpen", params: {
        textDocument: { uri: "file:///t.cht", languageId: "clear", version: 1, text: src },
      } },
      { jsonrpc: "2.0", id: 2, method: "textDocument/codeAction", params: {
        textDocument: { uri: "file:///t.cht" },
        range: { start: { line: 2, character: 0 }, end: { line: 2, character: 100 } },
        context: { diagnostics: [] },
      } },
      { jsonrpc: "2.0", id: 3, method: "shutdown", params: nil },
      { jsonrpc: "2.0", method: "exit", params: nil },
    ])
    expect(status.exitstatus).to eq(0)

    actions = frames.find { |f| f["id"] == 2 }["result"]
    expect(actions.size).to be >= 1
    fix = actions.first
    expect(fix["kind"]).to eq("quickfix")
    expect(fix["isPreferred"]).to be true
    expect(fix["title"]).to match(/MUTABLE/)
    expect(fix["edit"]["documentChanges"].first["edits"].first["newText"]).to eq("MUTABLE ")
  end

  it "renders hover content with registry markdown" do
    src = "FN main() RETURNS Void ->\n  _ = doesNotExist;\nEND\n"
    frames, _stderr, status = drive([
      { jsonrpc: "2.0", id: 1, method: "initialize", params: {} },
      { jsonrpc: "2.0", method: "initialized", params: {} },
      { jsonrpc: "2.0", method: "textDocument/didOpen", params: {
        textDocument: { uri: "file:///t.cht", languageId: "clear", version: 1, text: src },
      } },
      { jsonrpc: "2.0", id: 2, method: "textDocument/hover", params: {
        textDocument: { uri: "file:///t.cht" },
        position:     { line: 1, character: 8 },
      } },
      { jsonrpc: "2.0", id: 3, method: "shutdown", params: nil },
      { jsonrpc: "2.0", method: "exit", params: nil },
    ])
    expect(status.exitstatus).to eq(0)

    hover = frames.find { |f| f["id"] == 2 }["result"]
    expect(hover["contents"]["kind"]).to eq("markdown")
    md = hover["contents"]["value"]
    expect(md).to include("UNDEFINED_VAR")
    expect(md).to include("**Cause:**")
    expect(md).to include("**Fix:**")
  end

  it "accepts --stdio as a no-op (LSP clients pass it by default)" do
    # vscode-languageclient appends --stdio when configured for stdio
    # transport. Our binary must not reject it.
    frames, _stderr, status = drive_with_args(["--stdio"], [
      { jsonrpc: "2.0", id: 1, method: "initialize", params: {} },
      { jsonrpc: "2.0", id: 2, method: "shutdown", params: nil },
      { jsonrpc: "2.0", method: "exit", params: nil },
    ])
    expect(status.exitstatus).to eq(0)
    expect(frames.find { |f| f["id"] == 1 }["result"]["serverInfo"]["name"]).to eq("clear-lsp")
  end

  it "rejects malformed --log-level with exit code 2" do
    _stdout, stderr, status = Open3.capture3(
      "bundle", "exec", BIN_PATH, "--log-level=screaming",
      stdin_data: "",
      chdir:      REPO_ROOT,
    )
    expect(status.exitstatus).to eq(2)
    expect(stderr).to include("unknown --log-level")
  end

  it "shows usage on --help" do
    stdout, _stderr, status = Open3.capture3(
      "bundle", "exec", BIN_PATH, "--help",
      stdin_data: "",
      chdir:      REPO_ROOT,
    )
    expect(status.exitstatus).to eq(0)
    expect(stdout).to include("Usage: clear-lsp")
  end
end
