# frozen_string_literal: true

require "json"
require "fileutils"
require "minitest/autorun"
require "tmpdir"

require_relative "../lib/slopcop"

class ConstraintsSystemsProviderTest < Minitest::Test
  def test_new_systems_providers_are_registered
    assert_same SlopCop::Constraints::RustProvider, SlopCop::Constraints.providers.fetch("rust")
    assert_same SlopCop::Constraints::CProvider, SlopCop::Constraints.providers.fetch("c")
    assert_same SlopCop::Constraints::CppProvider, SlopCop::Constraints.providers.fetch("cpp")
    assert_same SlopCop::Constraints::CsharpProvider, SlopCop::Constraints.providers.fetch("csharp")
  end

  def test_rust_provider_finds_loom_and_unsafe_hazards
    with_file("src/lib.rs", <<~RS) do |dir, path|
      use std::sync::atomic::{AtomicUsize, Ordering};

      pub fn run(ptr: *const u8) -> usize {
          let value = AtomicUsize::new(0);
          value.fetch_add(1, Ordering::SeqCst);
          unsafe {
              ptr.add(1).read()
          }
      }
    RS
      hazards = SlopCop::Constraints::RustProvider.scan_hazards(repo: dir, paths: [path])
      types = hazards.map { |hazard| hazard[:hazard_type] }

      assert_includes types, "rust_loom_atomic"
      assert_includes types, "rust_unsafe_block"
      assert_includes types, "rust_unsafe_operation"
    end
  end

  def test_rust_provider_suppresses_matching_loom_coverage
    with_file("src/lib.rs", "pub fn run(v: &AtomicUsize) { v.fetch_add(1, Ordering::SeqCst); }\n") do |dir, path|
      evidence = SlopCop::Constraints::Evidence.from_specs(["loom:#{coverage_json(dir, path, 1 => 1)}"], repo: dir)
      findings = SlopCop::Constraints::RustProvider.findings(repo: dir, additions: { path => [1] }, evidence: evidence)

      assert_empty findings
    end
  end

  def test_c_provider_finds_sanitizer_hazard_families
    with_file("src/runtime.c", <<~C) do |dir, path|
      #include <pthread.h>
      void run(char *dst, char *src, int n) {
          pthread_mutex_lock(&lock);
          char *buf = malloc(32);
          memcpy(dst, src, n);
          int shifted = n << src[0];
          free(buf);
      }
    C
      hazards = SlopCop::Constraints::CProvider.scan_hazards(repo: dir, paths: [path])
      types = hazards.map { |hazard| hazard[:hazard_type] }

      assert_includes types, "c_tsan_concurrency"
      assert_includes types, "c_asan_raw_memory_api"
      assert_includes types, "c_lsan_lifetime"
      assert_includes types, "c_ubsan_arithmetic"
    end
  end

  def test_cpp_provider_finds_sanitizer_hazard_families
    with_file("src/runtime.cpp", <<~CPP) do |_dir, path|
      #include <atomic>
      void run(char *dst, char *src, int n) {
          std::atomic<int> ready;
          auto *buf = new char[32];
          std::memcpy(dst, src, n);
          auto raw = reinterpret_cast<int *>(dst);
          auto shifted = n << raw[0];
          delete[] buf;
      }
    CPP
      hazards = SlopCop::Constraints::CppProvider.scan_file(path, File.read(File.join(_dir, path)))
      types = hazards.map { |hazard| hazard[:hazard_type] }

      assert_includes types, "cpp_tsan_concurrency"
      assert_includes types, "cpp_asan_raw_memory_api"
      assert_includes types, "cpp_asan_pointer_or_cast"
      assert_includes types, "cpp_lsan_lifetime"
      assert_includes types, "cpp_ubsan_cast"
      assert_includes types, "cpp_ubsan_arithmetic"
    end
  end

  def test_csharp_provider_finds_concurrency_and_unsafe_hazards
    with_file("src/Worker.cs", <<~CS) do |dir, path|
      using System.Threading.Tasks;
      public unsafe class Worker {
          public void Run(byte* ptr) {
              Task.Run(() => {});
              fixed (byte* p = buffer) {
                  *p = 1;
              }
          }
      }
    CS
      hazards = SlopCop::Constraints::CsharpProvider.scan_hazards(repo: dir, paths: [path])
      types = hazards.map { |hazard| hazard[:hazard_type] }

      assert_includes types, "csharp_concurrency"
      assert_includes types, "csharp_unsafe_memory"
    end
  end

  def test_comment_and_string_hazards_are_ignored
    with_file("src/runtime.c", <<~C) do |dir, path|
      void run(void) {
          // pthread_mutex_lock(&lock);
          const char *s = "memcpy(dst, src, n)";
      }
    C
      assert_empty SlopCop::Constraints::CProvider.scan_hazards(repo: dir, paths: [path])
    end
  end

  private

  def with_file(path, contents)
    Dir.mktmpdir do |dir|
      abs = File.join(dir, path)
      FileUtils.mkdir_p(File.dirname(abs))
      File.write(abs, contents)
      yield dir, path
    end
  end

  def coverage_json(dir, path, hits)
    coverage = File.join(dir, "coverage.json")
    File.write(coverage, JSON.dump(coverage: { path => hits.transform_keys(&:to_s) }))
    coverage
  end
end
