# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "fileutils"
require "open3"
require "sqlite3"
require "tmpdir"

# End-to-end coverage for `lineage mcp` over its real stdio JSON-RPC
# transport, against a real lineage.db built the normal way
# (init -> build -> ingest-*), not synthetic fixtures. Mirrors
# lsp_integration_test.rb's pattern of driving the compiled binary directly
# rather than mocking the protocol.
class McpServerTest < Minitest::Test
  LINEAGE_BIN = File.expand_path("../target/release/lineage", __dir__)

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

      client = McpStdioClient.spawn(LINEAGE_BIN, "mcp", "--db", db, "--repo", repo)
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

  # Uncommitted changes: lineage.db reflects the last commit, but a working
  # tree edit adding an `unsafe` block is real, unbuilt risk. unit_context
  # must not silently serve stale (empty) hazards for a dirty file - it
  # should flag the file as dirty and rescan hazards live from disk, using
  # Lineage's own in-process Rust hazard scanner (no subprocess, no rebuild).
  def test_unit_context_live_rescans_hazards_for_a_dirty_rust_file
    Dir.mktmpdir do |repo|
      FileUtils.mkdir_p(File.join(repo, "src"))
      lib_path = File.join(repo, "src/lib.rs")
      File.write(lib_path, <<~RUST)
        pub fn safe_add(a: i32, b: i32) -> i32 {
            a + b
        }
      RUST

      Dir.chdir(repo) do
        run!("git init -q")
        run!("git config user.email t@t")
        run!("git config user.name t")
        run!("git add -A")
        run!("git commit -qm init")
      end

      # A second commit gives the unit a real `events` row, so
      # current_unit_spans_for_path reports its true multi-line extent
      # instead of the first-commit single-line fallback (see the
      # first-commit unit-range fix elsewhere this session). The change must
      # be semantic, not just a comment - normalized_hash strips comments,
      # so a comment-only edit produces no new event.
      File.write(lib_path, <<~RUST)
        pub fn safe_add(a: i32, b: i32) -> i32 {
            a + b + 0
        }
      RUST
      Dir.chdir(repo) do
        run!("git add -A")
        run!("git commit -qm 'no-op addition'")
      end

      db = File.join(repo, "lineage.db")
      run!([LINEAGE_BIN, "init", "--db", db])
      run!([LINEAGE_BIN, "build", "--db", db, "--repo", repo])

      # Uncommitted edit: introduces an unsafe block. Not committed, not
      # rebuilt - the database has no idea this hazard exists yet.
      File.write(lib_path, <<~RUST)
        pub fn safe_add(a: i32, b: i32) -> i32 {
            let ptr = &a as *const i32;
            unsafe { *ptr + b }
        }
      RUST

      client = McpStdioClient.spawn(LINEAGE_BIN, "mcp", "--db", db, "--repo", repo)
      begin
        client.initialize!
        context = client.call_tool("lineage_unit_context", { "path" => "src/lib.rs", "line" => 3 })
        assert_equal "uncommitted-changes", context["dirty"]
        refute_nil context["live_hazards"]
        unsafe_hazard = context["live_hazards"].find { |h| h["hazard_type"] == "rust_unsafe_block" }
        refute_nil unsafe_hazard, "expected a live-rescanned rust_unsafe_block hazard, got #{context["live_hazards"].inspect}"
        assert_equal "miri", unsafe_hazard["required_evidence"]
      ensure
        client.shutdown!
      end
    end
  end

  # DB-less mode: no lineage.db was ever built. unit_context and
  # verification_gaps should still work off live disk content (structure via
  # heuristic extraction, hazards via the same in-process scanner), while a
  # DB-only tool like file_risk fails clearly instead of crashing the server.
  def test_db_less_mode_serves_live_structure_and_hazards_without_a_database
    Dir.mktmpdir do |repo|
      FileUtils.mkdir_p(File.join(repo, "src"))
      File.write(File.join(repo, "src/lib.rs"), <<~RUST)
        pub fn risky(x: *const i32) -> i32 {
            unsafe { *x }
        }
      RUST

      client = McpStdioClient.spawn(LINEAGE_BIN, "mcp", "--repo", repo)
      begin
        client.initialize!

        context = client.call_tool("lineage_unit_context", { "path" => "src/lib.rs", "line" => 2 })
        assert_equal "risky", context.dig("unit", "name")
        assert_match(/no lineage\.db/, context["note"])
        hazard = context["live_hazards"].find { |h| h["hazard_type"] == "rust_unsafe_block" }
        refute_nil hazard

        gaps = client.call_tool("lineage_verification_gaps", { "path" => "src/lib.rs" })
        refute_empty gaps["open_hazards"]

        response = client.request("tools/call", { "name" => "lineage_file_risk", "arguments" => { "path" => "src/" } })
        result = response["result"]
        assert result["isError"], "expected lineage_file_risk to fail cleanly without a database"
      ensure
        client.shutdown!
      end
    end
  end

  # file_risk's avg_line_coverage/avg_mutant_coverage must weight each unit
  # by its current line count, not average flatly - otherwise a 3-line
  # getter and a 200-line function count equally, and one large undertested
  # unit hides behind several tiny well-tested ones. Proves the fix with a
  # concrete before/after: a naive flat average of a 100%-covered 3-line
  # function and a 10%-covered 14-line function is 55.0; the size-weighted
  # average is 25.9, dominated by the larger, worse-covered function.
  def test_file_risk_weights_coverage_by_unit_line_count
    Dir.mktmpdir do |repo|
      FileUtils.mkdir_p(File.join(repo, "src"))
      lib_path = File.join(repo, "src/lib.rs")
      File.write(lib_path, <<~RUST)
        pub fn tiny() -> i32 {
            1
        }

        pub fn big() -> i32 {
            let mut x = 0;
            x += 1;
            x += 2;
            x += 3;
            x += 4;
            x += 5;
            x += 6;
            x += 7;
            x += 8;
            x += 9;
            x
        }
      RUST

      Dir.chdir(repo) do
        run!("git init -q")
        run!("git config user.email t@t")
        run!("git config user.name t")
        run!("git add -A")
        run!("git commit -qm init")
      end

      # A second, semantic commit gives both units a real `events` row, so
      # their spans are true multi-line extents (3 and 14 lines) rather
      # than the first-commit single-line fallback - without this, every
      # unit's weight would degrade to 1 and the "fix" would be untestable
      # (a weighted average of equal weights is the flat average).
      File.write(lib_path, <<~RUST)
        pub fn tiny() -> i32 {
            2
        }

        pub fn big() -> i32 {
            let mut x = 0;
            x += 1;
            x += 2;
            x += 3;
            x += 4;
            x += 5;
            x += 6;
            x += 7;
            x += 8;
            x += 9;
            x += 10;
            x
        }
      RUST
      Dir.chdir(repo) do
        run!("git add -A")
        run!("git commit -qm 'grow big, tweak tiny'")
      end

      db = File.join(repo, "lineage.db")
      run!([LINEAGE_BIN, "init", "--db", db])
      run!([LINEAGE_BIN, "build", "--db", db, "--repo", repo])

      conn = SQLite3::Database.new(db)
      tiny_id = conn.execute("SELECT id FROM logical_units WHERE name LIKE '%tiny%' LIMIT 1").first.first
      big_id = conn.execute("SELECT id FROM logical_units WHERE name LIKE '%big%' LIMIT 1").first.first
      conn.execute("UPDATE logical_units SET current_line_cov = 100.0 WHERE id = ?", [tiny_id])
      conn.execute("UPDATE logical_units SET current_line_cov = 10.0 WHERE id = ?", [big_id])
      conn.close

      client = McpStdioClient.spawn(LINEAGE_BIN, "mcp", "--db", db, "--repo", repo)
      begin
        client.initialize!
        risk = client.call_tool("lineage_file_risk", { "path" => "src/lib.rs" })
        file = risk["files"].find { |f| f["current_path"] == "src/lib.rs" }
        refute_nil file
        assert_equal 2, file["units"]
        # (100 * 3 + 10 * 14) / (3 + 14) = 440 / 17 = 25.88... -> 25.9.
        # The unweighted flat average would have been (100 + 10) / 2 = 55.0.
        assert_equal 25.9, file["avg_line_coverage"]
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

# Minimal MCP JSON-RPC-over-stdio client. Unlike LspStdioClient in
# lsp_integration_test.rb, MCP's stdio transport is newline-delimited JSON
# (one message per line), not Content-Length framed - that framing is an LSP
# convention this codebase's original hand-rolled MVP wrongly assumed MCP
# shared. Porting the server to the spec-compliant rmcp SDK surfaced the
# mismatch immediately: the old MVP could never have talked to a real MCP
# client, only to its own equally-wrong test client.
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
    request(
      "initialize",
      {
        "protocolVersion" => "2024-11-05",
        "capabilities" => {},
        "clientInfo" => { "name" => "mcp_server_test", "version" => "0.0.0" }
      }
    )
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
    JSON.parse(@stdout.readline("\n"))
  end

  def write(payload)
    @stdin.write("#{JSON.generate(payload)}\n")
    @stdin.flush
  end
end
