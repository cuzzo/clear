# frozen_string_literal: true

require_relative "spec_helper"
require_relative "../lib/nil_kill/static_diff_audit"

RSpec.describe NilKill::StaticDiffAudit do
  describe "hash key parsing" do
    let(:audit) { NilKill::RubyStaticDiffAudit.new(root: "fake", added_lines: {}, context_paths: nil, finding_class: NilKill::StaticDiffAudit::Finding) }
    
    it "scans symbol hash keys with =>" do
      state = { keys: [], brace: 1, paren: 0, bracket: 0, quote: nil }
      idx = audit.send(:scan_hash_key, ":foo => 42", 0, state)
      expect(state[:keys]).to include("foo")
      expect(idx).to eq(7) # Position after =>
    end

    it "scans string hash keys with =>" do
      state = { keys: [], brace: 1, paren: 0, bracket: 0, quote: nil }
      idx = audit.send(:scan_hash_key, '"bar" => 42', 0, state)
      expect(state[:keys]).to include("bar")
      expect(idx).to eq(8) # Position after =>
    end
    
    it "scans identifier hash keys with =>" do
      state = { keys: [], brace: 1, paren: 0, bracket: 0, quote: nil }
      idx = audit.send(:scan_hash_key, "baz => 42", 0, state)
      expect(state[:keys]).to include("baz")
      expect(idx).to eq(6) # Position after =>
    end
    
    it "advances string state with escapes" do
      state = { quote: '"', escape: false }
      expect(audit.send(:advance_string_state, "\\", state)).to be(true)
      expect(state[:escape]).to be(true)
      
      expect(audit.send(:advance_string_state, "n", state)).to be(true)
      expect(state[:escape]).to be(false)
      
      expect(audit.send(:advance_string_state, '"', state)).to be(true)
      expect(state[:quote]).to be_nil
    end
    
    it "scans string literals with escapes" do
      idx, val = audit.send(:scan_string_literal, '"hello \\"world\\""', 0)
      expect(val).to eq('hello \\"world\\"')
      
      idx, val = audit.send(:scan_string_literal, '"unclosed \\"', 0)
      expect(val).to be_nil
    end
  end
end
