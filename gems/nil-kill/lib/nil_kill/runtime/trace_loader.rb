# typed: false
# frozen_string_literal: true

module NilKill
  module Runtime
    class TraceLoader
      MAX_DIAGNOSTICS_PER_FILE_CODE = 20

      def initialize(paths)
        @paths = Array(paths).flatten.compact
      end

      def each_event
        event_files.each do |file|
          diagnostics = Hash.new(0)
          File.foreach(file).with_index(1) do |line, line_no|
            next if line.strip.empty?

            event = JSON.parse(line)
            unless event.is_a?(Hash) && event["event"]
              yield_limited_diagnostic(diagnostics, file, line_no, "not_raw_trace_event",
                "JSONL row is not a Raw Runtime Trace Event v1 object") { |diagnostic| yield nil, diagnostic }
              break if diagnostics["not_raw_trace_event"] > MAX_DIAGNOSTICS_PER_FILE_CODE
              next
            end
            yield event, nil
          rescue JSON::ParserError => e
            yield_limited_diagnostic(diagnostics, file, line_no, "invalid_json", e.message) do |diagnostic|
              yield nil, diagnostic
            end
          end
        end
      end

      def event_files
        @paths.flat_map do |path|
          if File.directory?(path)
            Dir.glob(File.join(path, "**", "*.jsonl"))
          else
            path
          end
        end.select { |path| File.file?(path) }.sort
      end

      private

      def yield_limited_diagnostic(counts, file, line_no, code, message)
        counts[code] += 1
        if counts[code] <= MAX_DIAGNOSTICS_PER_FILE_CODE
          yield diagnostic(file, line_no, code, message)
        elsif counts[code] == MAX_DIAGNOSTICS_PER_FILE_CODE + 1
          yield diagnostic(file, line_no, "#{code}_suppressed",
            "suppressed additional #{code} diagnostics for this trace file")
        end
      end

      def diagnostic(file, line_no, code, message)
        {
          "severity" => "warning",
          "code" => code,
          "path" => file,
          "line" => line_no,
          "message" => message,
        }
      end
    end
  end
end
