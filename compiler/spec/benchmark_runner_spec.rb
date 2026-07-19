require "rspec"
require "tmpdir"

require_relative "../../benchmarks/runner"

RSpec.describe "benchmark leak substitutions" do
  it "applies hash-comment leak directives to code without changing comments" do
    src = <<~CHT
      # @leak: n = 1000000 -> n = 1000
      # n = 1_000_000
      FN main() RETURNS Void ->
        n = 1_000_000;
        print(n);
        RETURN;
      END
    CHT

    patched = apply_leak_substitutions(src)

    expect(patched).to include("n = 1000;")
    expect(patched).to include("# n = 1_000_000")
  end

  it "rewrites both exact and underscore-separated numeric forms on one line" do
    src = <<~CHT
      # @leak: 8000000 -> 8000
      FN main() RETURNS Void ->
        ASSERT final == 8_000_000, "expected 8000000";
        RETURN;
      END
    CHT

    patched = apply_leak_substitutions(src)

    expect(patched).to include('ASSERT final == 8000, "expected 8000";')
  end

  it "applies double-dash leak directives used by older examples" do
    src = <<~CHT
      -- @leak: count = 5000 -> count = 50
      FN main() RETURNS Void ->
        count = 5000;
        print(count);
        RETURN;
      END
    CHT

    patched = apply_leak_substitutions(src)

    expect(patched).to include("count = 50;")
  end
end

RSpec.describe "benchmark failure accounting" do
  around do |example|
    previous = $benchmark_failures
    $benchmark_failures = []
    example.run
  ensure
    $benchmark_failures = previous
  end

  it "records a failed coverage benchmark as a gate failure" do
    Dir.mktmpdir("clear-benchmark-gate") do |dir|
      source = File.join(dir, "bench.clear")
      File.write(source, "FN main() RETURNS Void -> RETURN; END\n")
      failed_status = instance_double(Process::Status, success?: false)
      allow(Open3).to receive(:capture2e).and_return(["compiler failed\n", failed_status])

      run_coverage_bench(dir)

      expect($benchmark_failures).to eq(["#{source}: coverage build or execution failed"])
    end
  end

  it "retains the captured crash tail instead of hiding non-leak failures" do
    output = (1..25).map { |i| "diagnostic #{i}\n" }.join

    tail = benchmark_output_tail(output)

    expect(tail).not_to include("diagnostic 5\n")
    expect(tail).to include("      diagnostic 6\n")
    expect(tail).to include("      diagnostic 25\n")
  end
end

RSpec.describe "scaled MVCC writer-pressure benchmark", :integration do
  it "completes repeatedly when a measured phase is shorter than one millisecond" do
    source_path = File.expand_path(
      "../../benchmarks/inter-clear/06_concurrent_mvcc_writer_pressure/bench.clear",
      __dir__,
    )

    Dir.mktmpdir("clear-mvcc-writer-pressure") do |dir|
      source = File.join(dir, "bench.clear")
      binary = File.join(dir, "bench")
      File.write(source, apply_leak_substitutions(File.read(source_path)))

      build_output, build_status = Open3.capture2e(
        File.expand_path("../../clear", __dir__), "build", source, "-o", binary,
      )
      expect(build_status.success?).to be(true), build_output

      50.times do |attempt|
        output, status = Open3.capture2e({ "CLEAR_THREADS" => "4" }, binary)
        expect(status.success?).to be(true), "attempt #{attempt + 1}: #{output}"
      end
    end
  end
end
