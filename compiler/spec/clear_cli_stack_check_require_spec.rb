require "rspec"
require "tmpdir"
require "fileutils"
require "open3"

# Regression: `clear build --stack-check` on a file that uses
# file-style REQUIRE (e.g. `REQUIRE "other.clear"`) must run the
# tier-sizing analysis end-to-end. Previously the analysis
# constructed `SemanticAnnotator.new` without an importer, so the
# annotator's REQUIRE handler raised and the rescue silently logged
# "[stack-check] Analysis failed", letting the build proceed without
# tier upgrade. For files with very large frames this overflowed
# the default 16 KB Standard fiber stack into adjacent slab memory
# and corrupted fiber slab headers at scheduler shutdown.

RSpec.describe "clear build --stack-check with file-style REQUIRE", :integration do
  PROJECT_ROOT_REQ = File.expand_path("../..", __dir__) unless defined?(PROJECT_ROOT_REQ)
  CLEAR_BIN_REQ    = File.join(PROJECT_ROOT_REQ, "clear") unless defined?(CLEAR_BIN_REQ)

  it "succeeds without [stack-check] Analysis failed and emits a tier line" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "helper.clear"), <<~CLEAR)
        FN helper(n: Int64) RETURNS Int64 ->
          RETURN n + 1;
        END
      CLEAR

      main_src = File.join(dir, "main.clear")
      File.write(main_src, <<~CLEAR)
        REQUIRE "helper.clear"

        FN main() RETURNS Void ->
          x = helper(41);
          RETURN;
        END
      CLEAR

      bin_path = File.join(dir, "test_bin")
      stdout, status = Open3.capture2e(CLEAR_BIN_REQ, "build", "--stack-check", main_src, "-o", bin_path)

      expect(status.success?).to be(true), "build failed:\n#{stdout}"
      expect(stdout).not_to include("[stack-check] Analysis failed")
      # On success, stack-check prints "  main fiber: ..." or
      # "[exact] main fiber: ..."; either is proof analysis ran.
      expect(stdout).to match(/main fiber:/)
    end
  end
end
