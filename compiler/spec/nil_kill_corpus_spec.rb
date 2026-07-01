require "open3"
require_relative "../ruby/backends/transpiler" unless defined?(ZigTranspiler)

RSpec.describe "nil-kill corpus generators" do
  it "excludes known non-buildable explicit-parallel benchmark corpus files" do
    stdout, stderr, status = Open3.capture3("bundle", "exec", "ruby", "tools/clear-nil-kill-require-cht-corpus.rb")
    expect(status).to be_success, stderr

    corpus_path = stdout.strip
    corpus = File.read(corpus_path)
    expect(corpus).not_to include("benchmarks/concurrent/12_false_sharing/bench.cht")
    expect(corpus).not_to include("benchmarks/concurrent/13_rwlock_starvation/bench.cht")
    expect(corpus).not_to include("benchmarks/concurrent/14_nested_lock/bench.cht")
    expect(corpus).not_to include("benchmarks/concurrent/19_atomic_ptr/bench.cht")
    expect(corpus).not_to include("benchmarks/inter-clear/03_concurrent_mvcc_vs_rwlock/bench.cht")
    expect(corpus).not_to include("benchmarks/inter-clear/04_concurrent_mvcc_fat_struct/bench.cht")
    expect(corpus).not_to include("benchmarks/inter-clear/05_concurrent_mvcc_pure_read/bench.cht")
    expect(corpus).not_to include("benchmarks/inter-clear/06_concurrent_mvcc_writer_pressure/bench.cht")
  end

  it "transpiles MAL corpus tests without importing the interpreter entrypoint" do
    source_dir = File.expand_path("../../examples/mal", __dir__)
    source = File.read(File.join(source_dir, "mal-corpus-tests.cht"))

    expect {
      ZigTranspiler.new.transpile(source, source_dir: source_dir)
    }.not_to raise_error
  end
end
