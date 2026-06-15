# typed: false
# frozen_string_literal: true

module NilKill
  module Runtime
    class TraceLoader
      def initialize(paths)
        @paths = Array(paths).flatten.compact
      end

      def each_event
        event_files.each do |file|
          File.foreach(file).with_index(1) do |line, line_no|
            next if line.strip.empty?

            event = JSON.parse(line)
            unless event.is_a?(Hash) && event["event"]
              yield nil, diagnostic(file, line_no, "not_raw_trace_event", "JSONL row is not a Raw Runtime Trace Event v1 object")
              next
            end
            yield event, nil
          rescue JSON::ParserError => e
            yield nil, diagnostic(file, line_no, "invalid_json", e.message)
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
