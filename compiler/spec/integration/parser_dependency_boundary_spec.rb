# typed: false

require "rspec"
require "open3"

RSpec.describe "parser dependency boundary" do
  it "does not load annotator signature analysis or Zig backend rendering" do
    root = File.expand_path("../../..", __dir__)
    script = <<~'RUBY'
      require "ast/parser"
      puts $LOADED_FEATURES.grep(/compiler\/ruby/)
    RUBY
    output, status = Open3.capture2e(
      RbConfig.ruby, "-I#{File.join(root, 'compiler/ruby')}", "-e", script,
      chdir: root,
    )

    expect(status).to be_success, output
    expect(output).not_to include("annotator/helpers/function_signature.rb")
    expect(output).not_to include("annotator/helpers/fixable_helpers.rb")
    expect(output).not_to include("backends/zig_type.rb")
    expect(output.lines.grep(/compiler\/ruby/).length).to be <= 18
  end

  it "loads Zig rendering only when a backend spelling is requested" do
    require_relative "../../ruby/ast/type"
    expect(Type.new(:Int64).zig_type).to eq("i64")
    expect(defined?(TypeZigRenderer)).to eq("constant")
  end
end
