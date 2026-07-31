#!/usr/bin/env ruby
# frozen_string_literal: true

# Runs .github/workflows/ci.yml locally, the way GitHub would run it.
#
# The repository is private and Actions is no longer available, so the workflow
# has to be executable here or it is not executable at all. This reads the
# workflow rather than restating it: jobs, their `needs` order, their `if`
# conditions, their matrices and their steps all come from the YAML, so a job
# added to CI is a job this runs.
#
# What it deliberately does not reproduce is the runner image. Steps that only
# exist to provision one (`actions/checkout`, every `setup-*`) are no-ops here,
# because the toolchains are already installed; steps that talk to GitHub
# (SARIF upload, Codecov, Bencher, `github-script`) are no-ops because there is
# nothing to talk to. Artifacts are real: `upload-artifact` copies into
# `.ci-local/artifacts/<name>` and `download-artifact` copies back out, so a
# job that consumes another's binaries gets them.
#
# Each job is pinned to two CPUs, which is what a GitHub runner has. Jobs run
# in parallel up to --jobs, the way the queue would.
#
#   tools/ci_local.rb                  # every job, in dependency order
#   tools/ci_local.rb --job sorbet     # one job and what it needs
#   tools/ci_local.rb --list           # what would run
#   tools/ci_local.rb --jobs 4         # four at a time, 8 cores

require "yaml"
require "json"
require "fileutils"
require "optparse"
require "open3"
require "etc"

ROOT = File.expand_path("..", __dir__)
STATE = File.join(ROOT, ".ci-local")
ARTIFACTS = File.join(STATE, "artifacts")
LOGS = File.join(STATE, "logs")

# Actions that provision a runner or report to GitHub. Neither applies here.
INERT = %w[
  actions/checkout actions/setup-node actions/setup-python actions/setup-java
  actions/setup-go actions/cache ruby/setup-ruby mlugg/setup-zig
  dtolnay/rust-toolchain github/codeql-action/upload-sarif codecov/codecov-action
  bencherdev/bencher actions/github-script
].freeze

options = { jobs: 2, only: nil, list: false, keep_going: true, reclaim: true }
OptionParser.new do |parser|
  parser.on("--jobs N", Integer) { |v| options[:jobs] = v }
  parser.on("--job NAME") { |v| (options[:only] ||= []) << v }
  parser.on("--list") { options[:list] = true }
  parser.on("--stop-on-failure") { options[:keep_going] = false }
  parser.on("--keep-coverage-trees") { options[:reclaim] = false }
end.parse!

WORKFLOW = YAML.load_file(File.join(ROOT, ".github/workflows/ci.yml"), aliases: true)

# The event this run stands for. Every `if` in the workflow is written against
# a pull request from a branch of this repository, which is the case the gates
# are meant to cover.
CONTEXT = {
  "github" => {
    "event_name" => "pull_request",
    "repository" => "cuzzo/clear",
    "workspace" => ROOT,
    "sha" => `git -C #{ROOT} rev-parse HEAD`.strip,
    "ref" => "refs/pull/local/merge",
    "run_id" => "local",
    "run_attempt" => "1",
    "event" => {
      "pull_request" => {
        "base" => { "ref" => "master", "sha" => `git -C #{ROOT} rev-parse master 2>/dev/null`.strip },
        "head" => { "repo" => { "full_name" => "cuzzo/clear" }, "sha" => `git -C #{ROOT} rev-parse HEAD`.strip },
        "number" => "local",
      },
      "before" => "",
    },
  },
  "runner" => { "os" => "Linux", "temp" => File.join(STATE, "tmp"), "arch" => "X64" },
}.freeze

# ---------------------------------------------------------------- expressions

