# frozen_string_literal: true

require_relative "language_provider"
require_relative "fact_mine_provider_helper"

module SlopCop
  module Constraints
    module CsharpProvider
      module_function

      EXCLUDED_DIRS = %w[.git bin obj packages node_modules tmp dist tests test].freeze
      CONCURRENCY_NEEDLES = [
        "Task.Run",
        "Task.Factory.StartNew",
        "new Thread",
        "ThreadPool.",
        "Parallel.",
        "lock (",
        "lock(",
        "Monitor.",
        "Interlocked.",
        "Volatile.",
        "ConcurrentDictionary",
        "ConcurrentQueue",
        "ConcurrentBag",
        "BlockingCollection",
        "SemaphoreSlim",
        "Mutex",
        "ReaderWriterLockSlim",
        "SpinLock"
      ].freeze
      UNSAFE_NEEDLES = [
        "unsafe",
        "fixed (",
        "fixed(",
        "stackalloc",
        "Marshal.",
        "IntPtr",
        "UIntPtr",
        "GCHandle",
        "Unsafe.",
        "MemoryMarshal."
      ].freeze

      def rules
        [
          {
            "id" => "slopcop-csharp-concurrency-uncovered",
            "name" => "C# concurrency coverage missing",
            "shortDescription" => { "text" => "C# concurrency site lacks concurrency coverage evidence" },
            "fullDescription" => {
              "text" => "A changed C# task, thread, lock, or concurrent collection site was not reached by concurrency coverage evidence."
            },
            "defaultConfiguration" => { "level" => "warning" }
          },
          {
            "id" => "slopcop-csharp-unsafe-uncovered",
            "name" => "C# unsafe coverage missing",
            "shortDescription" => { "text" => "C# unsafe/native-memory site lacks unsafe coverage evidence" },
            "fullDescription" => {
              "text" => "A changed C# unsafe, native-memory, pointer, or Marshal site was not reached by unsafe coverage evidence."
            },
            "defaultConfiguration" => { "level" => "warning" }
          },
          {
            "id" => "slopcop-csharp-metaprogramming-uncovered",
            "name" => "C# metaprogramming coverage missing",
            "shortDescription" => { "text" => "C# reflection or callback site lacks test-tracing coverage evidence" },
            "fullDescription" => {
              "text" => "A changed C# reflection, dynamic, or callback invocation site was not reached by test-tracing coverage evidence."
            },
            "defaultConfiguration" => { "level" => "warning" }
          }
        ]
      end

      def findings(repo:, additions:, evidence:)
        LanguageProvider.findings(self, repo: repo, additions: additions, evidence: evidence)
      end

      def scan_hazards(repo:, paths: nil)
        hazards = LanguageProvider.scan_hazards(self, repo: repo, paths: paths)
        cb_hazards = FactMineProviderHelper.scan_hazards_via_fact_mine(
          paths,
          repo: repo,
          language_extension: ".cs",
          hazard_type_filter: ["csharp_callback_invocation", "csharp_metaprogramming"],
          required_evidence: "nil-kill",
          label: "C# metaprogramming or callback site"
        )
        (hazards + cb_hazards).uniq { |h| [h[:path], h[:line], h[:hazard_type]] }.sort_by { |h| [h[:path], h[:line]] }
      end

      def source_path?(path)
        path.end_with?(".cs") && !LanguageProvider.excluded_path?(path, dirs: EXCLUDED_DIRS)
      end

      def rule_id_for(required_evidence)
        return "slopcop-csharp-metaprogramming-uncovered" if required_evidence == "nil-kill"

        required_evidence == "concurrency" ? "slopcop-csharp-concurrency-uncovered" : "slopcop-csharp-unsafe-uncovered"
      end

      def scan_file(path, contents)
        sites = []
        comment = { active: false }
        unsafe_depth = 0
        contents.lines.each_with_index do |source, index|
          line = index + 1
          code = LanguageProvider.c_style_code(source, comment)
          next if code.strip.empty?

          if concurrency_site?(code)
            sites << LanguageProvider.hazard(path, line, source, "csharp_concurrency", "concurrency", "C# task/thread/lock site")
          end
          if unsafe_site?(code, unsafe_depth)
            sites << LanguageProvider.hazard(path, line, source, "csharp_unsafe_memory", "unsafe", "C# unsafe/native-memory site")
          end
          unsafe_depth = update_unsafe_depth(code, unsafe_depth)
        end
        sites
      end

      def concurrency_site?(code)
        LanguageProvider.any_include?(code, CONCURRENCY_NEEDLES)
      end

      def unsafe_site?(code, unsafe_depth)
        unsafe_depth.positive? && pointer_operation?(code) ||
          LanguageProvider.any_include?(code, UNSAFE_NEEDLES) ||
          code.match?(/\b(?:byte|char|int|long|void)\s*\*/)
      end

      def pointer_operation?(code)
        code.include?("->") || code.match?(/\*\s*[A-Za-z_][A-Za-z0-9_]*/)
      end

      def update_unsafe_depth(code, unsafe_depth)
        code = code.chomp
        relevant = if unsafe_depth.positive?
                     code
                   elsif (match = code.match(/\bunsafe\s*\{.*\z/))
                     match[0]
                   else
                     ""
                   end
        return unsafe_depth if relevant.empty?

        [unsafe_depth + relevant.count("{") - relevant.count("}"), 0].max
      end
    end
  end
end
