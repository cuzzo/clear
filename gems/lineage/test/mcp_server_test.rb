# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "fileutils"
require "open3"
require "sqlite3"
require "tmpdir"

# End-to-end coverage for the MVP MCP server (tools/mcp_server.rb) over its
# real stdio JSON-RPC transport, against a real lineage.db built the normal
# way (init -> build -> ingest-*), not synthetic fixtures.
class McpServerTest < Minitest::Test
  LINEAGE_BIN = File.expand_path("../target/release/lineage", __dir__)
  MCP_SERVER = File.expand_path("../tools/mcp_server.rb", __dir__)

  def setup
    skip "lineage binary missing; build gems/lineage first" unless File.executable?(LINEAGE_BIN)
  end

  def test_all_five_tools_over_stdio
    Dir.mktmpdir do |repo|
      FileUtils.mkdir_p(File.join(repo, "src"))
      worker_path = File.join(repo, "src/worker.rb")
      File.write(worker_path, <<~RUBY)
        class Worker
          def run
            1
          end
        end
      RUBY

      Dir.chdir(repo) do
        run!("git init -q")
        run!("git config user.email t@t")
        run!("git config user.name t")
        run!("git add -A")
        run!("git commit -qm init")
      end

      db = File.join(repo, "lineage.db")
      run!([LINEAGE_BIN, "init", "--db", db])
      run!([LINEAGE_BIN, "build", "--db", db, "--repo", repo])

      # A second commit gives change_history real events to find, and moves
      # the unit's line so unit_context is exercised against updated state.
      File.write(worker_path, <<~RUBY)
        class Worker
          # a comment pushes the body down a line
          def run
            2
          end
        end
      RUBY
      Dir.chdir(repo) do
        run!("git add -A")
        run!("git commit -qm 'nudge run down a line'")
      end
      commit_2 = Dir.chdir(repo) { `git rev-parse HEAD`.strip }
      run!([LINEAGE_BIN, "build", "--db", db, "--repo", repo])

      # Hotness against the current (post-nudge) line 3: exercises
      # unit_context's hotness section and find_definition.
      hotness = File.join(repo, "hotness.json")
      File.write(hotness, JSON.generate(
        "schema" => "profile-hotness/v1", "source" => "test:mcp", "commit" => commit_2,
        "entries" => [{
          "function" => "Worker#run", "path" => "src/worker.rb", "line" => 3,
          "flat_share" => 0.4, "cum_share" => 0.62, "tier" => "critical"
        }]
      ))
      run!([LINEAGE_BIN, "ingest-hotness", "--db", db, "--repo", repo, "--input", hotness])

      # A hazard on the (now-moved) def-run line: exercises verification_gaps
      # and unit_context's hazards section. Inserted directly against the
      # reused insert_hazard_event.sql, mirroring how the Rust unit tests
      # construct hazard fixtures - ingest-hazards only scans systems
      # languages (zig/go/rust/c/cpp/csharp), not Ruby.
      unit_id = SQLite3::Database.new(db).execute(
        "SELECT id FROM logical_units WHERE name LIKE '%run%' LIMIT 1"
      ).first.first
      writable = SQLite3::Database.new(db)
      writable.execute(
        File.read(File.expand_path("../sql/storage/insert_hazard_event.sql", __dir__)),
        [unit_id, "ruby", "ruby_metaprogramming", "nil-kill", "src/worker.rb", 3, "run",
         "test-fixture", "commit-1", 1, "{}"]
      )
      writable.close

      client = McpStdioClient.spawn("ruby", MCP_SERVER, "--db", db, "--repo", repo)
      begin
        client.initialize!
        tool_names = client.list_tools
        assert_equal(
          %w[lineage_file_risk lineage_unit_context lineage_verification_gaps
             lineage_change_history lineage_find_definition].sort,
          tool_names.sort
        )

        context = client.call_tool("lineage_unit_context", { "path" => "src/worker.rb", "line" => 3 })
        assert_equal "Worker.run", context.dig("unit", "name")
        # A real `events` row exists after the second commit, so the span is
        # the method's true multi-line extent (def/body/end), not the
        # single-line first-commit fallback.
        assert_equal [3, 5], context["span"]
        hazard = context["hazards"].find { |h| h["hazard_type"] == "ruby_metaprogramming" }
        refute_nil hazard
        # The actual triggering source line, not just its classification -
        # otherwise a caller needs a second, separate file read to see what
        # was flagged.
        assert_equal "test-fixture", hazard["snippet"]
        assert(context["hotness"].any? { |h| h["tier"] == "critical" })

        risk = client.call_tool("lineage_file_risk", { "path" => "src/" })
        assert_equal "src/*", risk["scope"]
        assert(risk["files"].any? { |f| f["current_path"] == "src/worker.rb" && f["open_hazards"] == 1 })

        gaps = client.call_tool("lineage_verification_gaps", { "path" => "src/worker.rb" })
        gap_hazard = gaps["open_hazards"].find { |h| h["hazard_type"] == "ruby_metaprogramming" }
        refute_nil gap_hazard
        assert_equal "test-fixture", gap_hazard["snippet"]
        assert_equal "run", gap_hazard["symbol"]

        history = client.call_tool("lineage_change_history", { "path" => "src/worker.rb" })
        assert_operator history["events"].size, :>=, 1

        definitions = client.call_tool("lineage_find_definition", { "name" => "run" })
        assert(definitions["definitions"].any? { |d| d["path"] == "src/worker.rb" })

        # Unknown tool -> JSON-RPC error, not a crash.
        error = client.request("tools/call", { "name" => "not_a_real_tool", "arguments" => {} })
        refute_nil error["error"]
      ensure
        client.shutdown!
      end
    end
  end

  private

  def run!(command)
    if command.is_a?(String)
      system(command, exception: true)
    else
      _stdout, stderr, status = Open3.capture3(*command)
      raise "#{command.join(" ")} failed: #{stderr}" unless status.success?
    end
  end
