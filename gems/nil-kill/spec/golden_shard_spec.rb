# frozen_string_literal: true

require_relative "spec_helper"
require "digest"

# The trace document a shard adds up to, byte for byte.
#
# This exists to make a port provable. Turning a shard's JSONL into
# `runtime-trace.json.gz` is ~830 lines of Ruby across four files and is about
# to be rewritten; the espalier evidence diff that guarded earlier ports has a
# ~600-anchor noise floor and would not notice a subtle change here.
#
# Fields are compared by digest, and a mismatch reports the first differing
# entry rather than the whole field: this shard carries 4,000 calls, and
# rendering a diff of that is slower than the collect that produced it.
RSpec.describe "the trace document a shard produces" do
  # A method, not a constant: a constant assigned inside a describe block lands
  # on Object, where another spec file's identically named one overwrites it.
  def fixture
    File.expand_path("fixtures/golden_shard", __dir__)
  end

  def digest(value)
    Digest::SHA256.hexdigest(JSON.generate(value))
  end

  # Where two values first disagree, in a form a person can read.
  def first_difference(built, expected)
    if built.is_a?(Array) && expected.is_a?(Array)
      return "length #{built.length} vs #{expected.length}" if built.length != expected.length

      at = built.each_index.find { |i| built[i] != expected[i] }
      return "entry #{at}:\n    built    #{JSON.generate(built[at])[0, 300]}\n" \
             "    expected #{JSON.generate(expected[at])[0, 300]}"
    end
    "built    #{JSON.generate(built)[0, 300]}\n    expected #{JSON.generate(expected)[0, 300]}"
  end

  it "is exactly what the recorded shard produced" do
    plan = JSON.parse(File.read(File.join(fixture, "plan-digest.json")))
    expected = JSON.parse(
      Zlib::GzipReader.open(File.join(fixture, "expected-runtime-trace.json.gz"), &:read)
    )

    Dir.mktmpdir("nil-kill-golden", NilKill::ROOT) do |dir|
      FileUtils.cp_r(Dir.glob(File.join(fixture, "input", "*")), dir)
      built = NilKill::Runtime::TraceArtifact.build(
        root: NilKill::ROOT, runtime_dir: dir, plan: plan,
        languages: expected.fetch("languages"), run_ids: expected.fetch("run_ids")
      )

      expect(built.keys.sort).to eq(expected.keys.sort)
      differing = expected.keys.reject { |field| digest(built[field]) == digest(expected[field]) }
      expect(differing).to be_empty, lambda {
        differing.map { |field| "#{field}: #{first_difference(built[field], expected[field])}" }
          .join("\n")
      }
    end
  end
end
