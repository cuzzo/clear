# typed: false
# frozen_string_literal: true

module NilKill
  module Runtime
    # Converts language-neutral runtime_call events into a SCIP index.
    #
    # Runtime observations are intentionally encoded as ordinary SCIP
    # occurrences. Their modeled-world authority is declared in ToolInfo
    # arguments, so consumers can use the wire format without mistaking an
    # observed target set for compiler proof.
    class ScipEmitter
      SCHEMA_VERSION = 1
      TOOL_NAME = "nil-kill-runtime"
      TOOL_VERSION = "1"
      AUTHORITY = "runtime-modeled-world"
      AUTHORITY_ARGUMENT = "--fact-mine-index-authority=#{AUTHORITY}"
      EVENT_GLOB = "runtime-calls-*.jsonl"

      def self.emit(root:, runtime_dir:, output: nil, attestation: nil, environment: {})
        new(
          root: root,
          runtime_dir: runtime_dir,
          output: output,
          attestation: attestation,
          environment: environment
        ).emit
      end

      def initialize(root:, runtime_dir:, output: nil, attestation: nil, environment: {})
        @root = File.expand_path(root)
        @runtime_dir = File.expand_path(runtime_dir)
        @output = File.expand_path(output || File.join(@runtime_dir, "runtime.scip.json"))
        @attestation = File.expand_path(
          attestation || File.join(@runtime_dir, "runtime-attestation.json")
        )
        @environment = environment.transform_keys(&:to_s).transform_values(&:to_s)
      end

      def emit
        events, invalid_events = load_events
        inferred_events = infer_events(events)
        documents = build_documents(events + inferred_events)
        index = {
          "metadata" => {
            "version" => 0,
            "toolInfo" => {
              "name" => TOOL_NAME,
              "version" => TOOL_VERSION,
              "arguments" => [AUTHORITY_ARGUMENT],
            },
            "projectRoot" => project_root_uri,
            "textDocumentEncoding" => 1,
          },
          "documents" => documents,
          "externalSymbols" => [],
        }

        FileUtils.mkdir_p(File.dirname(@output))
        write_atomically(@output, JSON.pretty_generate(index) + "\n")
        write_atomically(
          @attestation,
          JSON.pretty_generate(
            attestation_payload(events, documents, invalid_events, inferred_events.length)
          ) + "\n"
        )
        {
          "index" => @output,
          "attestation" => @attestation,
          "events" => events.length,
          "inferred_events" => inferred_events.length,
          "documents" => documents.length,
          "occurrences" => documents.sum { |document| document.fetch("occurrences").length },
          "invalid_events" => invalid_events,
        }
      end

      private

      def infer_events(events)
        events.group_by { |event| event.fetch("language") }.sort.flat_map do |language, rows|
          Languages.provider_for(language).runtime_scip_inferred_events(
            events: rows,
            root: @root
          )
        end
      end

      def load_events
        events = []
        invalid = 0
        Dir.glob(File.join(@runtime_dir, EVENT_GLOB)).sort.each do |path|
          File.foreach(path) do |line|
            event = JSON.parse(line)
            unless valid_event?(event)
              invalid += 1
              next
            end
            events << event
          rescue JSON::ParserError
            invalid += 1
          end
        end
        [events, invalid]
      end

      def valid_event?(event)
        return false unless event.is_a?(Hash) && event["event"] == "runtime_call"
        return false if event["language"].to_s.empty?

        caller = event["caller"]
        callee = event["callee"]
        callsite = event["callsite"]
        caller.is_a?(Hash) && callee.is_a?(Hash) && callsite.is_a?(Hash) &&
          !caller["path"].to_s.empty? && !callee["name"].to_s.empty? &&
          !callsite["path"].to_s.empty? && callsite["line"].to_i.positive?
      end

      def build_documents(events)
        occurrences = Hash.new { |hash, key| hash[key] = [] }
        symbols = Hash.new { |hash, key| hash[key] = {} }
        languages = {}

        events.each do |event|
          language = event.fetch("language")
          callee = event.fetch("callee")
          callsite = event.fetch("callsite")
          callsite_path = File.expand_path(callsite.fetch("path"), @root)
          provider = Languages.provider_for(language)
          locations =
            if callsite["range"].is_a?(Array)
              [{
                "range" => callsite.fetch("range"),
                "selector" => callsite.fetch("selector", callee.fetch("name")),
              }]
            else
              provider.runtime_scip_callsite_locations(event: event, root: @root)
            end
          locations ||= token_ranges(
            callsite_path,
            callsite.fetch("line").to_i,
            callee.fetch("name")
          ).map { |range| { "range" => range, "selector" => callee.fetch("name") } }
          next if locations.empty?

          caller_document = document_path(callsite_path)
          register_document_language(languages, caller_document, language)
          locations.each do |location|
            selector = location.fetch("selector", callee.fetch("name"))
            symbol = runtime_symbol(language, callee, selector: selector)
            occurrences[caller_document] <<
              occurrence(location.fetch("range"), symbol, definition: false)

            callee_path = callee["path"].to_s
            next if callee_path.empty? || callee["native"] == true

            absolute_callee = File.expand_path(callee_path, @root)
            next unless inside_root?(absolute_callee)

            definition_range = token_ranges(
              absolute_callee,
              callee["line"].to_i,
              callee.fetch("name")
            ).then { |ranges| ranges.one? ? ranges.first : nil }
            next unless definition_range

            callee_document = document_path(absolute_callee)
            register_document_language(languages, callee_document, language)
            occurrences[callee_document] <<
              occurrence(definition_range, symbol, definition: true)
            symbols[callee_document][symbol] ||= { "symbol" => symbol }
          end
        end

        occurrences.keys.sort.map do |path|
          {
            "language" => languages.fetch(path),
            "relativePath" => path,
            "occurrences" => occurrences[path].uniq.sort_by do |row|
              [row.fetch("range"), row.fetch("symbol"), row.fetch("symbolRoles")]
            end,
            "symbols" => symbols[path].values.sort_by { |row| row.fetch("symbol") },
          }
        end
      end

      def register_document_language(languages, path, language)
        existing = languages[path]
        return languages[path] = language unless existing
        return if existing == language

        raise ArgumentError,
          "runtime SCIP document #{path} was traced as both #{existing} and #{language}"
      end

      def occurrence(range, symbol, definition:)
        {
          "range" => range,
          "symbol" => symbol,
          "symbolRoles" => definition ? 1 : 0,
        }
      end

      def project_root_uri
        encoded_path = URI::DEFAULT_PARSER.escape(@root)
        URI::Generic.build(scheme: "file", path: encoded_path).to_s
      end

      def runtime_symbol(language, callee, selector: callee.fetch("name"))
        manager = symbol_word(callee["package_manager"] || "runtime")
        package = symbol_word(callee["package"] || language)
        version = symbol_word(callee["version"] || "workspace")
        owner = descriptor_owner(callee["owner"] || callee["receiver_type"] || language)
        method = descriptor_name(selector)
        separator = callee["kind"].to_s == "class" ? "." : "#"
        "#{TOOL_NAME} #{manager} #{package} #{version} #{owner}#{separator}#{method}()."
      end

      def symbol_word(value)
        text = value.to_s
        return "." if text.empty?
        return text if text.match?(/\A[A-Za-z0-9_.+@\/-]+\z/)

        "`#{text.gsub("`", "``")}`"
      end

      def descriptor_owner(value)
        value.to_s.split("::").reject(&:empty?).map { |part| descriptor_name(part) }.join("/")
      end

      def descriptor_name(value)
        text = value.to_s
        return text if text.match?(/\A[A-Za-z_][A-Za-z0-9_!?=]*\z/)

        "`#{text.gsub("`", "``")}`"
      end

      def token_ranges(path, one_based_line, token)
        return [] unless one_based_line.positive? && File.file?(path)

        line = File.foreach(path).with_index(1).find { |_source, number| number == one_based_line }&.first
        return [] unless line

        token_matches(line, token.to_s).map do |start_byte, end_byte|
          [one_based_line - 1, start_byte, end_byte]
        end
      end

      def token_matches(line, token)
        return [] if token.empty?

        expression =
          if token.match?(/\A[A-Za-z_][A-Za-z0-9_!?=]*\z/)
            /(?<![A-Za-z0-9_])#{Regexp.escape(token)}(?![A-Za-z0-9_!?=])/
          else
            /#{Regexp.escape(token)}/
          end
        line.to_enum(:scan, expression).map do
          match = Regexp.last_match
          [
            line[0...match.begin(0)].to_s.bytesize,
            line[0...match.end(0)].to_s.bytesize,
          ]
        end
      end

      def document_path(path)
        Pathname.new(path).relative_path_from(Pathname.new(@root)).to_s
      end

      def inside_root?(path)
        path == @root || path.start_with?("#{@root}#{File::SEPARATOR}")
      end

      def attestation_payload(events, documents, invalid_events, inferred_events)
        claims = {
          "runtime_scip.authority" => AUTHORITY,
          "runtime_scip.closure_assumption" =>
            "observed call targets exhaust the attested workload and runtime environment",
          "runtime_scip.producer" => "#{TOOL_NAME}@#{TOOL_VERSION}",
          "runtime_scip.event_schema" => SCHEMA_VERSION.to_s,
          "runtime_scip.event_count" => events.length.to_s,
          "runtime_scip.document_count" => documents.length.to_s,
          "runtime_scip.invalid_event_count" => invalid_events.to_s,
          "runtime_scip.inferred_event_count" => inferred_events.to_s,
          "runtime_scip.inference" =>
            "language-owned source callsites joined to observed modeled dispatch domains",
          "runtime_scip.run_ids_sha256" => digest(
            events.map { |event| event["run_id"].to_s }.reject(&:empty?).uniq.sort.join("\n")
          ),
        }.merge(observed_environment(events)).merge(@environment)
        {
          "schema" => "fact-mine.semantic-environment.v1",
          "claims" => claims.sort.to_h,
        }
      end

      def observed_environment(events)
        events.map { |event| event["language"].to_s }
          .reject(&:empty?)
          .uniq
          .sort
          .each_with_object({}) do |language, claims|
            provider_claims = Languages.provider_for(language)
              .runtime_scip_environment(root: @root)
            provider_claims.each do |key, value|
              key = key.to_s
              value = value.to_s
              if claims.key?(key) && claims.fetch(key) != value
                raise ArgumentError,
                  "runtime SCIP environment claim #{key} conflicts across traced languages"
              end
              claims[key] = value
            end
          end
      end

      def digest(value)
        "sha256:#{Digest::SHA256.hexdigest(value)}"
      end

      def write_atomically(path, contents)
        temporary = "#{path}.#{Process.pid}.tmp"
        File.write(temporary, contents)
        File.rename(temporary, path)
      ensure
        File.delete(temporary) if temporary && File.exist?(temporary)
      end
    end
  end
end
