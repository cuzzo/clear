require "rspec"
require "tmpdir"
require_relative "../ruby/backends/transpiler" unless defined?(ZigTranspiler)

# A cross-package call is qualified by the importing module's alias, stamped on
# the AST node. The pipeline placeholder rewriter rebuilds call nodes, and the
# metadata copy dropped that stamp -- so the same call emitted bare inside a
# pipeline body and qualified everywhere else.
RSpec.describe "cross-package calls inside a pipeline body" do
  it "keeps the module alias when the rewriter rebuilds the call" do
    Dir.mktmpdir do |dir|
      lib = File.join(dir, "lib.clear")
      File.write(lib, <<~CLEAR)
        PUB STRUCT Spec { name: String }

        PUB FN describe_value(self: Spec) RETURNS String ->
          RETURN COPY self.name;
        END
      CLEAR

      out = ZigTranspiler.new.transpile_as_module(<<~CLEAR, source_dir: dir, pkg_paths: { "helpers" => lib })
        REQUIRE "pkg:helpers";

        PUB STRUCT Holder { specs: []Spec }

        PUB FN names(self: Holder) RETURNS ![]String
          REQUIRES self: LOCAL
        ->
        WITH POLYMORPHIC self AS view {
          RETURN view.specs |> SELECT COPY describe_value(_);
        }
        END
      CLEAR

      expect(out).to match(/__clear_module_\w+\.describe_value\(/)
      expect(out).not_to match(/[^.\w]describe_value\(rt/)
    end
  end
end
