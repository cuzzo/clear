#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "open-uri"
require "open3"

SCIP_JAVA_VERSION = "0.12.3"
SCIP_JAVA_SHA256 = "2d4d8a31333dfa0daf3aa0381a51de465e40b0dac5622e49363786a65f743f34"
SCIP_KOTLIN_COMMIT = "2648c7dc04c2cc999cae9e3fd19863177a07492d"
PATCHED_PLUGIN_SHA256 = "4a141d34551466881b4cfdd5127718358ddd0917971e0254664b48e6bcf3a319"

source_root, output, workspace_root, patch = ARGV
abort "usage: index_stdlib.rb SOURCE_ROOT OUTPUT.scip WORKSPACE_ROOT PATCH" unless patch
source_root = File.expand_path(source_root)
output = File.expand_path(output)
cache = File.join(File.expand_path(workspace_root), ".cache", "stdlib-indexers", "kotlin-2.2.0")
FileUtils.mkdir_p(cache)

java_home = ENV["JAVA_HOME"]
abort "JAVA_HOME must identify JDK 21" unless java_home && File.executable?(File.join(java_home, "bin", "java"))

def capture!(*command, chdir:, env: {})
  stdout, stderr, status = Open3.capture3(env, *command, chdir: chdir)
  abort "#{command.join(' ')} failed:\n#{stderr}" unless status.success?
  stdout
end

java_stdout, java_stderr, java_status = Open3.capture3(
  File.join(java_home, "bin", "java"), "-version", chdir: source_root
)
abort "failed to inspect JAVA_HOME" unless java_status.success?
java_version = "#{java_stdout}\n#{java_stderr}"
abort "JDK 21 is required, got #{java_version.inspect}" unless java_version.include?("21.")

scip_java = ENV["SCIP_JAVA"]
if scip_java && File.executable?(scip_java)
  actual = Digest::SHA256.file(scip_java).hexdigest
  abort "scip-java digest mismatch: expected #{SCIP_JAVA_SHA256}, got #{actual}" unless actual == SCIP_JAVA_SHA256
else
  scip_java = File.join(cache, "scip-java-v#{SCIP_JAVA_VERSION}")
  unless File.file?(scip_java) && Digest::SHA256.file(scip_java).hexdigest == SCIP_JAVA_SHA256
    temporary = "#{scip_java}.download-#{Process.pid}"
    url = "https://github.com/scip-code/scip-java/releases/download/v#{SCIP_JAVA_VERSION}/scip-java-v#{SCIP_JAVA_VERSION}"
    URI.open(url) { |input| File.open(temporary, "wb") { |file| IO.copy_stream(input, file) } }
    actual = Digest::SHA256.file(temporary).hexdigest
    abort "scip-java digest mismatch: expected #{SCIP_JAVA_SHA256}, got #{actual}" unless actual == SCIP_JAVA_SHA256
    File.rename(temporary, scip_java)
    FileUtils.chmod(0o755, scip_java)
  end
end
version = capture!(scip_java, "--version", chdir: source_root, env: {"JAVA_HOME" => java_home}).strip
abort "scip-java #{SCIP_JAVA_VERSION} is required, got #{version.inspect}" unless version == SCIP_JAVA_VERSION

plugin = ENV["SEMANTICDB_KOTLINC"]
if plugin && File.file?(plugin)
  actual = Digest::SHA256.file(plugin).hexdigest
  unless actual == PATCHED_PLUGIN_SHA256
    abort "semanticdb-kotlinc digest mismatch: expected #{PATCHED_PLUGIN_SHA256}, got #{actual}"
  end
