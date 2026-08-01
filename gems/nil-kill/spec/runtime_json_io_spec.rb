# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe NilKill::Runtime::JsonIO do
  it "reads plain and gzip JSONL transparently and compresses atomically" do
    Dir.mktmpdir("nil-kill-json-io") do |dir|
      plain = File.join(dir, "events.jsonl")
      File.write(plain, "{\"event\":1}\n{\"event\":2}\n")

      compressed = NilKill::Runtime::JsonIO.gzip_file(plain)

      expect(compressed).to end_with(".jsonl.gz")
      expect(File.exist?(plain)).to be(false)
      expect(File.binread(compressed, 2).bytes).to eq([0x1f, 0x8b])
      expect(NilKill::Runtime::JsonIO.foreach(compressed).to_a)
        .to eq(["{\"event\":1}\n", "{\"event\":2}\n"])
      expect(NilKill::Runtime::JsonIO.matching(dir, "events*.jsonl")).to eq([compressed])
    end
  end

end
