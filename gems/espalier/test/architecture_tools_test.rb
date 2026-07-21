# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "json"
require "open3"
require "fileutils"

# End-to-end coverage for the architecture tools: cycle_report,
# reach_through_report (espalier/tools) and change_coupling (lineage/tools),
# including SARIF emission, changed-file scoping, and Lineage SARIF ingestion.
class ArchitectureToolsTest < Minitest::Test
  TOOLS = File.expand_path("../tools", __dir__)
  LINEAGE_TOOLS = File.expand_path("../../lineage/tools", __dir__)
  LINEAGE_BIN = File.expand_path("../../lineage/target/release/lineage", __dir__)
  FACT_MINE_BIN = File.expand_path("../../fact-mine/target/release/fact-mine-rust", __dir__)

  def setup
    unless File.executable?(FACT_MINE_BIN)
      flunk "fact-mine-rust binary missing at #{FACT_MINE_BIN}; build the workspace first"
    end
  end

  def run_tool(script, *argv)
    stdout, stderr, status = Open3.capture3("ruby", script, *argv)
    assert status.success?, "#{File.basename(script)} failed: #{stderr}\n#{stdout}"
    stdout
  end

  def with_repo
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        system("git init -q && git config user.email t@t && git config user.name t", exception: true)
        yield dir
      end
    end
  end

  def commit_all(message)
    system("git add -A && git commit -qm '#{message}'", exception: true)
  end

  def test_cycle_report_finds_file_and_directory_cycles_and_emits_sarif
    with_repo do |dir|
      FileUtils.mkdir_p(%w[lib/core lib/util])
      File.write("lib/core/engine.rb", "require_relative '../util/format'\nclass Engine; end\n")
      File.write("lib/util/format.rb", "require_relative '../core/engine'\nclass Format; end\n")
      File.write("lib/free.rb", "class Free; end\n")
      commit_all("init")

      sarif = File.join(dir, "cycles.sarif")
      out = run_tool(File.join(TOOLS, "cycle_report.rb"), dir, "--sarif=#{sarif}")

      assert_includes out, "file dependency cycle"
      assert_includes out, "lib/core/engine.rb"
      assert_includes out, "directory dependency cycle"

      doc = JSON.parse(File.read(sarif))
      results = doc.dig("runs", 0, "results")
      assert_equal results.size, results.count { |r| r["ruleId"] == "arch-dependency-cycle" }
      assert_operator results.size, :>=, 2
      assert(results.any? { |r| r.dig("message", "text").include?("lib/core/engine.rb <-> lib/util/format.rb") })
    end
  end

  def test_cycle_report_excludes_reexport_facades
    with_repo do |dir|
      FileUtils.mkdir_p("pkg")
      File.write("pkg/__init__.py", "from .a import go\nfrom .b import stop\n")
      File.write("pkg/a.py", "from . import b\n\ndef go():\n    return 1\n")
      File.write("pkg/b.py", "def stop():\n    return 2\n")
      commit_all("init")

      out = run_tool(File.join(TOOLS, "cycle_report.rb"), dir)
      refute_includes out, "file dependency cycle"
    end
  end

  # Real bug: changed-scope mode used to narrow the CORPUS (the files fed
  # into graph construction) to just the module trees the diff touched,
  # before any cycle detection ran. A cycle spanning an unchanged module
  # (moduleA -> moduleB -> moduleA, where only moduleA's file changed) was
  # therefore structurally invisible - moduleB's file, and its edge back
  # into moduleA, were never even part of the graph. The correct model:
  # always build the full-corpus graph; scope only which findings get
  # reported. This proves a cross-module cycle is still found even when the
  # diff between --base and HEAD only touches one side of it.
  def test_cycle_report_changed_scope_still_finds_cycles_spanning_unchanged_modules
    with_repo do |dir|
      FileUtils.mkdir_p(%w[moduleA moduleB])
      File.write("moduleA/a.rb", "require_relative '../moduleB/b'\nclass A; end\n")
      File.write("moduleB/b.rb", "require_relative '../moduleA/a'\nclass B; end\n")
      commit_all("init")
      File.write("moduleA/a.rb", "require_relative '../moduleB/b'\nclass A\n  VERSION = 2\nend\n")
      commit_all("touch moduleA only")

      out = run_tool(File.join(TOOLS, "cycle_report.rb"), dir, "--base=HEAD~1")

      assert_includes out, "file dependency cycle",
        "expected the moduleA <-> moduleB cycle to still be found even though " \
        "the diff only touched moduleA - the full corpus must always be graphed"
      assert(out.include?("moduleA/a.rb <-> moduleB/b.rb"))
    end
  end

  # Real bug: fact-mine emitted zero import facts for Go at all (a separate
  # gap, fixed alongside this one), and even once it did, cycle_report's
  # import resolver only knew Python/Java dotted-module and JS/Ruby/C
  # relative-path conventions - a Go import names a whole package
  # directory, rooted at the module name from go.mod (e.g.
  # "github.com/org/repo/pkgb"), not a single file relative to the repo
  # root. Neither gap alone nor together produced any cross-package Go
  # cycle finding.
  def test_cycle_report_resolves_go_module_rooted_package_imports
    with_repo do |dir|
      File.write("go.mod", "module github.com/demo/project\n\ngo 1.21\n")
      FileUtils.mkdir_p(%w[pkga pkgb])
      File.write("pkga/a.go", <<~GO)
        package pkga

        import "github.com/demo/project/pkgb"

        func UseB() int {
        \treturn pkgb.Value
        }
      GO
      File.write("pkgb/b.go", <<~GO)
        package pkgb

        import "github.com/demo/project/pkga"

        var Value = 1

        func UseA() {
        \tpkga.UseB()
        }
      GO
      commit_all("init")

      out = run_tool(File.join(TOOLS, "cycle_report.rb"), dir)

      assert_includes out, "file dependency cycle"
      assert_includes out, "pkga/a.go <-> pkgb/b.go"
      assert_includes out, "directory dependency cycle"
    end
  end

  def test_reach_through_report_flags_convention_privacy_and_send_bypass
    with_repo do |dir|
      FileUtils.mkdir_p("lib")
      File.write("lib/vault.rb", <<~RB)
        class Vault
          def open_door
            unlock
          end

          private

          def unlock
            @locked = false
          end
        end
      RB
      File.write("lib/thief.rb", <<~RB)
        class Thief
          def rob(vault)
            vault.send(:unlock)
            vault.send(dynamic_name)
          end
        end
      RB
      File.write("lib/store.py", <<~PY)
        class Store:
            def _rebalance(self):
                pass

        def poke(store):
            store._rebalance()
      PY
      commit_all("init")

      sarif = File.join(dir, "reach.sarif")
      out = run_tool(File.join(TOOLS, "reach_through_report.rb"), dir, "--sarif=#{sarif}")

      assert_includes out, "Thief -> Vault#unlock"
      assert_includes out, "Store#_rebalance"
      assert_includes out, "dynamic send sites: 1"

      doc = JSON.parse(File.read(sarif))
      results = doc.dig("runs", 0, "results")
      rule_ids = results.map { |r| r["ruleId"] }
      assert_includes rule_ids, "arch-privacy-bypass"
      assert_includes rule_ids, "arch-reach-through"
    end
  end

  # Real bug, same root cause as the cycle_report case above: narrowing the
  # corpus to changed modules before building the call graph drops the
  # callee's facts entirely whenever the reached-into module didn't itself
  # change. A caller reaching into another module's private API is exactly
  # as real a finding when only the caller's module changed - the callee
  # not changing is not a reason to miss it.
  def test_reach_through_report_changed_scope_still_finds_callee_in_unchanged_module
    with_repo do |dir|
      FileUtils.mkdir_p(%w[moduleA moduleB])
      File.write("moduleB/vault.rb", <<~RB)
        class Vault
          def open_door
            unlock
          end

          private

          def unlock
            @locked = false
          end
        end
      RB
      File.write("moduleA/thief.rb", <<~RB)
        class Thief
          def rob(vault)
            vault.send(:unlock)
          end
        end
      RB
      commit_all("init")
      File.write("moduleA/thief.rb", <<~RB)
        class Thief
          def rob(vault)
            vault.send(:unlock)
          end

          def loot; end
        end
      RB
      commit_all("touch moduleA only")

      out = run_tool(File.join(TOOLS, "reach_through_report.rb"), dir, "--base=HEAD~1")

      assert_includes out, "Thief -> Vault#unlock",
        "expected the reach-through into moduleB's private method to still be found " \
        "even though the diff only touched moduleA - the full corpus must always be graphed"
    end
  end

  def test_change_coupling_reports_cross_module_pairs_and_scopes_to_changes
    with_repo do |dir|
      FileUtils.mkdir_p(%w[core util docs])
      File.write("core/a.rb", "# a0\n")
      File.write("util/b.rb", "# b0\n")
      File.write("core/lonely.rb", "# lonely\n")
      commit_all("init")
      6.times do |i|
        File.write("core/a.rb", "# a#{i + 1}\n")
        File.write("util/b.rb", "# b#{i + 1}\n")
        commit_all("co-change #{i}")
      end
      File.write("core/lonely.rb", "# changed alone\n")
      commit_all("solo change")

      sarif = File.join(dir, "coupling.sarif")
      out = run_tool(File.join(LINEAGE_TOOLS, "change_coupling.rb"), dir, "5", "--sarif=#{sarif}")
      # 6 explicit co-changes plus the creating commit.
      assert_match(/s=7\s+c=1\.00\s+cross-module\s+core\/a\.rb <-> util\/b\.rb/, out)

      doc = JSON.parse(File.read(sarif))
      results = doc.dig("runs", 0, "results")
      assert_equal 1, results.size
      assert_equal "arch-change-coupling", results[0]["ruleId"]

      # Changed-scope: a diff touching only the uncoupled file reports nothing.
      out_scoped = run_tool(
        File.join(LINEAGE_TOOLS, "change_coupling.rb"), dir, "5", "--base=HEAD~1"
      )
      assert_includes out_scoped, "(none)"
    end
  end

  def test_sarif_outputs_ingest_into_lineage
    skip "lineage binary missing; build gems/lineage first" unless File.executable?(LINEAGE_BIN)

    with_repo do |dir|
      FileUtils.mkdir_p(%w[lib/core lib/util])
      File.write("lib/core/engine.rb", "require_relative '../util/format'\nclass Engine; end\n")
      File.write("lib/util/format.rb", "require_relative '../core/engine'\nclass Format; end\n")
      commit_all("init")
      commit_sha = `git rev-parse HEAD`.strip

      sarif = File.join(dir, "cycles.sarif")
      run_tool(File.join(TOOLS, "cycle_report.rb"), dir, "--sarif=#{sarif}")

      db = File.join(dir, "lineage.db")
      system(LINEAGE_BIN, "init", "--db", db, exception: true)
      system(
        LINEAGE_BIN, "ingest-sarif", "--db", db, "--repo=.", "--input", sarif,
        "--source", "espalier-architecture", "--commit", commit_sha, "--replace",
        exception: true
      )

      require "sqlite3"
      rows = SQLite3::Database.new(db).execute(
        "SELECT rule_id, path FROM sarif_findings ORDER BY rule_id, path"
      )
      assert_operator rows.size, :>=, 1
      assert(rows.all? { |rule_id, _| rule_id == "arch-dependency-cycle" })
      assert(rows.any? { |_, path| path == "lib/core/engine.rb" })
    end
  end
end
