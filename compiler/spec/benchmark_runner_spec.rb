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
end
