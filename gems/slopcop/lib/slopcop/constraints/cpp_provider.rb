# frozen_string_literal: true

require_relative "language_provider"
require_relative "fact_mine_provider_helper"

module SlopCop
  module Constraints
    module CppProvider
      module_function

      EXCLUDED_DIRS = %w[.git vendor third_party node_modules build cmake-build-debug cmake-build-release tmp dist tests test].freeze
      EXTENSIONS = %w[.cc .cpp .cxx .hh .hpp .hxx].freeze
      TSAN_NEEDLES = [
        "std::thread",
        "std::jthread",
        "std::async",
        "std::atomic",
        "std::mutex",
        "std::shared_mutex",
        "std::recursive_mutex",
        "std::condition_variable",
        "std::lock_guard",
        "std::unique_lock",
        "std::scoped_lock",
        "std::call_once",
        ".lock(",
        ".try_lock(",
        ".unlock("
      ].freeze
      ASAN_NEEDLES = [
        "std::memcpy(",
        "std::memmove(",
        "std::memset(",
        "memcpy(",
        "memmove(",
        "memset(",
        "strcpy(",
        "strncpy(",
        "strcat(",
        "strncat(",
        "sprintf(",
        "snprintf(",
        "std::span<",
        "std::string_view"
      ].freeze
      LSAN_NEEDLES = [
        "malloc(",
        "calloc(",
        "realloc(",
        "free(",
        "std::malloc(",
        "std::calloc(",
        "std::realloc(",
        "std::free("
      ].freeze

      def rules
        evidence_rule("tsan", "C++ TSan coverage missing", "C++ shared-concurrency site lacks TSan coverage evidence") +
          evidence_rule("asan", "C++ ASan coverage missing", "C++ raw-memory site lacks ASan coverage evidence") +
          evidence_rule("lsan", "C++ LSan coverage missing", "C++ allocation/lifetime site lacks LSan coverage evidence") +
          evidence_rule("ubsan", "C++ UBSan coverage missing", "C++ undefined-behavior site lacks UBSan coverage evidence") +
          [
            {
              "id" => "slopcop-cpp-callback-uncovered",
              "name" => "C++ callback coverage missing",
              "shortDescription" => { "text" => "C++ function-pointer invocation lacks test-tracing coverage evidence" },
              "fullDescription" => {
                "text" => "A changed C++ function-pointer or callable invocation site was not reached by test-tracing coverage evidence."
              },
              "defaultConfiguration" => { "level" => "warning" }
            }
          ]
      end

      def evidence_rule(evidence, name, short)
        [
          {
            "id" => "slopcop-cpp-#{evidence}-uncovered",
            "name" => name,
            "shortDescription" => { "text" => short },
            "fullDescription" => {
              "text" => "A changed C++ #{evidence.upcase} hazard was not reached by #{evidence.upcase} coverage evidence."
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
          language_extension: EXTENSIONS,
          hazard_type_filter: "cpp_callback_invocation",
          required_evidence: "nil-kill",
          label: "C++ function-pointer invocation site"
        )
        (hazards + cb_hazards).uniq { |h| [h[:path], h[:line], h[:hazard_type]] }.sort_by { |h| [h[:path], h[:line]] }
      end

      def source_path?(path)
        EXTENSIONS.any? { |extension| path.end_with?(extension) } &&
          !LanguageProvider.excluded_path?(path, dirs: EXCLUDED_DIRS)
      end

      def rule_id_for(required_evidence)
        return "slopcop-cpp-callback-uncovered" if required_evidence == "nil-kill"

        "slopcop-cpp-#{required_evidence}-uncovered"
      end

      def scan_file(path, contents)
        sites = []
        comment = { active: false }
        contents.lines.each_with_index do |source, index|
          line = index + 1
          code = LanguageProvider.c_style_code(source, comment)
          next if code.strip.empty?

          add_tsan_site(sites, path, line, source, code)
          add_asan_site(sites, path, line, source, code)
          add_lsan_site(sites, path, line, source, code)
          add_ubsan_site(sites, path, line, source, code)
        end
        sites
      end

      def add_tsan_site(sites, path, line, source, code)
        return unless LanguageProvider.any_include?(code, TSAN_NEEDLES)

        sites << LanguageProvider.hazard(path, line, source, "cpp_tsan_concurrency", "tsan", "C++ atomic/thread/lock site")
      end

      def add_asan_site(sites, path, line, source, code)
        if LanguageProvider.any_include?(code, ASAN_NEEDLES)
          sites << LanguageProvider.hazard(path, line, source, "cpp_asan_raw_memory_api", "asan", "C++ raw-memory or unchecked buffer API")
        end
        if pointer_or_cast_hazard?(code)
          sites << LanguageProvider.hazard(path, line, source, "cpp_asan_pointer_or_cast", "asan", "C++ pointer/cast hazard")
        end
      end

      def add_lsan_site(sites, path, line, source, code)
        if LanguageProvider.any_include?(code, LSAN_NEEDLES) || code.match?(/\b(?:new|delete)(?:\[\])?\b/)
          sites << LanguageProvider.hazard(path, line, source, "cpp_lsan_lifetime", "lsan", "C++ allocation/free lifetime site")
        end
      end

      def add_ubsan_site(sites, path, line, source, code)
        if arithmetic_ub_site?(code)
          sites << LanguageProvider.hazard(path, line, source, "cpp_ubsan_arithmetic", "ubsan", "C++ divide/modulo/shift arithmetic site")
        end
        if code.match?(/\b(?:reinterpret_cast|const_cast)\s*</)
          sites << LanguageProvider.hazard(path, line, source, "cpp_ubsan_cast", "ubsan", "C++ cast site")
        end
      end

      def pointer_or_cast_hazard?(code)
        code.match?(/\b(?:reinterpret_cast|const_cast)\s*</)
      end

      def arithmetic_ub_site?(code)
        code.match?(%r{[A-Za-z0-9_\])]\s*(?:/|%)\s*[A-Za-z_(]}) ||
          code.match?(/[A-Za-z0-9_\])]\s*(?:<<|>>)\s*[A-Za-z_(]/)
      end
    end
  end
end
