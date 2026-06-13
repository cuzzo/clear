require "rspec"
require_relative "../src/ast/diagnostic_registry" unless defined?(DiagnosticRegistry)
require_relative "../src/ast/diagnostic_buckets" unless defined?(DiagnosticBuckets)

RSpec.describe DiagnosticBuckets do
  it "every bucketed code is in the diagnostic registry" do
    unknown = DiagnosticBuckets::BUCKETS.flat_map { |b|
      b[:codes].reject { |c| DiagnosticRegistry.known?(c) }.map { |c| "  :#{c} (in bucket #{b[:id]})" }
    }
    expect(unknown).to be_empty,
      "Buckets reference codes that aren't in the registry:\n" + unknown.join("\n")
  end

  it "every bucketed code has a category that matches its bucket" do
    mismatched = DiagnosticBuckets::BUCKETS.flat_map { |b|
      b[:codes].reject { |c|
        entry = DiagnosticRegistry.lookup(c)
        entry.nil? || entry[:category] == b[:category]
      }.map { |c| "  :#{c} (bucket #{b[:id]} declares :#{b[:category]}, registry has :#{DiagnosticRegistry.lookup(c)[:category]})" }
    }
    expect(mismatched).to be_empty,
      "Bucket-category mismatch:\n" + mismatched.join("\n")
  end

  # Every category that has at least one bucket defined must cover
  # every code in that category — partition must be exhaustive.
  bucketed_categories = DiagnosticBuckets::BUCKETS.map { |b| b[:category] }.uniq
  bucketed_categories.each do |cat|
    it "every :#{cat} code in the registry is covered by exactly one bucket" do
      all_codes = DiagnosticRegistry::DIAGNOSTICS.select { |_, e| e[:category] == cat }.keys
      bucketed  = DiagnosticBuckets.for_category(cat).flat_map { |b| b[:codes] }
      missing = all_codes - bucketed
      extra   = bucketed - all_codes
      duplicates = bucketed.tally.select { |_, n| n > 1 }.keys

      msg = []
      msg << "Missing from buckets:\n" + missing.map { |c| "  :#{c}" }.join("\n") unless missing.empty?
      msg << "Listed in a bucket but not in :#{cat}:\n" + extra.map { |c| "  :#{c}" }.join("\n") unless extra.empty?
      msg << "Listed in multiple buckets:\n" + duplicates.map { |c| "  :#{c}" }.join("\n") unless duplicates.empty?

      expect(msg).to be_empty, msg.join("\n\n")
    end
  end

  it "returns no buckets for an unknown category" do
    expect(DiagnosticBuckets.for_category(:missing_category)).to eq([])
  end

  it "bucket frequency is in 1..5 and alien_factor is :low/:medium/:high" do
    bad = DiagnosticBuckets::BUCKETS.reject { |b|
      (1..5).include?(b[:frequency]) && %i[low medium high].include?(b[:alien_factor])
    }
    expect(bad).to be_empty,
      "Buckets with bad frequency / alien_factor:\n" +
      bad.map { |b| "  #{b[:id]}: freq=#{b[:frequency]} alien=#{b[:alien_factor]}" }.join("\n")
  end

  it "bucket ids are unique" do
    ids = DiagnosticBuckets::BUCKETS.map { |b| b[:id] }
    duplicates = ids.tally.select { |_, n| n > 1 }.keys
    expect(duplicates).to be_empty, "Duplicate bucket ids: #{duplicates.inspect}"
  end

  it "renders frequency ranks as five-position stars" do
    expect(DiagnosticBuckets.frequency_stars(1)).to eq("★☆☆☆☆")
    expect(DiagnosticBuckets.frequency_stars(3)).to eq("★★★☆☆")
    expect(DiagnosticBuckets.frequency_stars(5)).to eq("★★★★★")
  end

  it "renders alien factor labels with a fallback" do
    expect(DiagnosticBuckets.alien_label(:low)).to eq("Low")
    expect(DiagnosticBuckets.alien_label(:medium)).to eq("Med")
    expect(DiagnosticBuckets.alien_label(:high)).to eq("High")
    expect(DiagnosticBuckets.alien_label(:unknown)).to eq("?")
  end

  it "reports status from pending registry entries and complete examples" do
    examples = {
      UNDEFINED_VAR: { bad: "x", good: "LET x: Int64 = 1" },
      UNKNOWN_TYPE: { bad: "x" },
      MISSING_FUNCTION: { good: "FN main() -> PASS END" },
      ARGUMENT_TYPE_ERROR: { bad: nil, good: "FN main() -> PASS END" },
      RETURN_MISMATCH: { bad: "RETURN true", good: nil },
    }

    expect(DiagnosticBuckets.status_of(:PRIMITIVE_PASSED_AS_MUTABLE, examples)).to eq(:pending)
    expect(DiagnosticBuckets.status_of(:UNDEFINED_VAR, examples)).to eq(:annotated)
    expect(DiagnosticBuckets.status_of(:UNKNOWN_TYPE, examples)).to eq(:todo)
    expect(DiagnosticBuckets.status_of(:MISSING_FUNCTION, examples)).to eq(:todo)
    expect(DiagnosticBuckets.status_of(:ARGUMENT_TYPE_ERROR, examples)).to eq(:todo)
    expect(DiagnosticBuckets.status_of(:RETURN_MISMATCH, examples)).to eq(:todo)
    expect(DiagnosticBuckets.status_of(:STRUCT_FIELD_UNRESOLVABLE, examples)).to eq(:todo)
  end

  it "returns covered codes as a set containing every bucket code" do
    expected = DiagnosticBuckets::BUCKETS.flat_map { |bucket| bucket[:codes] }.to_set

    expect(DiagnosticBuckets.covered_codes).to eq(expected)
    expect(DiagnosticBuckets.covered_codes).to include(:UNDEFINED_VAR, :WITH_CAP_BINDING_LOST)
  end
end
