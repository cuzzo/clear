# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "fileutils"
require "open3"
require "tmpdir"
require "yaml"
require "zlib"

class RubyStdlibMapTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  SUPPORT = File.join(
    ROOT,
    "fact-mine",
    "config",
    "stdlib_maps",
    "support.yml"
  )
  BRIDGE = File.join(
    ROOT,
    "fact-mine",
    "config",
    "stdlib_maps",
    "ruby",
    "build_symbol_bridge.rb"
  )
  ENVIRONMENT = File.join(
    ROOT,
    "fact-mine",
    "config",
    "stdlib_maps",
    "ruby",
    "semantic_environment.rb"
  )
  MANIFEST = File.join(ROOT, "fact-mine", "config", "stdlib_maps", "ruby-3.2.3.yml")

  def test_cruby_core_a_profiles_the_indexed_regexp_implementation_surface
    manifest = YAML.safe_load(File.read(MANIFEST))
    includes = manifest.fetch("source").fetch("include")

    assert_includes includes, "{array,dir,enum,error,file,hash,io,math,numeric,re,string}.c"
  end

  def test_cruby_registration_bridge_preserves_exact_aliases_and_rejects_unproven_bodies
    Dir.mktmpdir do |directory|
      File.write(File.join(directory, "math.c"), <<~C)
        rb_define_module_function(rb_mMath, "exp", math_exp, 1);
        rb_define_module_function(rb_mMath, "log", math_log, 1);
      C
      File.write(File.join(directory, "file.c"), <<~C)
        define_filetest_function("executable?", rb_file_executable_p, 1);
        rb_define_singleton_method(rb_cFile, "realpath", rb_file_s_realpath, -1);
      C
      producer = File.join(directory, "producer.json.gz")
      profile = File.join(directory, "profile.json")
      output = File.join(directory, "bridge.json")
      exact = "cxx . . $ math_exp(1)."
      executable = "cxx . . $ rb_file_executable_p(1)."
      realpath = "cxx . . $ rb_file_s_realpath(1)."
      Zlib::GzipWriter.open(producer) do |gzip|
        gzip.write(JSON.generate({
          "symbols" => {
            exact => { "bound_quality" => "upper_bound_exact_symbol" },
            executable => { "bound_quality" => "upper_bound_exact_symbol" },
            realpath => { "bound_quality" => "upper_bound_exact_symbol" },
            "cxx . . $ math_log(1)." => { "bound_quality" => "upper_bound_modeled_world" }
          }
        }))
      end
      File.write(profile, JSON.generate({
        "methods" => [
          { "path" => File.join(directory, "math.c"), "name" => "math_exp", "semantic_symbol" => exact },
          { "path" => File.join(directory, "math.c"), "name" => "math_log", "semantic_symbol" => "cxx . . $ math_log(1)." },
          { "path" => File.join(directory, "file.c"), "name" => "rb_file_executable_p", "semantic_symbol" => executable },
          { "path" => File.join(directory, "file.c"), "name" => "rb_file_s_realpath", "semantic_symbol" => realpath }
        ]
      }))

      stdout, stderr, status = Open3.capture3(
        "ruby", BRIDGE, producer, profile, directory, output, "3.2.3"
      )
      assert status.success?, "#{stdout}\n#{stderr}"
      symbols = JSON.parse(File.read(output)).fetch("symbols")
      assert_equal(
        [
          "nil-kill-runtime ruby ruby 3.2.3 Math#exp().",
          "nil-kill-runtime ruby ruby 3.2.3 Math.exp()."
        ],
        symbols.fetch(exact)
      )
      assert_equal(
        [
          "nil-kill-runtime ruby ruby 3.2.3 File.executable?().",
          "nil-kill-runtime ruby ruby 3.2.3 FileTest#executable?()."
        ],
        symbols.fetch(executable)
      )
      assert_equal ["nil-kill-runtime ruby ruby 3.2.3 File.realpath()."], symbols.fetch(realpath)
      refute symbols.key?("cxx . . $ math_log(1).")
    end
  end

  def test_cruby_environment_is_pinned_to_the_runtime_trace_version
    Dir.mktmpdir do |directory|
      FileUtils.mkdir_p(File.join(directory, "include", "ruby"))
      File.write(File.join(directory, "version.h"), "#define RUBY_VERSION_TEENY 3\n")
      File.write(File.join(directory, "include", "ruby", "version.h"), <<~C)
        #define RUBY_API_VERSION_MAJOR 3
        #define RUBY_API_VERSION_MINOR 2
      C
      output = File.join(directory, "environment.json")
      stdout, stderr, status = Open3.capture3("ruby", ENVIRONMENT, directory, output, "3.2.3")
      assert status.success?, "#{stdout}\n#{stderr}"
      assert_equal(
        {
          "runtime.language" => "ruby",
          "runtime.engine" => "ruby",
          "runtime.version" => "3.2.3",
          "runtime.engine_version" => "3.2.3"
        },
        JSON.parse(File.read(output)).fetch("claims")
      )

      _stdout, _stderr, mismatch = Open3.capture3("ruby", ENVIRONMENT, directory, output, "3.2.4")
      refute mismatch.success?
    end
  end
end
