# typed: true
module LSP
  # In-memory store of open documents. The LSP advertises full-sync
  # mode (`textDocumentSync: 1`) so `didChange` notifications carry
  # the entire new buffer in `contentChanges[0].text` — we just
  # replace the stored text. Incremental sync (mode 2) would require
  # patching ranges; deferred until performance demands it.
  #
  # Each entry tracks the integer `version` from the client (LSP
  # requires it to be monotonically increasing per uri) so later
  # commits can cache analysis results keyed by version.
  #
  # The store is single-threaded — the Server only mutates it from
  # the main message-loop thread. Re-analysis runs on a separate
  # thread but only reads the latest text snapshot.
  class DocumentStore
    Document = Struct.new(:uri, :text, :version, keyword_init: true) do
      # Cached findings + the version they reflect. Hover and
      # codeAction read these without re-analysing. Set by the Server
      # after each `analyze_and_publish` pass.
      def cached_findings;          @cached_findings; end
      def cached_findings=(value);  @cached_findings = value; end
      def cached_version;           @cached_version; end
      def cached_version=(value);   @cached_version = value; end
    end

    def initialize
      @docs = {}
    end

    # didOpen — new document arrives.
    def open(uri, text, version)
      @docs[uri] = Document.new(uri: uri, text: text, version: version)
    end

    # didChange — full-sync replacement.
    def update(uri, text, version)
      doc = @docs[uri]
      return nil unless doc
      doc.text = text
      doc.version = version
      # Stale cache; next analysis will refresh.
      doc.cached_findings = nil
      doc.cached_version  = nil
      doc
    end

    # didClose — drop the document.
    def close(uri)
      @docs.delete(uri)
    end

    def get(uri)
      @docs[uri]
    end

    def text(uri)
      @docs[uri]&.text
    end

    def version(uri)
      @docs[uri]&.version
    end

    def each(&block)
      @docs.each_value(&block)
    end
  end
end