end

# Minimal MCP JSON-RPC-over-stdio client, symmetric to LspStdioClient in
# lsp_integration_test.rb (same Content-Length framing).
class McpStdioClient
  def self.spawn(*command)
    stdin, stdout, wait_thread = Open3.popen2(*command)
    stdin.sync = true
    new(stdin, stdout, wait_thread)
  end

  def initialize(stdin, stdout, wait_thread)
    @stdin = stdin
    @stdout = stdout
    @wait_thread = wait_thread
    @next_id = 1
  end

  def initialize!
    request("initialize", { "protocolVersion" => "2024-11-05" })
    notify("notifications/initialized", {})
  end

  def list_tools
    request("tools/list", {}).dig("result", "tools").map { |tool| tool["name"] }
  end

  def call_tool(name, arguments)
    response = request("tools/call", { "name" => name, "arguments" => arguments })
    raise "tool call transport error: #{response["error"]}" if response["error"]

    result = response.dig("result")
    raise "tool #{name} returned isError: #{result["content"]}" if result["isError"]

    JSON.parse(result.dig("content", 0, "text"))
  end

  def request(method, params)
    id = @next_id
    @next_id += 1
    write({ "jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params })
    loop do
      message = read_message
      return message if message["id"] == id
    end
  end

  def notify(method, params)
    write({ "jsonrpc" => "2.0", "method" => method, "params" => params })
  end

  def shutdown!
    @stdin.close
    @stdout.close
    # Closing stdin is EOF to the server's read loop, which exits on its
    # own; only escalate to SIGTERM if it doesn't within a short grace
    # period (avoids a harmless-but-noisy SignalException warning).
    return if @wait_thread.join(2)

    Process.kill("TERM", @wait_thread.pid)
    @wait_thread.join(2)
  rescue IOError, Errno::ESRCH
    nil
  end

  private

  def read_message
    headers = {}
    loop do
      line = @stdout.readline("\r\n").chomp("\r\n")
      break if line.empty?

      key, value = line.split(": ", 2)
      headers[key] = value
    end
    length = Integer(headers.fetch("Content-Length"))
    JSON.parse(@stdout.read(length))
  end

  def write(payload)
    json = JSON.generate(payload)
    @stdin.write("Content-Length: #{json.bytesize}\r\n\r\n#{json}")
    @stdin.flush
  end
end
