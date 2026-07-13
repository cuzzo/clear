# frozen_string_literal: true
# typed: false

require_relative 'spec_helper'
require_relative '../../tools/fuzz/fail_complete'

RSpec.describe FuzzFailComplete do
  def result(pass: [], failures: [], compile_failures: [], leaks: [])
    [pass, failures, compile_failures, leaks]
  end

  it 'runs a green batch only once' do
    attempts = []
    output = described_class.run(%i[a b c]) do |entries|
      attempts << entries
      result(pass: entries)
    end

    expect(attempts).to eq([%i[a b c]])
    expect(output).to eq(result(pass: %i[a b c]))
  end

  it 'isolates every independently failing entry' do
    attempts = []
    output = described_class.run(%i[a b c d]) do |entries|
      attempts << entries
      failures = entries & %i[b d]
      result(pass: entries - failures, failures: failures)
    end

    expect(output).to eq(result(pass: %i[a c], failures: %i[b d]))
    expect(attempts).to include([:b], [:d])
  end

  it 'preserves a failure caused only by combining cells' do
    output = described_class.run(%i[a b]) do |entries|
      entries.length > 1 ? result(failures: [:combined]) : result(pass: entries)
    end

    expect(output).to eq(result(failures: [:combined]))
  end
end
