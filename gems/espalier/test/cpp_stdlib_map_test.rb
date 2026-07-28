# frozen_string_literal: true

require "json"
require "digest"
require "fileutils"
require "minitest/autorun"
require "open3"
require "tmpdir"
require "zlib"

class CppStdlibMapTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  CPP = File.join(ROOT, "fact-mine", "config", "stdlib_maps", "cpp")

  def test_revision_digest_is_path_stable
    Dir.mktmpdir do |directory|
      first = File.join(directory, "first", "include")
      second = File.join(directory, "second", "include")
      [first, second].each do |root|
        FileUtils.mkdir_p(File.join(root, "bits"))
        File.write(File.join(root, "vector"), "vector body")
        File.write(File.join(root, "bits", "config.h"), "config")
      end

      compute = lambda do |root|
        digest = Digest::SHA256.new
        Dir.glob(File.join(root, "**/*"), File::FNM_DOTMATCH)
          .select { |path| File.file?(path) }
          .sort
          .each do |path|
            relative = path.delete_prefix("#{root}#{File::SEPARATOR}")
            digest << relative << "\0" << Digest::SHA256.file(path).hexdigest << "\n"
          end
        digest.hexdigest
      end
      assert_equal compute.call(first), compute.call(second)
    end
  end

  def test_environment_is_entirely_language_owned_and_exact
    source = File.read(File.join(CPP, "semantic_environment.rb"))
    assert_includes source, "cpp.stdlib.effective_headers.sha256"
    assert_includes source, "cpp.preprocessor_macros.sha256"
    assert_includes source, "cpp.compiler.target"
    assert_includes source, "cpp.scip_clang.sha256"
  end

  def test_symbol_bridge_only_admits_exact_std_rows
    Dir.mktmpdir do |directory|
      summary = File.join(directory, "summary.json.gz")
      output = File.join(directory, "bridge.json")
      payload = {
        "symbols" => {
          "cxx . . $ std/vector#size()." => {
            "bound_quality" => "upper_bound_exact_symbol"
          },
          "cxx . . $ std/get()." => {
            "bound_quality" => "upper_bound_parametric_reflective_once"
          },
          "cxx . . $ __gnu_cxx/helper()." => {
            "bound_quality" => "upper_bound_exact_symbol"
          }
        }
      }
      Zlib::GzipWriter.open(summary) { |gzip| gzip.write(JSON.generate(payload)) }

      stdout, stderr, status = Open3.capture3(
        "ruby",
        File.join(CPP, "build_symbol_bridge.rb"),
        summary,
        output
      )
      assert status.success?, "#{stdout}\n#{stderr}"
      assert_equal(
        {
          "cxx . . $ std/vector#size()." =>
            "cxx . . $ std/vector#size()."
        },
        JSON.parse(File.read(output)).fetch("symbols")
      )
    end
  end
end
