# frozen_string_literal: true

# WIP shared helpers for the architecture-experiment tools (cycle_report,
# reach_through_report). Discovers production sources and runs fact-mine.

require "json"
require "open3"
require "set"

module CorpusCommon
  module_function

  EXCLUDE_DIRS = %w[
    test tests spec specs testing vendor node_modules examples example bench
    benchmark benchmarks dist build target third_party docs doc fixtures
    __pycache__ scripts tools ci .git generated samples sample demo
    zig-out .zig-cache coverage tmp transpile-tests zig-mutants
  ].to_set.freeze

  TEST_BASENAME = /\A(test_|.*[._-]tests?\.|.*[._]spec\.)/.freeze

  EXT_LANGUAGE = {
    ".rb" => "ruby", ".py" => "python", ".js" => "javascript", ".mjs" => "javascript",
    ".cjs" => "javascript", ".ts" => "typescript", ".go" => "go", ".c" => "c",
    ".cc" => "cpp", ".cpp" => "cpp", ".cxx" => "cpp", ".hpp" => "cpp", ".hh" => "cpp",
    ".cs" => "csharp", ".java" => "java", ".kt" => "kotlin", ".swift" => "swift",
    ".lua" => "lua", ".rs" => "rust", ".zig" => "zig", ".php" => "php"
  }.freeze

  def fact_mine_bin
    ENV.fetch("FACT_MINE_RUST_BINARY") do
      File.expand_path("../../fact-mine/target/release/fact-mine-rust", __dir__)
    end
  end

  def production_files(repo)
    files = Dir.chdir(repo) { Dir["**/*"] }.select do |path|
      next false unless File.file?(File.join(repo, path))
      next false if path.split("/")[0..-2].any? do |part|
        down = part.downcase
        EXCLUDE_DIRS.include?(down) || down.end_with?(".tests", ".test", "-tests", "_tests")
      end
      next false if path.end_with?(".d.ts", "_test.go", ".min.js")
      next false if File.basename(path).match?(TEST_BASENAME)
      EXT_LANGUAGE.key?(File.extname(path))
    end
    # .h is ambiguous: assign to the repo's dominant C-family language.
    c_family = files.count { |f| f.end_with?(".c") }
    cpp_family = files.count { |f| File.extname(f) =~ /\A\.(cc|cpp|cxx|hpp|hh)\z/ }
    headers = Dir.chdir(repo) { Dir["**/*.h"] }.reject do |path|
      path.split("/")[0..-2].any? { |part| EXCLUDE_DIRS.include?(part.downcase) }
    end
    files += headers if c_family.positive? || cpp_family.positive?
    files.sort
  end

  def run_fact_mine(mode, repo, files, extra_args: [])
    bin = fact_mine_bin
    raise "fact-mine binary missing: #{bin}" unless File.executable?(bin)

    merged = nil
    files.each_slice(120) do |slice|
      stdout, stderr, status = Open3.capture3(bin, mode, *extra_args, *slice, chdir: repo)
      raise "fact-mine #{mode} failed: #{stderr[0, 400]}" unless status.success?
      chunk = JSON.parse(stdout)
      if merged.nil?
        merged = chunk
      else
        chunk.each do |key, value|
          merged[key] = merged[key].is_a?(Array) && value.is_a?(Array) ? merged[key] + value : value
        end
      end
    end
    merged || {}
  end

  # syntax-facts requires an explicit --language; batch files per language.
  def run_syntax_facts(repo, files)
    documents = []
    files.group_by { |f| EXT_LANGUAGE[File.extname(f)] }.each do |language, batch|
      next unless language
      chunk = run_fact_mine("syntax-facts", repo, batch, extra_args: ["--language", language])
      documents.concat(chunk["documents"] || [])
    end
    { "documents" => documents }
  end

  # Tarjan strongly-connected components over adjacency Hash{node => Set[node]}.
  def strongly_connected_components(graph)
    index = {}
    low = {}
    on_stack = Set.new
    stack = []
    sccs = []
    counter = [0]

    visit = nil
    visit = lambda do |v|
      index[v] = low[v] = counter[0]
      counter[0] += 1
      stack << v
      on_stack << v
      (graph[v] || []).each do |w|
        if !index.key?(w)
          visit.call(w)
          low[v] = [low[v], low[w]].min
        elsif on_stack.include?(w)
          low[v] = [low[v], index[w]].min
        end
      end
      if low[v] == index[v]
        component = []
        loop do
          w = stack.pop
          on_stack.delete(w)
          component << w
          break if w == v
        end
        sccs << component
      end
    end

    graph.keys.each { |v| visit.call(v) unless index.key?(v) }
    sccs
  end
end

module CorpusCommon
  module_function

  # Corpus-resolved call edges (fact-mine.call-edges.v1).
  def run_call_edges(repo, files)
    bin = fact_mine_bin
    raise "fact-mine binary missing: #{bin}" unless File.executable?(bin)

    edges = []
    methods = []
    files.each_slice(200) do |slice|
      stdout, stderr, status = Open3.capture3(
        bin, "call-resolution", "--format=edges", *slice, chdir: repo
      )
      raise "fact-mine call-resolution failed: #{stderr[0, 400]}" unless status.success?
      chunk = JSON.parse(stdout)
      edges.concat(chunk["edges"] || [])
      methods.concat(chunk["methods"] || [])
    end
    { "edges" => edges, "methods" => methods }
  end

  def changed_files(repo, base, head)
    stdout, stderr, status = Open3.capture3(
      "git", "-C", repo, "diff", "--name-only", "#{base}...#{head || "HEAD"}"
    )
    raise "git diff failed: #{stderr[0, 200]}" unless status.success?
    stdout.lines.map(&:strip).reject(&:empty?)
  end

  def sarif_document(tool_name, rules, findings)
    {
      "$schema" => "https://raw.githubusercontent.com/oasis-tcs/sarif-spec/master/Schemata/sarif-schema-2.1.0.json",
      "version" => "2.1.0",
      "runs" => [
        {
          "tool" => {
            "driver" => {
              "name" => tool_name,
              "rules" => rules
            }
          },
          "results" => findings.map do |finding|
            {
              "ruleId" => finding[:rule_id],
              "level" => finding[:level] || "warning",
              "message" => { "text" => finding[:message] },
              "locations" => [
                {
                  "physicalLocation" => {
                    "artifactLocation" => { "uri" => finding[:path] },
                    "region" => { "startLine" => [finding[:line].to_i, 1].max }
                  }
                }
              ]
            }
          end
        }
      ]
    }
  end

  def write_sarif(path, tool_name, rules, findings)
    File.write(path, JSON.pretty_generate(sarif_document(tool_name, rules, findings)))
  end

  def parse_tool_options(argv)
    options = { repo: nil, sarif: nil, base: nil, head: nil }
    positional = []
    argv.each do |arg|
      case arg
      when /\A--sarif=(.+)/ then options[:sarif] = Regexp.last_match(1)
      when /\A--base=(.+)/ then options[:base] = Regexp.last_match(1)
      when /\A--head=(.+)/ then options[:head] = Regexp.last_match(1)
      when /\A--/ then raise "unknown option: #{arg}"
      else positional << arg
      end
    end
    options[:repo] = File.expand_path(positional.first || ".")
    options
  end

end
