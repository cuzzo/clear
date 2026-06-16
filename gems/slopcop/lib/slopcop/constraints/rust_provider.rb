# frozen_string_literal: true

require_relative "language_provider"

module SlopCop
  module Constraints
    module RustProvider
      module_function

      EXCLUDED_DIRS = %w[target vendor node_modules tmp dist tests benches examples].freeze
      ATOMIC_NEEDLES = [
        "std::sync::atomic",
        "core::sync::atomic",
        "Ordering::",
        ".load(",
        ".store(",
        ".swap(",
        ".compare_exchange(",
        ".compare_exchange_weak(",
        ".fetch_add(",
        ".fetch_sub(",
        ".fetch_or(",
        ".fetch_and(",
        ".fetch_xor(",
        ".fetch_update(",
        "fence("
      ].freeze
      CONCURRENCY_NEEDLES = [
        "thread::spawn",
        "std::thread::spawn",
        "std::sync::Mutex",
        "std::sync::RwLock",
        "std::sync::Condvar",
        "std::sync::Arc",
        "Arc<",
        "Mutex<",
        "RwLock<",
        "Condvar",
        "mpsc::",
        "crossbeam::channel",
        ".lock(",
        ".try_lock("
      ].freeze
      UNSAFE_API_NEEDLES = [
        "std::ptr::",
        "core::ptr::",
        "ptr::read",
        "ptr::write",
        "ptr::copy",
        "copy_nonoverlapping",
        "from_raw",
        "into_raw",
        "get_unchecked",
        "get_unchecked_mut",
        "unwrap_unchecked",
        "transmute",
        "assume_init",
        "MaybeUninit",
        "addr_of!",
        "asm!"
      ].freeze

      def rules
        [
          {
            "id" => "slopcop-rust-loom-uncovered",
            "name" => "Rust Loom coverage missing",
            "shortDescription" => { "text" => "Rust concurrency site lacks Loom coverage evidence" },
            "fullDescription" => {
              "text" => "A changed Rust atomic, lock, thread, or shared-concurrency site was not reached by Loom coverage evidence."
            },
            "defaultConfiguration" => { "level" => "warning" }
          },
          {
            "id" => "slopcop-rust-miri-uncovered",
            "name" => "Rust unsafe coverage missing",
            "shortDescription" => { "text" => "Rust unsafe site lacks Miri/unsafe coverage evidence" },
            "fullDescription" => {
              "text" => "A changed Rust unsafe block, unsafe declaration, or unsafe operation was not reached by Miri-style evidence."
            },
            "defaultConfiguration" => { "level" => "warning" }
          }
        ]
      end

      def findings(repo:, additions:, evidence:)
        LanguageProvider.findings(self, repo: repo, additions: additions, evidence: evidence)
      end

      def scan_hazards(repo:, paths: nil)
        LanguageProvider.scan_hazards(self, repo: repo, paths: paths)
      end

      def source_path?(path)
        path.end_with?(".rs") && !LanguageProvider.excluded_path?(path, dirs: EXCLUDED_DIRS)
      end

      def rule_id_for(required_evidence)
        required_evidence == "loom" ? "slopcop-rust-loom-uncovered" : "slopcop-rust-miri-uncovered"
      end

      def scan_file(path, contents)
        sites = []
        comment = { active: false }
        unsafe_depth = 0
        contents.lines.each_with_index do |source, index|
          line = index + 1
          code = LanguageProvider.c_style_code(source, comment)
          next if code.strip.empty?

          add_loom_sites(sites, path, line, source, code)
          add_unsafe_sites(sites, path, line, source, code, unsafe_depth)
          unsafe_depth = update_unsafe_depth(code, unsafe_depth)
        end
        sites
      end

      def add_loom_sites(sites, path, line, source, code)
        if atomic_site?(code)
          sites << LanguageProvider.hazard(path, line, source, "rust_loom_atomic", "loom", "atomic or memory-ordering site")
        end
        if concurrency_site?(code)
          sites << LanguageProvider.hazard(path, line, source, "rust_loom_concurrency", "loom", "thread/lock/shared-concurrency site")
        end
      end

      def add_unsafe_sites(sites, path, line, source, code, unsafe_depth)
        if code.match?(/\bunsafe\s+fn\b/)
          sites << LanguageProvider.hazard(path, line, source, "rust_unsafe_fn", "miri", "unsafe function")
        end
        if code.match?(/\bunsafe\s+impl\b/)
          sites << LanguageProvider.hazard(path, line, source, "rust_unsafe_impl", "miri", "unsafe impl")
        end
        if unsafe_block_start?(code)
          sites << LanguageProvider.hazard(path, line, source, "rust_unsafe_block", "miri", "unsafe block")
        end
        if unsafe_operation?(code) && (unsafe_depth.positive? || unsafe_block_start?(code))
          sites << LanguageProvider.hazard(path, line, source, "rust_unsafe_operation", "miri", "unsafe operation inside unsafe context")
        end
      end

      def atomic_site?(code)
        code.match?(/\bAtomic(?:Bool|I(?:8|16|32|64|size)|U(?:8|16|32|64|size)|Ptr)\b/) ||
          LanguageProvider.any_include?(code, ATOMIC_NEEDLES)
      end

      def concurrency_site?(code)
        LanguageProvider.any_include?(code, CONCURRENCY_NEEDLES)
      end

      def unsafe_block_start?(code)
        code.match?(/\bunsafe\s*\{/)
      end

      def unsafe_operation?(code)
        LanguageProvider.any_include?(code, UNSAFE_API_NEEDLES) ||
          code.match?(/(?:\w|\))\s*\.\s*(?:add|offset|read|write|copy_to|copy_from)\s*\(/) ||
          code.match?(/\*\s*[A-Za-z_][A-Za-z0-9_]*/)
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
