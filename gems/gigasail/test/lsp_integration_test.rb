# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "fileutils"
require "open3"
require "tmpdir"

# End-to-end coverage for `lineage lsp` over its real stdio JSON-RPC
# transport: go-to-definition (textDocument/definition, backed by
# find_definitions/`/api/definition`) and hotness surfacing in hover,
# gutter updates, and codeLens (previously loaded into every line
# annotation via apply_hotness but never read by any LSP handler).
class LspIntegrationTest < Minitest::Test
  LINEAGE_BIN = File.expand_path("../target/release/lineage", __dir__)

  def setup
    skip "lineage binary missing; build gems/lineage first" unless File.executable?(LINEAGE_BIN)
  end

  def test_definition_and_hotness_over_lsp_stdio
    Dir.mktmpdir do |repo|
      FileUtils.mkdir_p(File.join(repo, "src"))
      worker_path = File.join(repo, "src/worker.rb")
      caller_path = File.join(repo, "src/caller.rb")
      File.write(worker_path, <<~RUBY)
        class Worker
          def run
            1
          end
        end
      RUBY
      File.write(caller_path, <<~RUBY)
        def dispatch(worker)
          worker.run
        end
      RUBY

      Dir.chdir(repo) do
        run!("git init -q")
        run!("git config user.email t@t")
        run!("git config user.name t")
        run!("git add -A")
        run!("git commit -qm init")
      end
      commit = Dir.chdir(repo) { `git rev-parse HEAD`.strip }

      db = File.join(repo, "lineage.db")
      run!([LINEAGE_BIN, "init", "--db", db])
      run!([LINEAGE_BIN, "build", "--db", db, "--repo", repo])

      hotness = File.join(repo, "hotness.json")
      File.write(hotness, JSON.generate(
        "schema" => "profile-hotness/v1",
        "source" => "test:lsp-fixture",
        "commit" => commit,
        "entries" => [
          {
            "function" => "Worker#run", "path" => "src/worker.rb", "line" => 2,
            "flat_share" => 0.4, "cum_share" => 0.62, "tier" => "critical"
          }
        ]
      ))
      run!([LINEAGE_BIN, "ingest-hotness", "--db", db, "--repo", repo, "--input", hotness])

      client = LspStdioClient.spawn(LINEAGE_BIN, "lsp", "--db", db, "--repo", repo)
      begin
        client.initialize!

        # --- go-to-definition: cursor on `run` in `worker.run` (caller.rb)
        # must resolve to Worker#run's def line in worker.rb.
        client.did_open(caller_path, File.read(caller_path))
        definition = client.request("textDocument/definition", {
          "textDocument" => { "uri" => file_uri(caller_path) },
          "position" => { "line" => 1, "character" => 10 } # "  worker.run", inside "run"
        })
        locations = Array(definition["result"])
        refute_empty locations, "expected at least one definition location"
        assert_equal file_uri(worker_path), locations.first["uri"]
        assert_equal 1, locations.first.dig("range", "start", "line"), "0-indexed line 1 = `def run`"

        # --- hotness in hover: the def-run line (1-indexed line 2) is
        # tagged critical; hover must surface both the unit- and
        # line-level hotness rows, which existed in the annotation data
        # before this fix but were never read by hover_for_line.
        client.did_open(worker_path, File.read(worker_path))
        hover = client.request("textDocument/hover", {
          "textDocument" => { "uri" => file_uri(worker_path) },
          "position" => { "line" => 1, "character" => 2 }
        })
        hover_text = hover.dig("result", "contents", "value").to_s
        assert_includes hover_text, "Critical hotpath: 62.0% of runtime profile"
        assert_includes hover_text, "Runtime profile: critical - 62.0% cumulative (test:lsp-fixture)"

        # --- hotness in codeLens: the Worker#run lens title carries the
        # same critical-hotpath suffix the HTML UI's flame icon signals.
        lenses = client.request("textDocument/codeLens", {
          "textDocument" => { "uri" => file_uri(worker_path) }
        })
        titles = Array(lenses["result"]).map { |lens| lens.dig("command", "title") }
        assert(titles.any? { |title| title.to_s.include?("critical hotpath 62.0%") }, titles.inspect)

        # --- hotness in the gutter notification: same critical line
        # produces a "hotness_critical" gutter item alongside coverage.
        gutter = client.wait_for_notification("lineage/gutterUpdate") do |params|
          params["uri"] == file_uri(worker_path)
        end
        kinds = Array(gutter["items"]).map { |item| item["kind"] }
        assert_includes kinds, "hotness_critical"
      ensure
        client.shutdown!
      end
    end
  end

  private

  def file_uri(path)
    "file://#{File.expand_path(path)}"
  end

  def run!(command)
    if command.is_a?(String)
      system(command, exception: true)
    else
      _stdout, stderr, status = Open3.capture3(*command)
      raise "#{command.join(" ")} failed: #{stderr}" unless status.success?
    end
  end
end

# Minimal LSP JSON-RPC-over-stdio client: enough framing and correlation to
# drive one `lineage lsp` subprocess through a handful of requests and
# assert on both responses and server-to-client notifications.
class LspStdioClient
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
    @pending_notifications = []
  end

  def initialize!
    request("initialize", { "processId" => nil, "rootUri" => nil, "capabilities" => {} })
    notify("initialized", {})
  end

  def did_open(path, text)
    notify("textDocument/didOpen", {
      "textDocument" => {
        "uri" => "file://#{File.expand_path(path)}",
        "languageId" => "ruby",
        "version" => 1,
        "text" => text
      }
    })
  end

  def request(method, params)
    id = @next_id
    @next_id += 1
    write({ "jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params })
    read_until { |message| message["id"] == id }
  end

  def notify(method, params)
    write({ "jsonrpc" => "2.0", "method" => method, "params" => params })
  end

  # Blocks until a queued or newly-received notification of `method` for
  # which `block` returns true arrives; matches the standard LSP pattern of
  # awaiting a push (here, Lineage's custom lineage/gutterUpdate) rather than
  # a request/response pair.
  def wait_for_notification(method, timeout: 5)
    deadline = Time.now + timeout
    loop do
      match = @pending_notifications.find { |n| n["method"] == method && (!block_given? || yield(n["params"])) }
      if match
        @pending_notifications.delete(match)
        return match["params"]
      end
      raise "timed out waiting for #{method}" if Time.now > deadline

      @pending_notifications << read_message
    end
  end

  def shutdown!
    request("shutdown", {})
    notify("exit", {})
    @stdin.close
    @stdout.close
    Process.kill("TERM", @wait_thread.pid)
  rescue IOError, Errno::ESRCH
    nil
  ensure
    @wait_thread.join(2)
  end

  private

  def read_until
    loop do
      message = read_message
      if message["id"]
        return message if yield(message)
      else
        @pending_notifications << message
      end
    end
  end

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
