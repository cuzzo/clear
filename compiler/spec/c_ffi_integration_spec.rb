require "rspec"
require "open3"
require "tmpdir"

RSpec.describe "C ABI runtime fixture", :integration do
  ROOT = File.expand_path("../..", __dir__)
  FIXTURE = File.join(ROOT, "transpile-tests", "c-ffi-test")

  def zig
    candidates = [
      ENV["ZIG"],
      File.expand_path("~/zig-x86_64-linux-0.16.0/zig"),
      "zig",
    ].compact
    candidates.find { |candidate| candidate == "zig" || File.executable?(candidate) } || "zig"
  end

  it "compiles the C fixture and exercises it through CLEAR only" do
    Dir.mktmpdir("clear-c-ffi") do |native_dir|
      library = File.join(native_dir, "libclear_c_fixture.so")
      compile = [
        zig, "build-lib", "-dynamic", "-fPIC", "-lc", "--name", "clear_c_fixture",
        File.join(FIXTURE, "fixture.c"), "-I#{FIXTURE}", "-femit-bin=#{library}",
      ]
      compile_out, compile_status = Open3.capture2e(*compile, chdir: ROOT)
      expect(compile_status).to be_success, compile_out

      env = { "CLEAR_EXTRA_LINK_DIRS" => native_dir }
      output, status = Open3.capture2e(env, "./clear", "test", File.join(FIXTURE, "main.clear"), chdir: ROOT)
      expect(status).to be_success, output
      expect(output).to include("C FFI scalars, structs, arrays PASS")
      expect(output).to include("C FFI strings, out parameters, cleanup, errors PASS")
      expect(output).to include("C FFI synchronous callback PASS")
      expect(output).to include("C FFI pointer/count borrowed view PASS")

      import_output, import_status = Open3.capture2e(
        env, "./clear", "test", File.join(FIXTURE, "header_import.clear"), chdir: ROOT
      )
      expect(import_status).to be_success, import_output
      expect(import_output).to include("C header import PASS")
    end
  end
end
