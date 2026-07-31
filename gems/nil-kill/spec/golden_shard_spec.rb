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

  # Content, not key order. Every consumer of these files parses them, so the
  # order a producer happened to write its keys in is not part of the contract
  # -- and holding a port to it would be asserting something nothing depends on.
  def canonical(value)
    case value
    when Hash then value.keys.sort.to_h { |key| [key, canonical(value[key])] }
    when Array then value.map { |entry| canonical(entry) }
    else value
    end
  end

  def digest(value)
    Digest::SHA256.hexdigest(JSON.generate(canonical(value)))
  end

  # Where two values first disagree, in a form a person can read.
  def first_difference(built, expected)
    if built.is_a?(Array) && expected.is_a?(Array)
      return "length #{built.length} vs #{expected.length}" if built.length != expected.length

      at = built.each_index.find { |i| canonical(built[i]) != canonical(expected[i]) }
      return "no entry differs (ordering only)" if at.nil?

      return "entry #{at}:\n    built    #{JSON.generate(built[at])[0, 300]}\n" \
             "    expected #{JSON.generate(expected[at])[0, 300]}"
    end
    "built    #{JSON.generate(built)[0, 300]}\n    expected #{JSON.generate(expected)[0, 300]}"
  end

  # The rows the collector document shapes into, before anything joins them.
  # Recorded from the same shard, so the two tests together pin the whole
  # transformation from what the VM saw to what the join reads.
  # The plan as the collector receives it, not a projection: a port tested
  # against a hand-trimmed plan is tested against something that never occurs.
  def plan
    @plan ||= JSON.parse(Zlib::GzipReader.open(File.join(fixture, "plan.json.gz"), &:read))
  end

  it "shapes the collector document into exactly the recorded rows" do
    Dir.mktmpdir("nil-kill-golden-rows", NilKill::ROOT) do |dir|
      raw = Dir.glob(File.join(fixture, "input", "collector-raw-*.json.gz")).first
      FileUtils.cp(raw, dir)
      plan_path = File.join(dir, "plan.json")
      File.write(plan_path, JSON.generate(plan))
      NilKill::Runtime::DomainDeriver.export(
        runtime_dirs: [dir], plan: plan_path, source_roles: nil, root: NilKill::ROOT
      )

      recorded = Dir.glob(File.join(fixture, "input", "*.jsonl.gz"))
      expect(recorded).not_to be_empty
      differing = recorded.filter_map do |path|
        name = File.basename(path, ".gz")
        built = File.join(dir, name)
        next "#{name}: not written" unless File.file?(built)

        expected = Zlib::GzipReader.open(path, &:readlines).map { |line| JSON.parse(line) }
        actual = File.readlines(built).map { |line| JSON.parse(line) }
        next if digest(actual) == digest(expected)

        "#{name}: #{first_difference(actual, expected)}"
      end
      expect(differing).to be_empty, -> { differing.join("\n") }
    end
  end

  it "is exactly what the recorded shard produced" do
    expected = JSON.parse(
      Zlib::GzipReader.open(File.join(fixture, "expected-runtime-trace.json.gz"), &:read)
    )

    Dir.mktmpdir("nil-kill-golden", NilKill::ROOT) do |dir|
      FileUtils.cp_r(Dir.glob(File.join(fixture, "input", "*")), dir)
      built = NilKill::Runtime::TraceArtifact.build(
        root: NilKill::ROOT, runtime_dir: dir, plan: { "plan_digest" => plan.fetch("plan_digest") },
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
