# typed: false
# frozen_string_literal: true

require "spec_helper"

RSpec.describe "production Ruby visibility" do
  it "does not bypass method visibility with send" do
    root = File.expand_path("../ruby", __dir__)
    bypass = /(?<!public_)(?<!__)\bsend\(|__send__\(/
    violations = Dir.glob(File.join(root, "**", "*.rb")).sort.filter_map do |path|
      File.foreach(path).with_index(1).filter_map do |line, line_number|
        "#{path}:#{line_number}: #{line.strip}" if line.match?(bypass)
      end
    end.flatten

    expect(violations).to eq([]), <<~MESSAGE
      Production code must not bypass Ruby visibility with send/__send__.
      Use an ordinary private call for same-receiver behavior, public_send for
      genuinely dynamic public protocols, or define an honest narrow API.

      #{violations.join("\n")}
    MESSAGE
  end
end