# `${{ ... }}` reduced to Ruby. Only the forms the workflow actually uses are
# translated; anything else raises rather than silently evaluating to nil,
# because a mis-read condition would skip a gate and report success.
def evaluate(expression, scope)
  source = expression.strip
  ruby = source.dup
  ruby = ruby.gsub(/\balways\(\)/, "true")
  ruby = ruby.gsub(/\bsuccess\(\)/, "true")
  ruby = ruby.gsub(/\bcancelled\(\)/, "false")
  ruby = ruby.gsub(/\bfailure\(\)/, "false")
  ruby = ruby.gsub(/\bhashFiles\([^)]*\)/, '"local"')
  ruby = ruby.gsub(/\bformat\(/, "__format(")
  ruby = ruby.gsub(/\bjoin\(/, "__join(")
  ruby = ruby.gsub(/\btoJSON\(/, "__to_json(")
  ruby = ruby.gsub(/\bfromJSON\(/, "__from_json(")
  ruby = ruby.gsub(/\bcontains\(/, "__contains(")
  ruby = ruby.gsub(/\bstartsWith\(/, "__starts_with(")
  ruby = ruby.gsub(/\bendsWith\(/, "__ends_with(")
  # Dotted paths become lookups. Longest-first so `a.b.c` is not read as `a.b`.
  ruby = ruby.gsub(/\b(github|needs|matrix|env|steps|runner|inputs|secrets|job|vars)((?:\.[A-Za-z_][A-Za-z0-9_-]*)+)/) do
    path = ([Regexp.last_match(1)] + Regexp.last_match(2).split(".").reject(&:empty?)).map { |part| part.inspect }.join(", ")
    "__lookup(#{path})"
  end
  ruby = ruby.gsub(/(?<![!<>=])=(?![=~])/, "==") if ruby.match?(/(?<![!<>=])=(?![=~])/)
  Evaluator.new(scope).instance_eval(ruby)
rescue SyntaxError, NameError, NoMethodError => error
  abort "ci_local: cannot evaluate #{source.inspect}: #{error.class}: #{error.message}"
end

class Evaluator
  def initialize(scope)
    @scope = scope
  end

  def __lookup(*path)
    path.reduce(@scope) do |node, key|
      break nil unless node.is_a?(Hash)

      node[key]
    end
  end

  def __format(template, *rest)
    rest.each_with_index.reduce(template) { |text, (value, index)| text.gsub("{#{index}}", value.to_s) }
  end

  def __join(value, separator = ",") = Array(value).join(separator)
  def __to_json(value) = JSON.generate(value)
  def __from_json(value) = JSON.parse(value)
  def __contains(haystack, needle) = haystack.to_s.include?(needle.to_s)
  def __starts_with(text, prefix) = text.to_s.start_with?(prefix.to_s)
  def __ends_with(text, suffix) = text.to_s.end_with?(suffix.to_s)
end

def expand(value, scope)
  case value
  when String
    # A whole-string expression keeps its type; an interpolated one is text.
    if (whole = value.match(/\A\$\{\{(.+)\}\}\z/m))
      evaluate(whole[1], scope)
    else
      value.gsub(/\$\{\{(.+?)\}\}/m) { evaluate(Regexp.last_match(1), scope).to_s }
    end
  when Hash then value.to_h { |key, inner| [key, expand(inner, scope)] }
  when Array then value.map { |inner| expand(inner, scope) }
  else value
  end
end

def truthy?(condition, scope)
  return true if condition.nil?

  result = condition.is_a?(String) ? expand("${{ #{condition.gsub(/\A\$\{\{(.*)\}\}\z/m, '\1')} }}", scope) : condition
  !!result && result != "false"
end

# ------------------------------------------------------------------- planning

def matrix_instances(job, scope)
  matrix = job.dig("strategy", "matrix")
  return [nil] unless matrix

  matrix = expand(matrix, scope)
  includes = matrix["include"] || []
  keys = matrix.keys - %w[include exclude]
  combinations =
    if keys.empty?
      []
    else
      keys.reduce([{}]) do |rows, key|
        rows.flat_map { |row| Array(matrix[key]).map { |value| row.merge(key => value) } }
      end
    end
  combinations += includes
  combinations.empty? ? [nil] : combinations
end

Instance = Struct.new(:id, :job_id, :job, :matrix, :label, keyword_init: true)

def plan(workflow, scope)
  instances = []
  workflow["jobs"].each do |job_id, job|
    matrix_instances(job, scope).each_with_index do |matrix, index|
      suffix = matrix ? " (#{matrix.map { |k, v| "#{k}=#{v}" }.join(', ')})" : ""
      instances << Instance.new(
        id: matrix ? "#{job_id}##{index}" : job_id,
        job_id: job_id,
        job: job,
        matrix: matrix,
        label: (job["name"] ? expand(job["name"], scope.merge("matrix" => matrix)).to_s : job_id) + suffix
      )
    end
  end
  instances
end

# ---------------------------------------------------------------------- steps

def artifact_dir(name) = File.join(ARTIFACTS, name.gsub(%r{[^\w.-]}, "_"))

def run_uses(step, scope, log)
  action = step["uses"].to_s.split("@").first
  with = expand(step["with"] || {}, scope)
  case action
  when "actions/upload-artifact"
    destination = artifact_dir(with["name"].to_s)
    FileUtils.rm_rf(destination)
    FileUtils.mkdir_p(destination)
    found = with["path"].to_s.lines.map(&:strip).reject(&:empty?).flat_map do |pattern|
      Dir.glob(File.expand_path(pattern, ROOT))
    end
    found.each do |path|
      relative = path.sub(%r{\A#{Regexp.escape(ROOT)}/}, "")
      target = File.join(destination, relative)
      FileUtils.mkdir_p(File.dirname(target))
      File.directory?(path) ? FileUtils.cp_r(path, target) : FileUtils.cp(path, target)
    end
    if found.empty? && with["if-no-files-found"].to_s == "error"
      log.puts("upload-artifact #{with['name']}: no files matched #{with['path'].inspect}")
      return false
    end
    log.puts("uploaded artifact #{with['name']} (#{found.length} paths)")
  when "actions/cache", "actions/cache/restore"
    # A cache hit is just "the path is already populated", which is what the
    # guarded install steps actually want to know.
    paths = with["path"].to_s.lines.map(&:strip).reject(&:empty?)
    hit = !paths.empty? && paths.all? do |pattern|
      Dir.glob(File.expand_path(pattern, ROOT)).any? { |p| File.directory?(p) ? Dir.children(p).any? : File.size?(p) }
    end
    log.puts("cache #{with['key']}: #{hit ? 'hit' : 'miss'}")
    return { "cache-hit" => hit.to_s }
  when "actions/download-artifact"
    source = artifact_dir(with["name"].to_s)
    unless File.directory?(source)
      log.puts("download-artifact #{with['name']}: not produced by an earlier job")
      return false
    end
    into = File.expand_path(with["path"] || ".", ROOT)
    FileUtils.mkdir_p(into)
    Dir.glob(File.join(source, "**", "*"), File::FNM_DOTMATCH).each do |path|
      next if File.directory?(path)

      relative = path.sub(%r{\A#{Regexp.escape(source)}/}, "")
      # Artifacts are stored under the path they were uploaded from; the
      # consumer asks for them flat, the way GitHub delivers them.
      target = File.join(into, File.basename(relative))
      FileUtils.mkdir_p(File.dirname(target))
      FileUtils.cp(path, target)
      FileUtils.chmod("+x", target) if File.executable?(path)
    end
    log.puts("downloaded artifact #{with['name']} into #{with['path']}")
  else
    unless INERT.any? { |inert| action == inert || action.start_with?("#{inert}/") }
      log.puts("!! unhandled action #{action}; treating as a no-op")
    end
  end
  true
end

# A step that only installs system packages. The runner image does not exist
# here -- the toolchains are already on this machine -- and running it would
# ask for a sudo password that no CI shell has either.
def provisioning?(script)
  lines = script.lines.map(&:strip).reject { |line| line.empty? || line.start_with?("#") }
  return false if lines.empty?

  lines.all? do |line|
    line.match?(/\A(sudo\s+)?(apt-get|apt|add-apt-repository)\b/) ||
      line.match?(/\A(sudo\s+)?(python -m pip|pip3?)\s+install\b/) ||
      line.match?(/\Anpm\s+(install|ci)\b/) ||
      line.match?(/\A(sudo\s+)?gem\s+install\b/) ||
      line.match?(/\Acargo\s+install\b/) ||
      line.match?(/\Arustup\s+component\s+add\b/)
  end
end

# A step that only reports to GitHub -- a commit status, a PR comment. There
# is no GitHub here to report to, and nothing about the code is being checked.
def reporting?(script)
  lines = script.lines.map(&:strip).reject { |line| line.empty? || line.start_with?("#") }
  return false if lines.empty?
  return false unless lines.any? { |line| line.start_with?("gh ") }

  # Assignments and shell control around the `gh` call are still reporting.
  lines.none? do |line|
    line.match?(/\A(bundle|cargo|zig|ruby|rake|go|npm|python|pytest|make|\.\/)/)
  end
end

def run_script(step, scope, env, cpus, log)
  script = expand(step["run"], scope)
  if reporting?(script)
    log.puts("--- GitHub reporting step skipped (no GitHub here):\n#{script}")
    return [true, {}, {}]
  end
  if provisioning?(script)
    log.puts("--- provisioning step skipped (toolchains are installed here):\n#{script}")
    return [true, {}, {}]
  end
  shell_env = env.merge(expand(step["env"] || {}, scope).transform_values(&:to_s))
  directory = step["working-directory"] ? File.expand_path(expand(step["working-directory"], scope), ROOT) : ROOT
  outputs = File.join(STATE, "tmp", "outputs-#{Process.pid}-#{rand(1 << 32)}")
  FileUtils.mkdir_p(File.dirname(outputs))
  File.write(outputs, "")
  shell_env["GITHUB_OUTPUT"] = outputs
  shell_env["GITHUB_ENV"] = "#{outputs}.env"
  shell_env["GITHUB_STEP_SUMMARY"] = "#{outputs}.summary"
  shell_env["GITHUB_PATH"] = "#{outputs}.path"
  File.write(shell_env["GITHUB_ENV"], "")
  File.write(shell_env["GITHUB_STEP_SUMMARY"], "")
  File.write(shell_env["GITHUB_PATH"], "")

  command = ["taskset", "-c", cpus, "bash", "-eo", "pipefail", "-c", script]
  log.puts("$ #{script.lines.map(&:rstrip).join("\n  ")}")
  log.flush
  ok = system(shell_env, *command, chdir: directory, out: log, err: log)

  produced = File.read(outputs).lines.filter_map do |line|
    key, value = line.chomp.split("=", 2)
    [key, value] if key && value
  end.to_h
  exported = File.read(shell_env["GITHUB_ENV"]).lines.filter_map do |line|
    key, value = line.chomp.split("=", 2)
    [key, value] if key && value
  end.to_h
  added_path = File.read(shell_env["GITHUB_PATH"]).lines.map(&:strip).reject(&:empty?)
  exported["PATH"] = (added_path + [env["PATH"]]).join(":") unless added_path.empty?
  [ok, produced, exported]
end

def run_instance(instance, scope, cpus)
  FileUtils.mkdir_p(LOGS)
  path = File.join(LOGS, "#{instance.id.gsub(/[^\w.#-]/, '_')}.log")
  log = File.open(path, "w")
  log.sync = true
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  ok = true
  step_scope = scope.dup
  begin
    env = ENV.to_h
      .merge(expand(WORKFLOW["env"] || {}, scope).transform_values(&:to_s))
      .merge(expand(instance.job["env"] || {}, scope).transform_values(&:to_s))
    # Two cores, which is what the hosted runner has, and what the build tools
    # would otherwise read from this machine's much larger core count.
    env["CARGO_BUILD_JOBS"] = "2"
    env["MAKEFLAGS"] = "-j2"
    env["RUST_TEST_THREADS"] = "2"
    env["PARALLEL_TEST_PROCESSORS"] = "2"
    # Tools the runner image ships that are built locally here.
    extra_path = ["#{Dir.home}/kcov/build/src", "#{Dir.home}/.local/bin", "#{Dir.home}/.cargo/bin"]
      .select { |dir| File.directory?(dir) }
    env["PATH"] = (extra_path + [env["PATH"]]).join(":")
    env["CI"] = "true"
    env["GITHUB_ACTIONS"] = "true"
    env["GITHUB_WORKSPACE"] = ROOT

    steps = instance.job["steps"] || []
    step_scope["steps"] = {}
    steps.each_with_index do |step, index|
      unless truthy?(step["if"], step_scope)
        log.puts("--- skipped step #{index}: #{step['name'] || step['uses'] || 'run'}")
        next
      end
      log.puts("--- step #{index}: #{step['name'] || step['uses'] || 'run'}")
      if step["uses"]
        result = run_uses(step, step_scope, log)
        succeeded = result != false
        step_scope["steps"][step["id"]] = { "outputs" => result } if step["id"] && result.is_a?(Hash)
      else
        succeeded, produced, exported = run_script(step, step_scope, env, cpus, log)
        step_scope["steps"][step["id"]] = { "outputs" => produced } if step["id"]
        env.merge!(exported) if exported
      end
      next if succeeded || step["continue-on-error"]

      ok = false
      log.puts("!!! step #{index} failed")
      break
    end
  rescue StandardError => error
    log.puts("!!! #{error.class}: #{error.message}")
    ok = false
  ensure
    log.close
  end
  [ok, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, path, step_scope]
end

# ------------------------------------------------------------------ scheduler

FileUtils.mkdir_p([STATE, ARTIFACTS, LOGS, File.join(STATE, "tmp")])

base_scope = CONTEXT.merge("needs" => {}, "env" => expand(WORKFLOW["env"] || {}, CONTEXT))
instances = plan(WORKFLOW, base_scope)
if options[:only]
  wanted = options[:only]
  keep = wanted.dup
  loop do
    additions = instances.select { |i| keep.include?(i.job_id) }
      .flat_map { |i| Array(i.job["needs"]) }.uniq - keep
    break if additions.empty?

    keep.concat(additions)
  end
  instances = instances.select { |i| keep.include?(i.job_id) }
end

if options[:list]
  instances.each { |i| puts format("%-42s needs=%s", i.id, Array(i.job["needs"]).join(",")) }
  exit 0
end

cores = Etc.nprocessors
slots = (0...options[:jobs]).map do |slot|
  first = (slot * 2) % cores
  "#{first},#{(first + 1) % cores}"
end

results = {}
pending = instances.dup
running = {}
puts "ci_local: #{instances.length} job instances, #{options[:jobs]} at a time, 2 cores each"

until pending.empty? && running.empty?
  while running.size < options[:jobs] && (ready = pending.find { |i|
    Array(i.job["needs"]).all? { |need| results.key?(need) }
  })
    pending.delete(ready)
    needs_scope = Array(ready.job["needs"]).to_h do |need|
      [need, { "result" => results[need][:ok] ? "success" : "failure", "outputs" => results[need][:outputs] }]
    end
    scope = base_scope.merge("needs" => needs_scope, "matrix" => ready.matrix)
    unless truthy?(ready.job["if"], scope)
      puts format("  %-46s SKIP (if)", ready.id)
      results[ready.job_id] = { ok: true, outputs: {}, skipped: true }
      next
    end
    slot = (0...options[:jobs]).find { |s| running.values.none? { |r| r[:slot] == s } }
    reader, writer = IO.pipe
    pid = fork do
      reader.close
      ok, seconds, path, final_scope = run_instance(ready, scope, slots[slot])
      # A job's outputs are read from the steps that produced them; the
      # `changes` job's decide what the rest of the run does.
      outputs = expand(ready.job["outputs"] || {}, final_scope)
      writer.write(JSON.generate("ok" => ok, "seconds" => seconds, "log" => path, "outputs" => outputs))
      writer.close
      exit!(0)
    end
    writer.close
    running[pid] = { instance: ready, slot: slot, reader: reader }
  end
  break if running.empty?

  pid = Process.wait
  finished = running.delete(pid)
  payload = JSON.parse(finished[:reader].read) rescue { "ok" => false, "seconds" => 0, "log" => "?", "outputs" => {} }
  finished[:reader].close
  results[finished[:instance].job_id] = {
    ok: payload["ok"],
    outputs: payload["outputs"] || {},
  }
  puts format("  %-46s %-4s %6.1fs  %s", finished[:instance].id,
              payload["ok"] ? "PASS" : "FAIL", payload["seconds"], payload["log"])
  if !payload["ok"] && !options[:keep_going]
    puts "stopping on first failure"
    break
  end
end

failed = results.reject { |_, r| r[:ok] }
puts
puts "ci_local: #{results.count { |_, r| r[:ok] }} passed, #{failed.size} failed"
failed.each_key { |id| puts "  FAIL #{id}" }
exit(failed.empty? ? 0 : 1)
