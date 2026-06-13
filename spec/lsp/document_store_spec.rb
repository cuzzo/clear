require "rspec"
require_relative "../../src/lsp/document_store" unless defined?(LSP::DocumentStore)

RSpec.describe LSP::DocumentStore do
  let(:store) { described_class.new }
  let(:uri)   { "file:///tmp/foo.cht" }

  describe "#open" do
    it "stores text + version" do
      store.open(uri, "hello", 1)
      expect(store.text(uri)).to eq("hello")
      expect(store.version(uri)).to eq(1)
    end
  end

  describe "#update" do
    it "replaces text and bumps version" do
      store.open(uri, "v1", 1)
      store.update(uri, "v2", 2)
      expect(store.text(uri)).to eq("v2")
      expect(store.version(uri)).to eq(2)
    end

    it "returns nil when the uri isn't open" do
      expect(store.update("file:///nope.cht", "x", 1)).to be_nil
    end

    it "invalidates cached findings on update" do
      store.open(uri, "v1", 1)
      doc = store.get(uri)
      doc.cached_findings = :stale_value
      doc.cached_version  = 1

      store.update(uri, "v2", 2)
      expect(doc.cached_findings).to be_nil
      expect(doc.cached_version).to be_nil
    end
  end

  describe "#close" do
    it "drops the document" do
      store.open(uri, "x", 1)
      store.close(uri)
      expect(store.get(uri)).to be_nil
    end

    it "is a no-op for an unknown uri" do
      expect { store.close("file:///nope.cht") }.not_to raise_error
    end
  end

  describe "cache fields" do
    it "exposes cached_findings and cached_version" do
      store.open(uri, "x", 1)
      doc = store.get(uri)
      doc.cached_findings = "FINDINGS"
      doc.cached_version  = 1
      expect(doc.cached_findings).to eq("FINDINGS")
      expect(doc.cached_version).to eq(1)
    end
  end

  describe "#each" do
    it "iterates every open document" do
      store.open("file:///a.cht", "a", 1)
      store.open("file:///b.cht", "b", 1)
      texts = []
      store.each { |d| texts << d.text }
      expect(texts.sort).to eq(["a", "b"])
    end
  end
end
