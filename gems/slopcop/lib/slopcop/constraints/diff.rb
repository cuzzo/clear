# frozen_string_literal: true

require "set"

module SlopCop
  module Constraints
    module Diff
      module_function

      def added_lines(repo:, base:, head: "HEAD")
        old_path = nil
        new_path = nil
        old_line = nil
        new_line = nil
        adds = Hash.new { |hash, key| hash[key] = Set.new }

        diff(repo, base, head).each_line do |line|
          if line.start_with?("diff --git ")
            old_path = nil
            new_path = nil
            old_line = nil
            new_line = nil
            next
          end

          if line.start_with?("--- ")
            old_path = header_path(line, "--- ")
            next
          end

          if line.start_with?("+++ ")
            new_path = header_path(line, "+++ ")
            next
          end

          next unless old_path || new_path

          if (match = line.match(/\A@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@/))
            old_line = match[1].to_i
            new_line = match[2].to_i
            next
          end

          next unless old_line && new_line
          next if line.start_with?("\\")

          if line.start_with?("+") && !line.start_with?("+++")
            adds[new_path] << new_line if new_path
            new_line += 1
          elsif line.start_with?("-") && !line.start_with?("---")
            old_line += 1
          else
            old_line += 1
            new_line += 1
          end
        end

        adds.transform_values { |lines| lines.to_a.sort }.sort.to_h
      end

      def diff(repo, base, head)
        IO.popen(["git", "diff", "--unified=0", "#{base}...#{head}"],
                 chdir: repo, err: [:child, :out], &:read)
      end

      def header_path(line, prefix)
        path = line.delete_prefix(prefix).strip
        return nil if path == "/dev/null"

        path.sub(/\A[ab]\//, "")
      end
    end
  end
end
