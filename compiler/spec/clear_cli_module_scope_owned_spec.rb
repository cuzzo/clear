require "rspec"
require "tmpdir"
require "fileutils"
require "open3"

RSpec.describe "module-scope owned values", :integration do
  PROJECT_ROOT_MODULE_SCOPE = File.expand_path("../..", __dir__) unless defined?(PROJECT_ROOT_MODULE_SCOPE)
  CLEAR_BIN_MODULE_SCOPE = File.join(PROJECT_ROOT_MODULE_SCOPE, "clear") unless defined?(CLEAR_BIN_MODULE_SCOPE)

  it "rejects a cleanup-bearing top-level binding in a registered package module" do
    Dir.mktmpdir do |dir|
      lib_src = File.join(dir, "lib.clear")
      File.write(lib_src, <<~CLEAR)
        names: []String = ["alpha", "beta"];

        PUB FN count() RETURNS Int64 ->
            RETURN names.length();
        END
      CLEAR

      main_src = File.join(dir, "main.clear")
      File.write(main_src, <<~CLEAR)
        REQUIRE "pkg:rtoc_6d6f64676c6f62616c" AS modglobal

        FN main() RETURNS Void ->
            ASSERT count() == 2;
            RETURN;
        END
      CLEAR

      output, status = Open3.capture2e(
        CLEAR_BIN_MODULE_SCOPE, "build", main_src, "--force",
        "--pkg", "rtoc_6d6f64676c6f62616c=#{lib_src}"
      )
      expect(status.success?).to be(false)
      expect(output).to include("MODULE_SCOPE_OWNED_VALUE")
      expect(output).not_to include("MIR ownership verification failed")
    end
  end

  it "rejects a cleanup-bearing top-level binding in the root program" do
    Dir.mktmpdir do |dir|
      main_src = File.join(dir, "main.clear")
      File.write(main_src, <<~CLEAR)
        STRUCT Holder {
          label: ?String
        }

        PUB FN holder__new(label: ?String = NIL) RETURNS Holder ->
          RETURN Holder{ label: COPY label };
        END

        shared_default: Holder = holder__new(NIL);

        FN main() RETURNS Void ->
          print("{shared_default.label == NIL}");
        END
      CLEAR

      output, status = Open3.capture2e(
        CLEAR_BIN_MODULE_SCOPE, "build", main_src, "--force"
      )
      expect(status.success?).to be(false)
      expect(output).to include("MODULE_SCOPE_OWNED_VALUE")
      # The old failure mode: the owned-local recipe (defer/try/rt) emitted at
      # Zig container scope, surfacing as a Zig syntax error instead of a
      # source diagnostic.
      expect(output).not_to include("expected ',' after field")
    end
  end

  it "keeps comptime-safe module-scope constants legal" do
    Dir.mktmpdir do |dir|
      main_src = File.join(dir, "main.clear")
      File.write(main_src, <<~CLEAR)
        text_types: [2]String@symbol = [:STRING, :CHAR];

        FN main() RETURNS Void ->
            ASSERT text_types[0] == :STRING;
            ASSERT text_types[1] == :CHAR;
            RETURN;
        END
      CLEAR

      bin_path = File.join(dir, "bin")
      output, status = Open3.capture2e(
        CLEAR_BIN_MODULE_SCOPE, "build", main_src, "-o", bin_path, "--force"
      )
      expect(status.success?).to be(true), "build failed:\n#{output}"

      run_output, run_status = Open3.capture2e(bin_path)
      expect(run_status.success?).to be(true), "run failed:\n#{run_output}"
    end
  end
end
