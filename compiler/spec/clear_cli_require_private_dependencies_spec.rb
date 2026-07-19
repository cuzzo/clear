require "rspec"
require "tmpdir"
require "fileutils"
require "open3"

RSpec.describe "clear build with private REQUIRE dependencies", :integration do
  PROJECT_ROOT_PRIVATE_REQUIRE = File.expand_path("../..", __dir__) unless defined?(PROJECT_ROOT_PRIVATE_REQUIRE)
  CLEAR_BIN_PRIVATE_REQUIRE = File.join(PROJECT_ROOT_PRIVATE_REQUIRE, "clear") unless defined?(CLEAR_BIN_PRIVATE_REQUIRE)

  it "keeps private helpers and internal types used by a public function" do
    Dir.mktmpdir do |dir|
      provider_dir = File.join(dir, "provider")
      consumer_dir = File.join(dir, "consumer")
      FileUtils.mkdir_p(provider_dir)
      FileUtils.mkdir_p(consumer_dir)

      File.write(File.join(provider_dir, "helper.clear"), <<~CLEAR)
        STRUCT Box { value: Int64 }

        PRIVATE FN unbox(box: Box) RETURNS Int64 ->
          RETURN box.value;
        END

        PUB FN answer() RETURNS Int64 ->
          RETURN unbox(Box{ value: 42 });
        END
      CLEAR

      main_src = File.join(consumer_dir, "main.clear")
      File.write(main_src, <<~CLEAR)
        REQUIRE "../provider/helper.clear";

        FN main() RETURNS Void ->
          print(answer().toString());
          RETURN;
        END
      CLEAR

      bin_path = File.join(dir, "test_bin")
      build_output, build_status = Open3.capture2e(
        CLEAR_BIN_PRIVATE_REQUIRE, "build", main_src, "-o", bin_path, "--force"
      )
      expect(build_status.success?).to be(true), "build failed:\n#{build_output}"

      run_output, run_status = Open3.capture2e(bin_path)
      expect(run_status.success?).to be(true), "run failed:\n#{run_output}"
      expect(run_output).to include("42")
    end
  end
end
