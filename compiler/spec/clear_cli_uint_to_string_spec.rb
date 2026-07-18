require "rspec"
require "tmpdir"
require "open3"

RSpec.describe "UInt64.toString", :integration do
  PROJECT_ROOT_UINT_STRING = File.expand_path("../..", __dir__) unless defined?(PROJECT_ROOT_UINT_STRING)
  CLEAR_BIN_UINT_STRING = File.join(PROJECT_ROOT_UINT_STRING, "clear") unless defined?(CLEAR_BIN_UINT_STRING)

  it "formats values above the signed 64-bit range" do
    Dir.mktmpdir do |dir|
      source = File.join(dir, "main.clear")
      File.write(source, <<~CLEAR)
        FN main() RETURNS Void ->
          print(18_446_744_073_709_551_615_u64.toString());
          RETURN;
        END
      CLEAR

      binary = File.join(dir, "main")
      build_output, build_status = Open3.capture2e(
        CLEAR_BIN_UINT_STRING, "build", source, "-o", binary, "--force"
      )
      expect(build_status.success?).to be(true), "build failed:\n#{build_output}"

      run_output, run_status = Open3.capture2e(binary)
      expect(run_status.success?).to be(true), "run failed:\n#{run_output}"
      expect(run_output).to include("18446744073709551615")
    end
  end
end
