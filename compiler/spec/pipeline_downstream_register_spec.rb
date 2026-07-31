require "rspec"
require "open3"
require "tmpdir"

# Pipeline DOWNSTREAM register — spec/pipeline_downstream_register_spec.rb
#
# Companion to pipeline_position_matrix_spec.rb for the worst bug class it
# cannot see: programs the compiler ACCEPTS (transpile + MIR verification pass)
# that are then broken downstream — emitted Zig that does not compile, or
# binaries that segfault / invalid-free at runtime. Nothing else in the suite
# exercises these shapes; each cell here is one such accepted-but-broken
# program, found by the 2026-07 adjacent-surface probe.
#
# Every cell asserts its CURRENT broken outcome, strict in BOTH directions:
#   - if the cell's build/run starts SUCCEEDING, the spec fails with "remove
#     the cell from the register" (so a fix must delete the entry), and
#   - if it fails with a DIFFERENT signature, the spec fails (the bug moved).
#
# Tagged :integration — needs the ./clear CLI and the Zig toolchain
# (`bundle exec prspec spec/ --tag integration` lane).

RSpec.describe "Pipeline downstream register", :integration do
  ROOT = File.expand_path("../..", __dir__)

  # stage :build  — `./clear build` must FAIL with the expected Zig error.
  # stage :test   — `./clear test` must FAIL with the expected crash signature.
  # stage :transpile — transpiler must FAIL with the expected (wrong) message.
  # All five original cells (WINDOW owned-fn hoist, pipeline-in-lambda hoist,
  # BG STREAM in TEST THAT, BG in TEST THAT scheduler GPF, binding-chain
  # diagnostic) were fixed 2026-07-24. Positive coverage lives in
  # transpile-tests/660-663 and the intentional-diagnostic example below.
  CELLS = {}.freeze

  # Intentional-diagnostic coverage (formerly cell
  # binding_chain_materialize_wrong_diag): a materializing AS $v binding
  # chain must be rejected with the informative chain message, not the
  # misleading unresolved-binding error.
  it "rejects materializing AS $v binding chains with the intentional diagnostic" do
    src = <<~CLEAR
      STRUCT Order { tag: String, price: Float64 }
      STRUCT User { name: String, discount: Float64, orders: []Order }

      FN dup(s: String) RETURNS String -> RETURN COPY s; END

      FN main() RETURNS Void ->
          ao: Order[] = [Order{ tag: "x", price: 10.0 }, Order{ tag: "yy", price: 5.0 }];
          us: User[] = [User{ name: "alice", discount: 0.9, orders: ao }];
          tags = us AS $u
              |> UNNEST $u.orders AS $o
              |> SELECT dup($o.tag);
          MUTABLE n: Int64 = 0;
          tags |> EACH { n = n + _.length(); };
          ASSERT n == 3, "lens";
          RETURN;
      END
    CLEAR
    out = Dir.mktmpdir do |dir|
      file = File.join(dir, "cell.clear")
      File.write(file, src)
      cmd = ["ruby", File.join(ROOT, "compiler/ruby/backends/transpiler.rb"), "--default-stack", "Large", file]
      captured, _status = Open3.capture2e(*cmd, chdir: ROOT)
      captured
    end
    expect(out).to match(/Materializing terminals are not supported in AS \$v binding chains/)
    expect(out).not_to match(/Undefined pipeline binding/)
  end

  def run_cell(cell)
    Dir.mktmpdir do |dir|
      file = File.join(dir, "cell.clear")
      File.write(file, cell[:src])
      cmd = case cell[:stage]
            when :build     then [File.join(ROOT, "clear"), "build", file]
            when :test      then [File.join(ROOT, "clear"), "test", file]
            when :transpile then ["ruby", File.join(ROOT, "compiler/ruby/backends/transpiler.rb"),
                                  "--default-stack", "Large", file]
            end
      out, _status = Open3.capture2e(*cmd, chdir: ROOT)
      out
    end
  end

  CELLS.each do |id, cell|
    it "#{id} still fails with the registered signature" do
      out = run_cell(cell)
      passed = out =~ /All \d+ tests? passed|^Built: / && out !~ cell[:expect]
      expect(passed).to be_falsey,
        "cell now SUCCEEDS — the bug is fixed; remove '#{id}' from the register " \
        "and add the positive runtime/build coverage in its place"
      expect(out).to match(cell[:expect]),
        "cell failed with a DIFFERENT signature than registered.\n" \
        "Expected #{cell[:expect].inspect}\n--- output tail ---\n#{out.lines.last(15).join}"
    end
  end
end
