# frozen_string_literal: true

require_relative "language_provider"

module SlopCop
  module Constraints
    module CProvider
      module_function

      EXCLUDED_DIRS = %w[.git vendor third_party node_modules build cmake-build-debug cmake-build-release tmp dist tests test].freeze
      TSAN_NEEDLES = [
        "_Atomic",
        "atomic_",
        "__atomic_",
        "__sync_",
        "pthread_create",
        "pthread_mutex_",
        "pthread_rwlock_",
        "pthread_cond_",
        "pthread_spin_",
        "pthread_barrier_",
        "mtx_",
        "cnd_",
        "thrd_create"
      ].freeze
      ASAN_NEEDLES = [
        "memcpy(",
        "memmove(",
        "memset(",
        "strcpy(",
        "strncpy(",
        "strcat(",
        "strncat(",
        "sprintf(",
        "snprintf(",
        "vsprintf(",
        "vsnprintf(",
        "gets(",
        "scanf(",
        "sscanf(",
        "fscanf(",
        "alloca("
      ].freeze
      LSAN_NEEDLES = [
        "malloc(",
        "calloc(",
        "realloc(",
        "aligned_alloc(",
        "posix_memalign(",
        "strdup(",
        "strndup(",
        "free("
      ].freeze

      def rules
        evidence_rule("tsan", "C TSan coverage missing", "C shared-concurrency site lacks TSan coverage evidence") +
          evidence_rule("asan", "C ASan coverage missing", "C raw-memory site lacks ASan coverage evidence") +
          evidence_rule("lsan", "C LSan coverage missing", "C allocation/lifetime site lacks LSan coverage evidence") +
          evidence_rule("ubsan", "C UBSan coverage missing", "C undefined-behavior site lacks UBSan coverage evidence") +
          [
            {
              "id" => "slopcop-c-callback-uncovered",
              "name" => "C callback coverage missing",
              "shortDescription" => { "text" => "C function-pointer invocation lacks test-tracing coverage evidence" },
              "fullDescription" => {
                "text" => "A changed C function-pointer invocation site was not reached by test-tracing coverage evidence."
              },
              "defaultConfiguration" => { "level" => "warning" }
            }
          ]
      end

      def evidence_rule(evidence, name, short)
        [
          {
            "id" => "slopcop-c-#{evidence}-uncovered",
            "name" => name,
            "shortDescription" => { "text" => short },
            "fullDescription" => {
              "text" => "A changed C #{evidence.upcase} hazard was not reached by #{evidence.upcase} coverage evidence."
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
          language_extension: [".c", ".h"],
          hazard_type_filter: "c_callback_invocation",
          required_evidence: "nil-kill",
          label: "C function-pointer invocation site"
        )
        (hazards + cb_hazards).uniq { |h| [h[:path], h[:line], h[:hazard_type]] }.sort_by { |h| [h[:path], h[:line]] }
      end

      def source_path?(path)
        (path.end_with?(".c") || path.end_with?(".h")) &&
          !LanguageProvider.excluded_path?(path, dirs: EXCLUDED_DIRS)
      end

      def rule_id_for(required_evidence)
        return "slopcop-c-callback-uncovered" if required_evidence == "nil-kill"

        "slopcop-c-#{required_evidence}-uncovered"
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

        sites << LanguageProvider.hazard(path, line, source, "c_tsan_concurrency", "tsan", "C atomic/thread/lock site")
      end

      def add_asan_site(sites, path, line, source, code)
        if LanguageProvider.any_include?(code, ASAN_NEEDLES)
          sites << LanguageProvider.hazard(path, line, source, "c_asan_raw_memory_api", "asan", "C raw-memory or unchecked buffer API")
        end
        if pointer_hazard?(code)
          sites << LanguageProvider.hazard(path, line, source, "c_asan_pointer", "asan", "C pointer dereference/arithmetic site")
        end
      end

      def add_lsan_site(sites, path, line, source, code)
        return unless LanguageProvider.any_include?(code, LSAN_NEEDLES)

        sites << LanguageProvider.hazard(path, line, source, "c_lsan_lifetime", "lsan", "C allocation/free lifetime site")
      end

      def add_ubsan_site(sites, path, line, source, code)
        if arithmetic_ub_site?(code)
          sites << LanguageProvider.hazard(path, line, source, "c_ubsan_arithmetic", "ubsan", "C divide/modulo/shift arithmetic site")
        end
        if cast_ub_site?(code)
          sites << LanguageProvider.hazard(path, line, source, "c_ubsan_cast", "ubsan", "C pointer/integer cast site")
        end
      end

      def pointer_hazard?(code)
        code.include?("->") ||
          code.match?(/\A\s*\*\s*[A-Za-z_][A-Za-z0-9_]*/) ||
          code.match?(/(?:=\s*|return\s+|\(|,|\[)\*\s*[A-Za-z_][A-Za-z0-9_]*/)
      end

      def arithmetic_ub_site?(code)
        code.match?(%r{[A-Za-z0-9_\])]\s*(?:/|%)\s*[A-Za-z_(]}) ||
          code.match?(/[A-Za-z0-9_\])]\s*(?:<<|>>)\s*[A-Za-z_(]/)
      end

      def cast_ub_site?(code)
        code.match?(/\([A-Za-z_][A-Za-z0-9_\s]*(?:\*|intptr_t|uintptr_t|size_t|ssize_t|int|long|short|char)[A-Za-z0-9_\s\*]*\)\s*[A-Za-z_(&*]/)
      end
    end
  end
end
