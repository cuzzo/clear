require "rspec"
require "tmpdir"
require "fileutils"
require "open3"

RSpec.describe "clear build with --pkg registered packages", :integration do
  PROJECT_ROOT_REGISTERED_PKG = File.expand_path("../..", __dir__) unless defined?(PROJECT_ROOT_REGISTERED_PKG)
  CLEAR_BIN_REGISTERED_PKG = File.join(PROJECT_ROOT_REGISTERED_PKG, "clear") unless defined?(CLEAR_BIN_REGISTERED_PKG)

  it "resolves an aliased registered package imported by a local REQUIRE dependency" do
    Dir.mktmpdir do |dir|
      generated_dir = File.join(dir, "generated")
      app_dir = File.join(dir, "app")
      FileUtils.mkdir_p(generated_dir)
      FileUtils.mkdir_p(app_dir)

      pkg_path = File.join(generated_dir, "budget.clear")
      File.write(pkg_path, <<~CLEAR)
        PUB FN pkgAnswer() RETURNS Int64 ->
          RETURN 41;
        END
      CLEAR

      File.write(File.join(app_dir, "helper.clear"), <<~CLEAR)
        REQUIRE "pkg:rtoc_627564676574" AS budget_module

        PUB FN wrapped() RETURNS Int64 ->
          RETURN pkgAnswer() + 1;
        END
      CLEAR

      main_src = File.join(app_dir, "main.clear")
      File.write(main_src, <<~CLEAR)
        REQUIRE "helper.clear";

        FN main() RETURNS Void ->
          print(wrapped().toString());
          RETURN;
        END
      CLEAR

      bin_path = File.join(dir, "test_bin")
      build_output, build_status = Open3.capture2e(
        CLEAR_BIN_REGISTERED_PKG, "build", main_src, "-o", bin_path, "--force",
        "--pkg", "rtoc_627564676574=#{pkg_path}"
      )
      expect(build_status.success?).to be(true), "build failed:\n#{build_output}"

      run_output, run_status = Open3.capture2e(bin_path)
      expect(run_status.success?).to be(true), "run failed:\n#{run_output}"
      expect(run_output).to include("42")
    end
  end

  it "resolves package-exported struct types used unqualified by importers" do
    Dir.mktmpdir do |dir|
      generated_dir = File.join(dir, "generated")
      app_dir = File.join(dir, "app")
      FileUtils.mkdir_p(generated_dir)
      FileUtils.mkdir_p(app_dir)

      pkg_path = File.join(generated_dir, "budget.clear")
      File.write(pkg_path, <<~CLEAR)
        PUB STRUCT Budget { limit: Int64 }

        PUB FN budgetNew(limit: Int64) RETURNS Budget ->
          RETURN Budget{ limit: limit };
        END
      CLEAR

      File.write(File.join(app_dir, "helper.clear"), <<~CLEAR)
        REQUIRE "pkg:rtoc_627564676574" AS budget_module

        PUB FN helperLimit(budget: Budget) RETURNS Int64 ->
          RETURN budget.limit;
        END
      CLEAR

      main_src = File.join(app_dir, "main.clear")
      File.write(main_src, <<~CLEAR)
        REQUIRE "helper.clear";
        REQUIRE "pkg:rtoc_627564676574" AS budget_module

        FN main() RETURNS Void ->
          b: Budget = budgetNew(42);
          print(helperLimit(b).toString());
          RETURN;
        END
      CLEAR

      bin_path = File.join(dir, "test_bin")
      build_output, build_status = Open3.capture2e(
        CLEAR_BIN_REGISTERED_PKG, "build", main_src, "-o", bin_path, "--force",
        "--pkg", "rtoc_627564676574=#{pkg_path}"
      )
      expect(build_status.success?).to be(true), "build failed:\n#{build_output}"

      run_output, run_status = Open3.capture2e(bin_path)
      expect(run_status.success?).to be(true), "run failed:\n#{run_output}"
      expect(run_output).to include("42")
    end
  end

  it "rejects a --pkg registration whose source file does not exist" do
    Dir.mktmpdir do |dir|
      main_src = File.join(dir, "main.clear")
      File.write(main_src, <<~CLEAR)
        FN main() RETURNS Void ->
          RETURN;
        END
      CLEAR

      output, status = Open3.capture2e(
        CLEAR_BIN_REGISTERED_PKG, "build", main_src, "--force",
        "--pkg", "rtoc_627564676574=#{File.join(dir, 'missing.clear')}"
      )
      expect(status.success?).to be(false)
      expect(output).to include("missing.clear")
    end
  end
end
