# typed: false
require "rspec"
require "tmpdir"
require_relative "../ruby/compiler/package_source"

RSpec.describe PackageSource do
  def write(dir, name, content)
    path = File.join(dir, name)
    File.write(path, content)
    path
  end

  it "drops sibling requires and keeps the member bodies in order" do
    Dir.mktmpdir do |dir|
      a = write(dir, "a.clear", <<~CLEAR)
        REQUIRE "pkg:pkg_b" AS b
        PUB STRUCT A { n: Int64 }
      CLEAR
      b = write(dir, "b.clear", <<~CLEAR)
        REQUIRE "pkg:pkg_a" AS a
        PUB STRUCT B { a: A }
      CLEAR

      merged = described_class.merge([a, b], resolve_pkg: lambda { |name|
        { "pkg_a" => a, "pkg_b" => b }[name]
      })

      expect(merged.source).not_to include("REQUIRE")
      expect(merged.source.index("STRUCT A")).to be < merged.source.index("STRUCT B")
      expect(merged.source).to include("# FILE: #{a}")
      expect(merged.source).to include("# FILE: #{b}")
    end
  end

  it "hoists external requires once, deduplicated by path and alias" do
    Dir.mktmpdir do |dir|
      a = write(dir, "a.clear", <<~CLEAR)
        REQUIRE "pkg:regex" AS re
        PUB STRUCT A { n: Int64 }
      CLEAR
      b = write(dir, "b.clear", <<~CLEAR)
        REQUIRE "pkg:regex" AS re
        REQUIRE "pkg:regex" AS rx
        PUB STRUCT B { n: Int64 }
      CLEAR

      merged = described_class.merge([a, b], resolve_pkg: ->(_name) { nil })

      requires = merged.source.lines.select { |l| l.start_with?("REQUIRE") }
      expect(requires).to eq([
        %(REQUIRE "pkg:regex" AS re\n),
        %(REQUIRE "pkg:regex" AS rx\n),
      ])
      # Externals are hoisted above every member body.
      expect(merged.source.index("REQUIRE \"pkg:regex\" AS rx")).to be < merged.source.index("STRUCT A")
    end
  end

  it "re-anchors path-relative external requires to the member's directory" do
    Dir.mktmpdir do |dir|
      sub = File.join(dir, "sub")
      Dir.mkdir(sub)
      dep = write(sub, "dep.clear", "PUB STRUCT Dep { n: Int64 }\n")
      a = write(sub, "a.clear", <<~CLEAR)
        REQUIRE "dep.clear"
        PUB STRUCT A { d: Dep }
      CLEAR

      merged = described_class.merge([a], resolve_pkg: ->(_name) { nil })

      expect(merged.source).to include(%(REQUIRE "#{dep}"))
    end
  end

  it "drops exact-duplicate generated FN blocks and repeated EXTERN lines, keeping conflicting bodies" do
    Dir.mktmpdir do |dir|
      a = write(dir, "a.clear", <<~CLEAR)
        EXTERN FN compilerRegexCompile(pattern: String) RETURNS Int64;
        FN castAToB(v: Int64) RETURNS Int64 ->
          IF v > 0 THEN
            RETURN v;
          END
          RETURN v;
        END
        PUB STRUCT A { n: Int64 }
      CLEAR
      b = write(dir, "b.clear", <<~CLEAR)
        EXTERN FN compilerRegexCompile(pattern: String) RETURNS Int64;
        FN castAToB(v: Int64) RETURNS Int64 ->
          IF v > 0 THEN
            RETURN v;
          END
          RETURN v;
        END
        FN conflicting(v: Int64) RETURNS Int64 ->
          RETURN v;
        END
        PUB STRUCT B { n: Int64 }
      CLEAR
      c = write(dir, "c.clear", <<~CLEAR)
        FN conflicting(v: Int64) RETURNS Int64 ->
          RETURN (v + 1);
        END
        PUB STRUCT C { n: Int64 }
      CLEAR

      merged = described_class.merge([a, b, c], resolve_pkg: ->(_name) { nil })

      expect(merged.source.scan("EXTERN FN compilerRegexCompile").length).to eq(1)
      expect(merged.source.scan("FN castAToB").length).to eq(1)
      # Differing bodies under one name are both kept so the compiler
      # surfaces the conflict instead of silently picking one.
      expect(merged.source.scan("FN conflicting").length).to eq(2)
    end
  end

  it "recognizes siblings through comma-list package registrations" do
    Dir.mktmpdir do |dir|
      a = write(dir, "a.clear", <<~CLEAR)
        REQUIRE "pkg:whole" AS whole
        PUB STRUCT A { n: Int64 }
      CLEAR
      b = write(dir, "b.clear", "PUB STRUCT B { n: Int64 }\n")

      merged = described_class.merge([a, b], resolve_pkg: lambda { |name|
        name == "whole" ? "#{a},#{b}" : nil
      })

      expect(merged.source).not_to include("REQUIRE")
    end
  end
end
