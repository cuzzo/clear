# typed: false
# frozen_string_literal: true

require "tmpdir"

require_relative "../../ruby/incremental/module_cache"

RSpec.describe Incremental::ModuleCache do
  around do |example|
    Dir.mktmpdir("module-cache-spec-") do |dir|
      @dir = dir
      example.run
    end
  end

  def write(name, contents)
    path = File.join(@dir, name)
    File.write(path, contents)
    path
  end

  def cache(compiler_key: "compiler-1")
    described_class.new(dir: File.join(@dir, "cache"), compiler_key: compiler_key)
  end

  it "recompiles a unit only when one of its own sources changes" do
    source = write("leaf.clear", "one")
    compiles = 0
    unit = -> { cache.fetch("leaf", [source]) { compiles += 1; "compiled:#{File.read(source)}" } }

    expect(unit.call).to eq("compiled:one")
    expect(unit.call).to eq("compiled:one")
    expect(compiles).to eq(1)

    File.write(source, "two")
    expect(unit.call).to eq("compiled:two")
    expect(compiles).to eq(2)
  end

  it "invalidates a unit when a source it read transitively changes" do
    leaf = write("leaf.clear", "leaf-one")
    root = write("root.clear", "root")
    compiles = { leaf: 0, root: 0 }

    build = lambda do
      store = cache
      store.fetch("root", [root]) do
        compiles[:root] += 1
        inner = store.fetch("leaf", [leaf]) do
          compiles[:leaf] += 1
          File.read(leaf)
        end
        "root(#{inner})"
      end
    end

    expect(build.call).to eq("root(leaf-one)")
    expect(build.call).to eq("root(leaf-one)")
    expect(compiles).to eq({ leaf: 1, root: 1 })

    File.write(leaf, "leaf-two")
    expect(build.call).to eq("root(leaf-two)")
    expect(compiles).to eq({ leaf: 2, root: 2 })
  end

  it "still records a shared dependency the importer resolved from its own cache" do
    leaf = write("leaf.clear", "leaf-one")
    first = write("first.clear", "first")
    second = write("second.clear", "second")
    compiles = Hash.new(0)

    build = lambda do
      store = cache
      # Whatever compiles the leaf first wins; the importer serves the second
      # request from memory without re-entering the cache.
      seen = {}
      compile_leaf = lambda do
        return seen[:leaf] if seen.key?(:leaf)

        seen[:leaf] = store.fetch("leaf", [leaf]) { compiles[:leaf] += 1; File.read(leaf) }
      end
      one = store.fetch("first", [first]) { compiles[:first] += 1; compile_leaf.call }
      two = store.fetch("second", [second]) do
        compiles[:second] += 1
        store.reuse("leaf")
        seen.key?(:leaf) ? seen[:leaf] : compile_leaf.call
      end
      [one, two]
    end

    expect(build.call).to eq(%w[leaf-one leaf-one])
    expect(compiles).to eq({ leaf: 1, first: 1, second: 1 })

    File.write(leaf, "leaf-two")
    expect(build.call).to eq(%w[leaf-two leaf-two])
    expect(compiles).to eq({ leaf: 2, first: 2, second: 2 })
  end

  it "keeps generations apart so a compiler change never reuses old units" do
    source = write("leaf.clear", "one")
    compiles = 0
    build = ->(key) { cache(compiler_key: key).fetch("leaf", [source]) { compiles += 1; "compiled" } }

    build.call("compiler-1")
    build.call("compiler-1")
    build.call("compiler-2")

    expect(compiles).to eq(2)
  end

  it "stores nothing when the unit fails to compile" do
    source = write("leaf.clear", "one")
    store = cache

    expect { store.fetch("leaf", [source]) { raise ArgumentError, "boom" } }.to raise_error(ArgumentError)

    compiled = store.fetch("leaf", [source]) { "recovered" }
    expect(compiled).to eq("recovered")
  end

  it "is off unless the environment names both a directory and a key" do
    bare = ENV.to_h.reject { |name, _| [described_class::DIR_ENV, described_class::KEY_ENV].include?(name) }
    stub_const("ENV", bare)
    expect(described_class.from_env).to be_nil

    stub_const("ENV", bare.merge(
      described_class::DIR_ENV => File.join(@dir, "cache"),
      described_class::KEY_ENV => "compiler-1"
    ))
    expect(described_class.from_env).to be_a(described_class)
  end
end
