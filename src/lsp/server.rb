# typed: true
require "sorbet-runtime"
require "stringio"

require_relative "rpc"
require_relative "logger"
require_relative "document_store"
require_relative "analyzer"
require_relative "diagnostics"
require_relative "code_actions"
require_relative "hover"

module LSP
  # CLEAR Language Server. The lifecycle pieces (initialize, shutdown,
  # exit) handle protocol setup; the textDocument/* handlers run the
  # canonical Lexer→Parser→SemanticAnnotator pipeline against open
  # documents and publish diagnostics back to the client.
  class Server
      extend T::Sig

    # JSON-RPC 2.0 reserved error codes used by LSP.
    METHOD_NOT_FOUND = -32601

    # `debounce_ms` is configurable so specs can drive the debounce
    # path without sleeping for half a second; production runs at the
    # default 500.
    sig { params(stdin: StringIO, stdout: StringIO, log_level: Symbol, debounce_ms: Integer).void }
    def initialize(stdin: $stdin, stdout: $stdout, log_level: :info, debounce_ms: 500)
      @stdin            = stdin
      @stdout           = stdout
      @stdout.sync      = true
      @logger           = T.let(Logger.new(level: log_level), Logger)
      @initialized      = T.let(false, T::Boolean)
      @shutdown_requested = T.let(false, T::Boolean)
      @docs             = T.let(DocumentStore.new, DocumentStore)
      # FixCollector is module-global; serialise analyses across
      # whatever threads might trigger them.
      @analyze_mutex    = T.let(Mutex.new, Mutex)
      # Stdout writes happen from the main loop AND from timer
      # threads — guard frame integrity.
      @output_mutex     = T.let(Mutex.new, Mutex)
      # Debounce machinery for didChange. One pending timer per uri;
      # rapid edits cancel the prior timer.
      @debounce_ms      = debounce_ms
      @timers           = T.let({}, T::Hash[T.untyped, T.untyped])
      @timer_mutex      = T.let(Mutex.new, Mutex)
    end

    # Main loop. Runs until `exit` notification or stdin EOF.
    sig { returns(T.untyped) }
    def run
      @logger.info("clear-lsp starting")
      loop do
        msg = RPC.read_message(@stdin)
        if msg.nil?
          @logger.info("stdin closed; exiting")
          break
        end
        dispatch(msg)
      end
    rescue RPC::FramingError => e
      @logger.error("framing error: #{e.message}; client stream desynced — exiting")
      exit_code = 1
      Kernel.exit(exit_code)
    rescue => e
      @logger.error("fatal: #{e.class}: #{e.message}\n  #{T.must(e.backtrace).first(5).join("\n  ")}")
      Kernel.exit(1)
    end

    # Synchronously wait for every pending timer thread to complete.
    # Production never needs this — the LSP runs forever and exits
    # via `exit` notification — but tests use it to step past the
    # debounce window deterministically.
    sig { returns(Array) }
    def flush_pending!
      threads = T.let(nil, T.nilable(T::Array[Thread]))
      @timer_mutex.synchronize { threads = @timers.values.dup }
      T.must(threads).each(&:join)
    end

    private

    # Dispatch a parsed message to the right handler. JSON-RPC messages
    # are either requests (have an `id`, expect a response) or
    # notifications (no `id`). Unknown methods get a MethodNotFound
    # error response if it was a request; notifications are dropped
    # silently (per JSON-RPC 2.0 spec).
    sig { params(msg: T::Hash[String, T.untyped]).returns(T.untyped) }
    def dispatch(msg)
      method = msg["method"]
      id     = msg["id"]
      params = msg["params"] || {}
      @logger.debug("← #{method} #{id ? "(request id=#{id})" : "(notification)"}")

      case method
      when "initialize"               then respond(id, handle_initialize(params))
      when "initialized"              then handle_initialized(params)
      when "textDocument/didOpen"     then handle_did_open(params)
      when "textDocument/didChange"   then handle_did_change(params)
      when "textDocument/didSave"     then handle_did_save(params)
      when "textDocument/didClose"    then handle_did_close(params)
      when "textDocument/codeAction"  then respond(id, handle_code_action(params))
      when "textDocument/hover"       then respond(id, handle_hover(params))
      when "shutdown"                 then respond(id, handle_shutdown(params))
      when "exit"                     then handle_exit
      else
        if id
          respond_error(id, METHOD_NOT_FOUND, "Method not found: #{method}")
        else
          @logger.debug("ignoring unknown notification: #{method}")
        end
      end
    end

    sig { params(id: Integer, result: T.untyped).returns(StringIO) }
    def respond(id, result)
      send_message(jsonrpc: "2.0", id: id, result: result)
    end

    sig { params(id: Integer, code: Integer, message: String).returns(StringIO) }
    def respond_error(id, code, message)
      send_message(jsonrpc: "2.0", id: id, error: { code: code, message: message })
    end

    sig { params(msg: T::Hash[Symbol, T.untyped]).returns(StringIO) }
    def send_message(msg)
      @logger.debug("→ #{msg[:method] || (msg[:result] ? "result(id=#{msg[:id]})" : "error(id=#{msg[:id]})")}")
      @output_mutex.synchronize do
        RPC.write_message(@stdout, msg)
      end
    end

    # ---- lifecycle handlers ----

    # `initialize` request — the very first message. We declare the
    # capabilities the server will support.
    #
    # `textDocumentSync: 1` = Full sync. The client sends the entire
    # buffer on every `didChange`. Simpler than incremental sync;
    # CLEAR files are small enough that the cost is negligible.
    sig { params(_params: Hash).returns(Hash) }
    def handle_initialize(_params)
      {
        capabilities: {
          textDocumentSync: 1,
          hoverProvider: true,
          codeActionProvider: {
            codeActionKinds: [CodeActions::KIND_QUICKFIX, CodeActions::KIND_REFACTOR],
          },
        },
        serverInfo: {
          name:    "clear-lsp",
          version: "0.1.0",
        },
      }
    end

    sig { params(_params: Hash).returns(NilClass) }
    def handle_initialized(_params)
      @initialized = true
      @logger.info("initialization complete")
      nil
    end

    # `shutdown` request — client asks the server to wind down. We
    # acknowledge with a null result; the server keeps running until
    # the subsequent `exit` notification.
    sig { params(_params: Hash).returns(NilClass) }
    def handle_shutdown(_params)
      @shutdown_requested = true
      @logger.info("shutdown requested")
      nil
    end

    # `exit` notification — terminate. Per LSP, exit code 0 if a
    # `shutdown` was received first, 1 otherwise.
    sig { returns(T.untyped) }
    def handle_exit
      @logger.info("exit (clean=#{@shutdown_requested})")
      Kernel.exit(@shutdown_requested ? 0 : 1)
    end

    # ---- textDocument/* handlers ----

    # `textDocument/didOpen` — the client just opened a buffer. Cache
    # it and run a first pass.
    sig { params(params: Hash).returns(T.nilable(IO)) }
    def handle_did_open(params)
      td  = params["textDocument"]
      uri = td["uri"]
      txt = td["text"]
      ver = td["version"]
      @docs.open(uri, txt, ver)
      @logger.info("didOpen #{uri} (version=#{ver}, #{txt.lines.size} lines)")
      analyze_and_publish(uri)
    end

    # `textDocument/didChange` — full-sync replacement. The client
    # sends the entire new text in `contentChanges[0].text`. We
    # debounce the analysis so a flurry of keystrokes only triggers
    # one full re-parse after the user pauses.
    sig { params(params: Hash).returns(T.nilable(Thread)) }
    def handle_did_change(params)
      td  = params["textDocument"]
      uri = td["uri"]
      ver = td["version"]
      changes = params["contentChanges"] || []
      return if changes.empty?
      new_text = changes.last["text"]
      @docs.update(uri, new_text, ver)
      @logger.debug("didChange #{uri} (version=#{ver}) — scheduled")
      schedule_reanalyze(uri)
    end

    # `textDocument/didSave` — re-analyze immediately (save is an
    # explicit user action; no need to debounce).
    sig { params(params: Hash).returns(T.untyped) }
    def handle_did_save(params)
      uri = params["textDocument"]["uri"]
      @logger.debug("didSave #{uri}")
      cancel_timer(uri)  # prevent racing with a pending didChange timer
      analyze_and_publish(uri)
    end

    # `textDocument/didClose` — drop the document and clear any
    # pending diagnostics on the client.
    sig { params(params: Hash).returns(T.untyped) }
    def handle_did_close(params)
      uri = params["textDocument"]["uri"]
      cancel_timer(uri)
      @docs.close(uri)
      publish_diagnostics(uri, [])
      @logger.info("didClose #{uri}")
    end

    # `textDocument/codeAction` — return the FixableFinding fixes
    # that overlap the requested range as LSP CodeActions. No new
    # analysis runs; we read from cached findings.
    sig { params(params: Hash).returns(Array) }
    def handle_code_action(params)
      uri = params["textDocument"]["uri"]
      range = params["range"]
      doc = @docs.get(uri)
      actions = CodeActions.for_range(doc, range)
      @logger.debug("codeAction #{uri} → #{actions.size} action(s)")
      actions
    end

    # `textDocument/hover` — when the cursor sits on a token that has
    # an active diagnostic, render the registry entry + spec example
    # as markdown. Returns nil to dismiss the hover popup when there's
    # nothing relevant.
    sig { params(params: Hash).returns(T.nilable(Hash)) }
    def handle_hover(params)
      uri = params["textDocument"]["uri"]
      pos = params["position"]
      doc = @docs.get(uri)
      hover = Hover.render(doc, pos)
      @logger.debug("hover #{uri} → #{hover ? "rendered" : "none"}")
      hover
    end

    # Run the analyzer on the current text for `uri` and publish the
    # resulting diagnostics. Caches the findings on the Document for
    # later hover / code-action requests.
    sig { params(uri: String).returns(T.nilable(IO)) }
    def analyze_and_publish(uri)
      doc = @docs.get(uri)
      return unless doc
      result = @analyze_mutex.synchronize { Analyzer.run(doc.text) }
      doc.cached_findings = result
      doc.cached_version  = doc.version

      diagnostics = Diagnostics.from_result(result, doc.text)
      publish_diagnostics(uri, diagnostics)
    rescue => e
      @logger.error("analyze_and_publish failed for #{uri}: #{e.class}: #{e.message}")
    end

    # Send a `textDocument/publishDiagnostics` notification.
    sig { params(uri: String, diagnostics: Array).returns(T.untyped) }
    def publish_diagnostics(uri, diagnostics)
      send_message(
        jsonrpc: "2.0",
        method:  "textDocument/publishDiagnostics",
        params:  { uri: uri, diagnostics: diagnostics },
      )
      @logger.info("published #{diagnostics.size} diagnostic(s) for #{uri}")
    end

    # ---- debounce machinery ----

    # Schedule a re-analysis of `uri` after `@debounce_ms`. If a
    # timer is already pending, kill it first — only the latest
    # edit's analysis fires. The timer thread cleans up its own
    # @timers entry on completion (unless a newer thread has
    # already replaced it).
    sig { params(uri: String).returns(Thread) }
    def schedule_reanalyze(uri)
      delay = @debounce_ms / 1000.0
      @timer_mutex.synchronize do
        @timers[uri]&.kill
        @timers[uri] = Thread.new do
          begin
            sleep delay
            analyze_and_publish(uri)
          ensure
            @timer_mutex.synchronize do
              # Don't accidentally drop a NEWER timer that replaced us.
              @timers.delete(uri) if @timers[uri] == Thread.current
            end
          end
        end
      end
    end

    # Cancel any pending timer for `uri`. Used by didSave (which
    # analyses immediately) and didClose (which drops the document).
    sig { params(uri: String).returns(T.nilable(Thread)) }
    def cancel_timer(uri)
      @timer_mutex.synchronize do
        t = @timers.delete(uri)
        t&.kill
      end
    end

  end
end