else
  checkout = File.join(cache, "scip-kotlin")
  unless File.directory?(File.join(checkout, ".git"))
    capture!("git", "clone", "--quiet", "https://github.com/sourcegraph/scip-kotlin.git", checkout, chdir: cache)
  end
  head = capture!("git", "rev-parse", "HEAD", chdir: checkout).strip
  unless head == SCIP_KOTLIN_COMMIT
    capture!("git", "fetch", "--quiet", "--depth", "1", "origin", SCIP_KOTLIN_COMMIT, chdir: checkout)
    capture!("git", "checkout", "--quiet", "--detach", "FETCH_HEAD", chdir: checkout)
  end
  _stdout, _stderr, applied = Open3.capture3("git", "apply", "--check", File.expand_path(patch), chdir: checkout)
  capture!("git", "apply", File.expand_path(patch), chdir: checkout) if applied.success?
  unless system("git", "apply", "--reverse", "--check", File.expand_path(patch), chdir: checkout,
                out: File::NULL, err: File::NULL)
    abort "the pinned scip-kotlin patch could not be applied cleanly"
  end
  capture!(
    File.join(checkout, "gradlew"), "--no-daemon", ":semanticdb-kotlinc:shadowJar",
    chdir: checkout,
    env: {"JAVA_HOME" => java_home}
  )
  plugin = Dir[File.join(checkout, "semanticdb-kotlinc/build/libs/semanticdb-kotlinc-*.jar")]
    .reject { |path| path.end_with?("-slim.jar") }
    .max
  abort "patched semanticdb-kotlinc jar was not produced" unless plugin
end
actual_plugin = Digest::SHA256.file(plugin).hexdigest
unless actual_plugin == PATCHED_PLUGIN_SHA256
  abort "patched semanticdb-kotlinc is not reproducible: expected #{PATCHED_PLUGIN_SHA256}, got #{actual_plugin}"
end

marker = JSON.parse(File.read(File.join(source_root, ".fact-mine-source.json")))
binary = marker.fetch("binary")
semanticdb = File.join(source_root, ".fact-mine", "semanticdb")
FileUtils.rm_rf(semanticdb)
FileUtils.mkdir_p(semanticdb)
settings = File.join(source_root, "settings.gradle")
build = File.join(source_root, "build.gradle")
properties = File.join(source_root, "gradle.properties")
File.write(settings, <<~GRADLE)
  pluginManagement {
      repositories {
          gradlePluginPortal()
          mavenCentral()
      }
  }
  rootProject.name = "fact-mine-kotlin-stdlib"
GRADLE
File.write(build, <<~GRADLE)
  plugins {
      id "org.jetbrains.kotlin.multiplatform" version "2.2.0"
  }
  repositories { mavenCentral() }
  dependencies {
      commonMainImplementation files("#{binary}")
  }
  kotlin {
      jvm()
      targets.configureEach {
          compilations.configureEach {
              compileTaskProvider.configure {
                  compilerOptions {
                      freeCompilerArgs.addAll(
                          "-Xallow-kotlin-package",
                          "-opt-in=kotlin.contracts.ExperimentalContracts",
                          "-Xfriend-paths=#{binary}",
                          "-Xplugin=#{plugin}",
                          "-P", "plugin:semanticdb-kotlinc:sourceroot=#{source_root}",
                          "-P", "plugin:semanticdb-kotlinc:targetroot=#{semanticdb}"
                      )
                  }
              }
          }
      }
      sourceSets {
          commonMain.kotlin.srcDirs("commonMain/generated", "commonMain/kotlin/collections")
          commonMain.kotlin.exclude(
              "**/AbstractMutableCollection.kt", "**/AbstractMutableList.kt",
              "**/AbstractMutableMap.kt", "**/AbstractMutableSet.kt", "**/ArrayList.kt",
              "**/Collections.kt", "**/CollectionsH.kt", "**/HashMap.kt", "**/HashSet.kt",
              "**/LinkedHashMap.kt", "**/LinkedHashSet.kt", "**/Maps.kt", "**/Sets.kt"
          )
          jvmMain.kotlin.srcDir("jvmMain/generated")
      }
  }
GRADLE
File.write(properties, "kotlin.stdlib.default.dependency=false\n")

gradle = ENV["GRADLE"]
gradle ||= File.join(cache, "scip-kotlin", "gradlew")
capture!(gradle, "--no-daemon", "clean", "compileKotlinJvm", chdir: source_root,
         env: {"JAVA_HOME" => java_home})
FileUtils.mkdir_p(File.dirname(output))
capture!(scip_java, "index-semanticdb", semanticdb, "--output", output,
         chdir: source_root, env: {"JAVA_HOME" => java_home})
abort "scip-java did not produce #{output}" unless File.size?(output)
