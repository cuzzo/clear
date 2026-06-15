# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe AutoType::GuardedAutocorrect do
  it "restores Sorbet autocorrect removals of defensive safe navigation" do
    Dir.mktmpdir("auto-type-autocorrect") do |dir|
      path = File.join(dir, "example.rb")
      File.write(path, "value&.name\n")
      autocorrect = described_class.new([])
      snapshot = { path => [{ line: 1, content: "value&.name\n" }] }

      File.write(path, "value.name\n")

      expect(autocorrect.send(:restore_safe_navigation, snapshot)).to eq(1)
      expect(File.read(path)).to eq("value&.name\n")
    end
  end

  it "restores known bogus did-you-mean autocorrect replacements" do
    Dir.mktmpdir("auto-type-autocorrect") do |dir|
      path = File.join(dir, "example.rb")
      original = ["node.class.module_alias\n"]
      File.write(path, "node.class.module_eval\n")
      autocorrect = described_class.new([])

      expect(autocorrect.send(:restore_bogus_replacements, path => original)).to eq(1)
      expect(File.read(path)).to eq("node.class.module_alias\n")
    end
  end
end
