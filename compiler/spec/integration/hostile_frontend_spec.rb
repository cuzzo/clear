# typed: false

require "rspec"
require "open3"

RSpec.describe "hostile frontend subprocess target" do
  it "keeps minimized hostile-source failures as permanent diagnostics" do
    root = File.expand_path("../../..", __dir__)
    worker = [RbConfig.ruby, File.join(root, "tools/fuzz/hostile_frontend.rb"), "--worker"]
    fixtures = Dir[File.join(__dir__, "fixtures/hostile_frontend/*.clear.bin")]

    expect(fixtures).not_to be_empty
    fixtures.each do |fixture|
      output, status = Open3.capture2e(*worker, stdin_data: File.binread(fixture), chdir: root)
      expect(status).to be_success, "#{File.basename(fixture)}: #{output}"
    end
  end

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
