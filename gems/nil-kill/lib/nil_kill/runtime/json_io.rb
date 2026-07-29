# typed: false
# frozen_string_literal: true

require "zlib"

module NilKill
  module Runtime
    # Transparent JSON/JSONL compression at the runtime-evidence boundary.
    # SCIP indexes remain plain JSON for compatibility with existing SCIP
    # consumers; tracer evidence and attestations use gzip by default.
    module JsonIO
      module_function

      def read(path)
        gzip?(path) ? Zlib::GzipReader.open(path, &:read) : File.read(path)
      end

      def foreach(path, &block)
        return enum_for(__method__, path) unless block

        if gzip?(path)
          Zlib::GzipReader.open(path) { |io| io.each_line(&block) }
        else
          File.foreach(path, &block)
        end
      end

      def write(path, contents)
        FileUtils.mkdir_p(File.dirname(path))
        temporary = "#{path}.#{Process.pid}.tmp"
        if gzip?(path)
          Zlib::GzipWriter.open(temporary) { |io| io.write(contents) }
        else
          File.binwrite(temporary, contents)
        end
        File.rename(temporary, path)
      ensure
        File.delete(temporary) if temporary && File.exist?(temporary)
      end

      def parse(path)
        JSON.parse(read(path))
      end

      def gzip_file(path)
        return path if gzip?(path)

        compressed = "#{path}.gz"
        write(compressed, File.binread(path))
        File.delete(path)
        compressed
      end

      def matching(directory, pattern)
        (Dir.glob(File.join(directory, pattern)) +
          Dir.glob(File.join(directory, "#{pattern}.gz"))).uniq.sort
      end

      def gzip?(path)
        path.to_s.end_with?(".gz")
      end
    end
  end
end
