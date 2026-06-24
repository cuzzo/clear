# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "json"
require "fileutils"
require_relative "../lib/slopcop"

class DecomplexVerdictCovTest < Minitest::Test
  def test_flatten_detectors
    detectors = {
      "semantic_alias" => {
        "alias_clusters" => { "sites" => ["a.rb:foo:10"] }
      },
      "predicate_alias" => {
        "alias_clusters" => { "sites" => ["b.rb:bar:10"] }
      },
      "other_group" => {
        "some_detector" => { "sites" => ["c.rb:baz:10"] }
      },
      "direct_detector" => { "sites" => ["d.rb:qux:10"] }
    }
    
    flat = SlopCop::DecomplexVerdict.send(:flatten_detectors, detectors)
    assert_equal({ "sites" => ["a.rb:foo:10"] }, flat["semantic_predicate_aliases"])
    assert_equal({ "sites" => ["b.rb:bar:10"] }, flat["exact_predicate_aliases"])
    assert_equal({ "sites" => ["c.rb:baz:10"] }, flat["some_detector"])
    assert_equal({ "sites" => ["d.rb:qux:10"] }, flat["direct_detector"])
  end

  def test_index_empty_files
    verdict = SlopCop::DecomplexVerdict.index([])
    assert_equal :absent, verdict[:status]
  end

  def test_index_error_rescue
    # Force process_detectors to raise an error
    SlopCop::DecomplexVerdict.stub :load_decomplex_facts, { detectors: { "direct" => "bad" }, status: :ok } do
      SlopCop::DecomplexVerdict.stub :process_detectors, ->(*args) { raise StandardError, "forced error" } do
        verdict = SlopCop::DecomplexVerdict.index(["a.rb"])
        assert_equal :error, verdict[:status]
      end
    end
  end

  def test_load_decomplex_facts_env_absent
    ENV["DECOMPLEX_FACTS_FILE"] = ""
    # Make binary not executable/missing
    ENV["DECOMPLEX_RUST_BINARY"] = "/missing-binary"
    res = SlopCop::DecomplexVerdict.send(:load_decomplex_facts, ["a.rb"])
    assert_equal :absent, res[:status]
    ENV["DECOMPLEX_FACTS_FILE"] = nil
    ENV["DECOMPLEX_RUST_BINARY"] = nil
  end

  def test_load_decomplex_facts_execution_fails
    ENV["DECOMPLEX_FACTS_FILE"] = ""
    # Point to a valid executable that fails (like /bin/false)
    ENV["DECOMPLEX_RUST_BINARY"] = "/bin/false"
    res = SlopCop::DecomplexVerdict.send(:load_decomplex_facts, ["a.rb"])
    assert_equal :error, res[:status]
    ENV["DECOMPLEX_FACTS_FILE"] = nil
    ENV["DECOMPLEX_RUST_BINARY"] = nil
  end

  def test_load_decomplex_facts_success
    ENV["DECOMPLEX_FACTS_FILE"] = ""
    Dir.mktmpdir do |dir|
      mock_facts = "#{dir}/facts.json"
      File.write(mock_facts, JSON.dump({ "detectors" => { "false_simplicity" => [] } }))
      
      # Mock system to write the facts and return true
      # Kernel.system or self.system. Here it is ok = system(...) inside load_decomplex_facts.
      # We can stub :system
      SlopCop::DecomplexVerdict.stub :system, ->(*args) { File.write(args[3], File.read(mock_facts)); true } do
        # We also need to stub File.executable? for the binary
        File.stub :executable?, true do
          res = SlopCop::DecomplexVerdict.send(:load_decomplex_facts, ["a.rb"])
          assert_equal :ok, res[:status]
          assert_equal([], res[:detectors]["false_simplicity"])
        end
      end
    end
    ENV["DECOMPLEX_FACTS_FILE"] = nil
  end

  def test_extract_sites
    # Array payload with hash items
    arr_payload = [
      { "sites" => ["a.rb:foo:10"], "spans" => { "a.rb:foo:10" => [10, 0, 10, 5] } }
    ]
    sites = SlopCop::DecomplexVerdict.send(:extract_sites, arr_payload)
    assert_equal 1, sites.size
    assert_equal "a.rb:foo:10", sites.first[:site]
    assert_equal [10, 0, 10, 5], sites.first[:span]

    # Hash payload without sites (nested values)
    hash_payload = {
      "some_sub_key" => { "sites" => ["b.rb:bar:20"] }
    }
    sites = SlopCop::DecomplexVerdict.send(:extract_sites, hash_payload)
    assert_equal 1, sites.size
    assert_equal "b.rb:bar:20", sites.first[:site]
  end

  def test_parse_loc_malformed
    assert_equal [], SlopCop::DecomplexVerdict.send(:parse_loc, "malformed")
    assert_equal [], SlopCop::DecomplexVerdict.send(:parse_loc, "a:b")
    assert_equal ["a", "b", "10"], SlopCop::DecomplexVerdict.send(:parse_loc, "a:b:10")
  end
end
