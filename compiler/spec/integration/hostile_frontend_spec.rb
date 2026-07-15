# typed: false

require "rspec"
require "open3"

RSpec.describe "hostile frontend subprocess target" do
  it "accepts arbitrary and mutation-derived source only as a parse or diagnostic" do
    root = File.expand_path("../../..", __dir__)
    command = [
      RbConfig.ruby,
      File.join(root, "tools/fuzz/hostile_frontend.rb"),
      "--cases", "12",
      "--seed", "20260715",
      "--timeout", "1.0",
      "--memory-mb", "1024",
    ]
    output, status = Open3.capture2e(*command, chdir: root)

    expect(status).to be_success, output
    expect(output).to include("12 cases passed")
  end
end
