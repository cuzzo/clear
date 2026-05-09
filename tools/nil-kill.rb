#!/usr/bin/env ruby
# typed: false
# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "pathname"
require "set"
require "shellwords"
require "time"

begin
  require "prism"
rescue LoadError
  warn "error: prism is required; run `bundle install`"
  exit 2
end

module NilKill
  ROOT = File.expand_path("..", __dir__)
  TMP_DIR = File.join(ROOT, "tmp", "nil-kill")
  RUNTIME_DIR = File.join(TMP_DIR, "runtime")
  EVIDENCE_PATH = File.join(TMP_DIR, "evidence.json")
  REPORT_PATH = File.join(TMP_DIR, "report.md")

  HIGH = "high"
  REVIEW = "review"
  GAP = "gap"

  module_function

  def rel(path)
    Pathname.new(path).relative_path_from(Pathname.new(ROOT)).to_s
  rescue StandardError
    path.to_s
  end

  def target_dirs
    ENV.fetch("NIL_KILL_TARGETS", "src").split(File::PATH_SEPARATOR).map { |path| File.expand_path(path, ROOT) }
  end

  def target_files
    target_dirs.flat_map { |dir| File.directory?(dir) ? Dir.glob(File.join(dir, "**", "*.rb")) : [dir] }.select { |p| File.file?(p) }.sort
  end

  def target_path?(path)
    abs = File.expand_path(path, ROOT)
    target_dirs.any? { |dir| abs == dir || abs.start_with?(dir + File::SEPARATOR) }
  end

  def sorbet_type(classes, allow_nilable: true)
    classes = Array(classes).compact.reject(&:empty?)
    return "T.untyped" if classes.empty?
    has_nil = classes.include?("NilClass")
    others = classes.reject { |c| c == "NilClass" || c.include?("#") || c.start_with?("Sorbet::Private::") }
    return "T.untyped" if others.empty?
    base =
      if others.all? { |c| c == "TrueClass" || c == "FalseClass" }
        "T::Boolean"
      elsif others.size == 1
        others.first
      elsif ENV.fetch("NIL_KILL_UNION_POLICY", "untyped") == "any" && others.size <= 4
        "T.any(#{others.sort.join(", ")})"
      else
        "T.untyped"
      end
    return "T.untyped" if base == "T.untyped"
    has_nil && allow_nilable ? "T.nilable(#{base})" : base
  end

  def useful_type?(type)
    type && type != "T.untyped" && type != "NilClass"
  end

  def confidence(calls)
    calls.to_i >= ENV.fetch("NIL_KILL_MIN_CALLS", "20").to_i ? HIGH : REVIEW
  end

  def display_union(classes, allow_nilable: true)
    classes = Array(classes).compact.reject(&:empty?)
    has_nil = classes.include?("NilClass")
    others = classes.reject { |c| c == "NilClass" || c.include?("#") || c.start_with?("Sorbet::Private::") }
    base = others.size == 1 ? others.first : "T.any(#{others.sort.join(", ")})"
    has_nil && allow_nilable ? "T.nilable(#{base})" : base
  end

  class CLI
    def initialize(argv)
      @argv = argv.dup
    end

    def run
      command = @argv.shift
      case command
      when "collect" then collect
      when "infer" then Infer.new(@argv).run
      when "apply" then Apply.new(@argv).run
      when "review" then InteractiveReview.new(@argv).run
      when "loop" then Loop.new(@argv).run
      when "report" then Report.new.run
      when "doctor" then Doctor.new.run
      when "help", nil then help
      else
        warn "unknown command: #{command}"
        help
        exit 2
      end
    end

    def collect
      commands = collect_commands
      abort "usage: tools/nil-kill.rb collect [--commands FILE] [--continue-on-error] -- <command...>" if commands.empty?
      tracer = File.join(ROOT, "tools", "nil-kill", "runtime_trace.rb")
      rubyopt = (ENV["RUBYOPT"].to_s.split + ["-r#{tracer}"]).join(" ")
      env = ENV.to_h.merge("NIL_KILL_TRACE" => "1", "RUBYOPT" => rubyopt)
      continue = @argv.delete("--continue-on-error")
      commands.each_with_index do |cmd, i|
        puts "[#{i + 1}/#{commands.size}] NIL_KILL_TRACE=1 RUBYOPT=#{rubyopt.shellescape} #{cmd.shelljoin}"
        ok = system(env, *cmd)
        next if ok || continue
        exit($?&.exitstatus || 1)
      end
    end

    def collect_commands
      commands = []
      while (idx = @argv.index("--commands"))
        file = @argv[idx + 1] || abort("--commands requires a file")
        @argv.slice!(idx, 2)
        commands.concat(read_command_file(file))
      end
      while (idx = @argv.index("--cmd"))
        command = @argv[idx + 1] || abort("--cmd requires a command string")
        @argv.slice!(idx, 2)
        commands << Shellwords.split(command)
      end
      while (idx = @argv.index("--glob"))
        pattern = @argv[idx + 1] || abort("--glob requires a pattern")
        template_idx = @argv.index("--template") || abort("--glob requires --template")
        template = @argv[template_idx + 1] || abort("--template requires a command template")
        [idx, template_idx].sort.reverse_each { |remove_idx| @argv.slice!(remove_idx, 2) }
        Dir.glob(pattern).sort.each do |file|
          commands << Shellwords.split(template.gsub("{file}", file))
        end
      end
      sep = @argv.index("--")
      commands << @argv[(sep + 1)..] if sep
      commands
    end

    def read_command_file(path)
      File.readlines(path, chomp: true).filter_map do |line|
        stripped = line.strip
        next if stripped.empty? || stripped.start_with?("#")
        Shellwords.split(stripped)
      end
    end

    def help
      puts <<~TEXT
        Usage:
          bundle exec ruby tools/nil-kill.rb collect -- <command...>
          bundle exec ruby tools/nil-kill.rb collect --commands runtime-commands.txt
          bundle exec ruby tools/nil-kill.rb collect --cmd "bundle exec rspec" --cmd "./clear test transpile-tests"
          bundle exec ruby tools/nil-kill.rb collect --glob "lib/**/*.rb" --template "ruby {file}"
          bundle exec ruby tools/nil-kill.rb infer [--no-sorbet]
          bundle exec ruby tools/nil-kill.rb apply [--dry-run] [--all]
          bundle exec ruby tools/nil-kill.rb review [--kind replace_nil_with_default]
          bundle exec ruby tools/nil-kill.rb loop [--defaults] -- <verify command...>
          bundle exec ruby tools/nil-kill.rb report
          bundle exec ruby tools/nil-kill.rb doctor

        Config:
          NIL_KILL_TARGETS=src[:other_dir]   target Ruby source roots
          NIL_KILL_MIN_CALLS=20              runtime confidence threshold
          NIL_KILL_UNION_POLICY=untyped|any  default: untyped
          NIL_KILL_AUTO_DEFAULTS=1           promote safe nil default rewrites into loop/apply
          NIL_KILL_PRESSURE_SORT=priority|slots|hotness
          NIL_KILL_ELEMENT_SAMPLE=20          container elements sampled by runtime tracing
      TEXT
    end
  end

  class Store
    attr_reader :methods, :tlets, :facts, :diagnostics, :actions

    def initialize
      @methods = {}
      @tlets = {}
      @facts = { "files" => {}, "unsigned_methods" => [], "existing_sigs" => [], "tlet_sites" => [], "dead_nil_checks" => [],
                 "struct_declarations" => [], "struct_field_static" => [], "tuple_arrays" => [], "hash_shapes" => [] }
      @diagnostics = { "sorbet_errors" => [], "nil_origins" => [] }
      @actions = []
    end

    def method_record(key)
      @methods[key.join("\0")] ||= {
        "key" => key, "calls" => 0, "ok_calls" => 0, "raised_calls" => 0,
        "params_by_name" => {}, "params_ok" => {}, "params_raised" => {}, "param_elem" => {}, "param_kv" => {},
        "param_sites" => {}, "param_sites_ok" => {}, "param_sites_raised" => {},
        "returns" => [], "return_elem" => [], "return_kv" => [[], []], "raised" => [],
        "source" => nil, "has_sig" => false,
      }
    end

    def to_h
      { "version" => 1, "generated_at" => Time.now.utc.iso8601, "target_dirs" => NilKill.target_dirs.map { |d| NilKill.rel(d) },
        "methods" => @methods.values, "tlets" => @tlets.values, "facts" => @facts,
        "diagnostics" => @diagnostics, "actions" => @actions }
    end

    def write
      FileUtils.mkdir_p(TMP_DIR)
      File.write(EVIDENCE_PATH, JSON.pretty_generate(to_h))
    end

    def self.read
      abort "missing #{NilKill.rel(EVIDENCE_PATH)}; run `tools/nil-kill.rb infer` first" unless File.exist?(EVIDENCE_PATH)
      JSON.parse(File.read(EVIDENCE_PATH))
    end
  end

  class Infer
    def initialize(argv)
      @run_sorbet = !argv.include?("--no-sorbet")
      @store = Store.new
    end

    def run
      load_runtime
      index_sources
      load_sorbet if @run_sorbet
      build_actions
      @store.write
      Report.new.run
    end

    def load_runtime
      Dir.glob(File.join(RUNTIME_DIR, "methods-*.jsonl")).each do |file|
        File.foreach(file) do |line|
          obs = JSON.parse(line)
          next unless NilKill.target_path?(obs["path"])
          key = [obs["class"], obs["method"], obs["kind"], obs["path"], obs["line"]]
          rec = @store.method_record(key)
          rec["calls"] += obs["calls"].to_i
          rec["ok_calls"] += obs["ok_calls"].to_i
          rec["raised_calls"] += obs["raised_calls"].to_i
          %w[returns return_elem raised].each { |k| rec[k] = (rec[k] + Array(obs[k])).uniq.sort }
          merge_hash_sets(rec["params_by_name"], obs["params_by_name"])
          merge_hash_sets(rec["params_ok"], obs["params_ok"])
          merge_hash_sets(rec["params_raised"], obs["params_raised"])
          merge_hash_counts(rec["param_sites"], obs["param_sites"])
          merge_hash_counts(rec["param_sites_ok"], obs["param_sites_ok"])
          merge_hash_counts(rec["param_sites_raised"], obs["param_sites_raised"])
          merge_hash_sets(rec["param_elem"], obs["param_elem"])
          merge_hash_kv(rec["param_kv"], obs["param_kv"])
          merge_kv(rec["return_kv"], obs["return_kv"])
        end
      end
      Dir.glob(File.join(RUNTIME_DIR, "tlets-*.jsonl")).each do |file|
        File.foreach(file) do |line|
          obs = JSON.parse(line)
          next unless NilKill.target_path?(obs["path"])
          key = "#{obs["path"]}:#{obs["line"]}"
          rec = (@store.tlets[key] ||= { "path" => obs["path"], "line" => obs["line"], "calls" => 0, "classes" => [] })
          rec["calls"] += obs["calls"].to_i
          rec["classes"] = (rec["classes"] + Array(obs["classes"])).uniq.sort
        end
      end
      Dir.glob(File.join(RUNTIME_DIR, "structs-*.jsonl")).each do |file|
        File.foreach(file) do |line|
          obs = JSON.parse(line)
          next unless NilKill.target_path?(obs["path"])
          @store.facts["struct_field_runtime"] ||= []
          @store.facts["struct_field_runtime"] << obs
        end
      end
    end

    def index_sources
      NilKill.target_files.each do |path|
        idx = SourceIndex.new(path)
        @store.facts["files"][NilKill.rel(path)] = idx.summary
        @store.facts["unsigned_methods"].concat(idx.methods.reject { |m| m["has_sig"] })
        @store.facts["existing_sigs"].concat(idx.methods.select { |m| m["has_sig"] })
        @store.facts["tlet_sites"].concat(idx.tlet_sites)
        @store.facts["dead_nil_checks"].concat(idx.dead_nil_checks)
        @store.facts["struct_declarations"].concat(idx.struct_declarations)
        @store.facts["struct_field_static"].concat(idx.struct_field_static)
        @store.facts["tuple_arrays"].concat(idx.tuple_arrays)
        @store.facts["hash_shapes"].concat(idx.hash_shapes)
        idx.methods.each do |method|
          rec = @store.method_record([method["class"], method["method"], method["kind"], File.expand_path(method["path"], ROOT), method["line"]])
          rec["source"] = method
          rec["has_sig"] = method["has_sig"]
        end
      end
    end

    def load_sorbet
      _out, err, _status = Open3.capture3({ "SRB_YES" => "1", "NO_COLOR" => "1" }, "bundle", "exec", "srb", "tc")
      @store.diagnostics["sorbet_errors"] = parse_sorbet_errors(err)
      @store.diagnostics["nil_origins"] = parse_nil_origins(err)
    rescue Errno::ENOENT
      @store.diagnostics["sorbet_errors"] = []
    end

    def build_actions
      @store.methods.each_value do |rec|
        src = rec["source"]
        next unless src
        report_bad_input_candidates(rec, src)
        report_nil_param_candidates(rec, src)
        report_union_candidates(rec, src)
        rec["has_sig"] ? validate_sig(rec, src) : propose_sig(rec, src)
      end
      @store.facts["tlet_sites"].each { |site| propose_tlet_action(site) }
      @store.facts["dead_nil_checks"].each do |finding|
        if finding["kind"] == "nil_check"
          @store.actions << base_action("replace_dead_nil_check", HIGH, finding["path"], finding["line"], finding["reason"],
            { "code" => finding["code"] })
        else
          @store.actions << base_action("remove_dead_safe_nav", HIGH, finding["path"], finding["line"], finding["reason"],
            { "code" => finding["code"] })
        end
      end
      @store.diagnostics["sorbet_errors"].each do |diag|
        kind = %w[7002 7003 7005 7007].include?(diag["code"]) ? "annotation_conflict" : "sorbet_warning"
        conf = kind == "annotation_conflict" ? REVIEW : GAP
        @store.actions << base_action(kind, conf, diag["path"], diag["line"],
          "Sorbet #{diag["code"]}: #{diag["message"]}", { "code" => diag["code"] })
      end
    end

    def propose_sig(rec, src)
      sig = sig_for(rec, src)
      conf = sig.include?("T.untyped") || rec["calls"].to_i.zero? ? REVIEW : NilKill.confidence(rec["calls"])
      if src["uses_yield"] && conf == HIGH
        conf = REVIEW
      end
      message = src["uses_yield"] ? "add missing sig; method uses implicit yield, block typing needs review" : "add missing sig"
      @store.actions << base_action("add_sig", conf, src["path"], src["line"], message, { "sig" => sig, "scope" => src["scope"] })
    end

    def validate_sig(rec, src)
      sig = src["sig"].to_s
      params_for_typing(rec).each do |name, classes|
        observed = NilKill.sorbet_type(classes)
        next unless NilKill.useful_type?(observed)
        next unless sig.match?(/\b#{Regexp.escape(name)}:\s*T\.untyped\b/)
        @store.actions << base_action("fix_sig_param", NilKill.confidence(rec["calls"]), src["path"], src["line"],
          "existing sig param #{name} is T.untyped; observed #{observed}", { "name" => name, "type" => observed })
      end
      observed_return = NilKill.sorbet_type(rec["returns"])
      if NilKill.useful_type?(observed_return) && sig.include?("returns(T.untyped)")
        @store.actions << base_action("fix_sig_return", NilKill.confidence(rec["calls"]), src["path"], src["line"],
          "existing sig return is T.untyped; observed #{observed_return}", { "type" => observed_return })
      end
    end

    def propose_tlet_action(site)
      abs = File.expand_path(site["path"], ROOT)
      obs = @store.tlets["#{abs}:#{site["line"]}"]
      if site["tlet"] && site["type"] == "T.untyped" && obs
        type = NilKill.sorbet_type(obs["classes"])
        return unless NilKill.useful_type?(type)
        @store.actions << base_action("narrow_tlet", NilKill.confidence(obs["calls"]), site["path"], site["line"],
          "narrow existing T.let to #{type}", { "type" => type })
      elsif !site["tlet"] && site["candidate_type"]
        @store.actions << base_action("add_tlet", HIGH, site["path"], site["line"],
          "add T.let for #{site["name"]}", { "name" => site["name"], "type" => site["candidate_type"] })
      end
    end

    def sig_for(rec, src)
      params = src["params"].map do |param|
        type = NilKill.sorbet_type(params_for_typing(rec)[param["name"]] || [])
        type = "T.untyped" unless NilKill.useful_type?(type)
        type = "T.nilable(#{type})" if param["nil_default"] && !type.start_with?("T.nilable(") && type != "T.untyped"
        "#{param["name"]}: #{type}"
      end
      ret = src["method"] == "initialize" && src["kind"] == "instance" ? nil : NilKill.sorbet_type(rec["returns"])
      ret = "T.untyped" unless ret.nil? || NilKill.useful_type?(ret)
      clause = ret.nil? ? "void" : "returns(#{ret})"
      params.empty? ? "sig { #{clause} }" : "sig { params(#{params.join(", ")}).#{clause} }"
    end

    def params_for_typing(rec)
      rec["params_ok"].empty? ? rec["params_by_name"] : rec["params_ok"]
    end

    def report_bad_input_candidates(rec, src)
      return if rec["params_ok"].empty? || rec["params_raised"].empty?
      rec["params_by_name"].each do |name, all_classes|
        ok_classes = Array(rec["params_ok"][name])
        raised_classes = Array(rec["params_raised"][name])
        next if ok_classes.empty? || raised_classes.empty?
        extra = all_classes - ok_classes
        next if extra.empty?
        broad = NilKill.display_union(all_classes)
        narrow = NilKill.sorbet_type(ok_classes)
        next unless broad.include?("T.any(") && NilKill.useful_type?(narrow)
        @store.actions << base_action("bad_input_type_candidate", REVIEW, src["path"], src["line"],
          "param #{name} would become #{broad} only because raised calls saw #{extra.sort.join(", ")}; normal calls suggest #{narrow}",
          { "name" => name, "broad_type" => broad, "candidate_type" => narrow, "raised_only_classes" => extra.sort,
            "callsites" => filtered_sites(rec["param_sites_raised"][name], extra) })
      end
    end

    def report_nil_param_candidates(rec, src)
      params_for_typing(rec).each do |name, classes|
        next unless Array(classes).include?("NilClass")
        non_nil = Array(classes) - ["NilClass"]
        candidate = NilKill.sorbet_type(non_nil)
        @store.actions << base_action("nil_param_observed", REVIEW, src["path"], src["line"],
          "param #{name} observed nil; source should be traced before adding T.nilable#{NilKill.useful_type?(candidate) ? " (non-nil candidate: #{candidate})" : ""}",
          { "name" => name, "candidate_type" => candidate, "callsites" => filtered_sites(param_sites_for_typing(rec)[name], ["NilClass"]) })
        propose_nil_default_actions(rec, src, name, candidate)
      end
    end

    def propose_nil_default_actions(rec, src, name, candidate)
      default = default_for_type(candidate)
      return unless default
      filtered_sites(param_sites_for_typing(rec)[name], ["NilClass"]).each do |site, count|
        root = site.sub(/:[^:]+\z/, "")
        path, line = split_site(root)
        next unless path && line && NilKill.target_path?(path)
        rel_path = NilKill.rel(path)
        next unless callsite_default_rewrite_safe?(rel_path, line)
        conf = ENV["NIL_KILL_AUTO_DEFAULTS"] == "1" ? HIGH : REVIEW
        @store.actions << base_action("replace_nil_with_default", conf, rel_path, line,
          "replace nil with #{default} for #{src["class"]}##{src["method"]} param #{name} (#{count} observed call(s))",
          { "default" => default, "name" => name, "candidate_type" => candidate, "observed_calls" => count.to_i,
            "target_path" => src["path"], "target_line" => src["line"], "target_method" => "#{src["class"]}##{src["method"]}" })
      end
    end

    def default_for_type(type)
      case type
      when "Array", /\AT::Array\b/ then "[]"
      when "Hash", /\AT::Hash\b/ then "{}"
      when "String" then "\"\""
      else nil
      end
    end

    def split_site(site)
      match = site.match(/\A(.+):(\d+)\z/)
      match ? [match[1], match[2].to_i] : [nil, nil]
    end

    def callsite_default_rewrite_safe?(rel_path, line)
      source = File.readlines(File.join(ROOT, rel_path))[line - 1]
      return false unless source
      source.scan(/\bnil\b/).size == 1
    rescue Errno::ENOENT
      false
    end

    def report_union_candidates(rec, src)
      params_for_typing(rec).each do |name, classes|
        others = Array(classes).reject { |c| c == "NilClass" }
        next unless others.uniq.size > 1
        @store.actions << base_action("union_observed", REVIEW, src["path"], src["line"],
          "param #{name} observed #{others.uniq.sort.join(", ")}; leaving as T.untyped by default until more evidence or design intent is clear",
          { "name" => name, "classes" => others.uniq.sort, "callsites" => filtered_sites(param_sites_for_typing(rec)[name], others.uniq) })
      end
    end

    def param_sites_for_typing(rec)
      rec["param_sites_ok"].empty? ? rec["param_sites"] : rec["param_sites_ok"]
    end

    def filtered_sites(sites, classes)
      wanted = Array(classes).to_set
      (sites || {}).select { |site, _count| wanted.include?(site_class(site)) }
    end

    def site_class(site)
      site.to_s.split(":").last
    end

    def base_action(kind, conf, path, line, message, data)
      { "kind" => kind, "confidence" => conf, "path" => path, "line" => line, "message" => message, "data" => data }
    end

    def merge_hash_sets(target, source)
      (source || {}).each { |name, vals| target[name] = (Array(target[name]) + Array(vals)).uniq.sort }
    end

    def merge_hash_kv(target, source)
      (source || {}).each { |name, kv| merge_kv((target[name] ||= [[], []]), kv) }
    end

    def merge_hash_counts(target, source)
      (source || {}).each do |name, sites|
        bucket = (target[name] ||= {})
        (sites || {}).each { |site, count| bucket[site] = bucket.fetch(site, 0) + count.to_i }
      end
    end

    def merge_kv(target, source)
      return unless source
      target[0] = (Array(target[0]) + Array(source[0])).uniq.sort
      target[1] = (Array(target[1]) + Array(source[1])).uniq.sort
    end

    def parse_sorbet_errors(output)
      output.lines.filter_map do |line|
        next unless line =~ /^(.*?\.rb):(\d+):\s+(.*?)\s+https:\/\/srb\.help\/(\d+)/
        { "path" => $1, "line" => $2.to_i, "message" => $3, "code" => $4 }
      end
    end

    def parse_nil_origins(output)
      origins = Hash.new(0)
      current = false
      output.gsub(/\e\[[0-9;]*m/, "").each_line do |line|
        if line =~ /^(.*?\.rb):(\d+):.*does not exist on/
          current = true
        elsif current && line =~ /^\s+(.*?\.rb):(\d+):/
          origins["#{$1}:#{$2}"] += 1
          current = false
        end
      end
      origins.sort_by { |_, count| -count }.map { |origin, count| { "origin" => origin, "count" => count } }
    end
  end

  class SourceIndex
    attr_reader :methods, :tlet_sites, :dead_nil_checks, :struct_declarations, :struct_field_static, :tuple_arrays, :hash_shapes

    def initialize(path)
      @path = path
      @rel = NilKill.rel(path)
      @lines = File.readlines(path)
      @methods = []
      @tlet_sites = []
      @dead_nil_checks = []
      @struct_declarations = []
      @struct_field_static = []
      @tuple_arrays = []
      @hash_shapes = []
      @struct_fields_by_name = {}
      @struct_full_by_name = {}
      @non_nil_locals = Set.new
      @non_nil_method_returns = Set.new
      parsed = Prism.parse_file(path)
      if parsed.success?
        collect_struct_declarations(parsed.value, [])
        collect_non_nil_method_returns(parsed.value)
        walk(parsed.value, [])
      end
    end

    def summary
      { "methods" => @methods.size, "unsigned_methods" => @methods.count { |m| !m["has_sig"] },
        "tlet_sites" => @tlet_sites.count { |s| s["tlet"] }, "candidate_tlet_sites" => @tlet_sites.count { |s| !s["tlet"] },
        "dead_nil_checks" => @dead_nil_checks.size, "structs" => @struct_declarations.size,
        "tuple_arrays" => @tuple_arrays.size, "hash_shapes" => @hash_shapes.size }
    end

    def walk(node, scope)
      case node
      when Prism::ClassNode, Prism::ModuleNode
        child_walk(node.body, scope + [node.constant_path.slice])
      when Prism::DefNode
        record = method_record(node, scope)
        @methods << record
        scoped_facts(record) { child_walk(node.body, scope) }
      when Prism::CallNode
        inspect_call(node)
        inspect_struct_constructor(node)
        child_walk(node, scope)
      when Prism::ArrayNode
        inspect_array_literal(node)
        child_walk(node, scope)
      when Prism::HashNode
        inspect_hash_literal(node)
        child_walk(node, scope)
      when Prism::LocalVariableWriteNode
        update_local_fact(node)
        child_walk(node, scope)
      when Prism::InstanceVariableWriteNode, Prism::ClassVariableWriteNode, Prism::GlobalVariableWriteNode
        inspect_variable_write(node)
        child_walk(node, scope)
      else
        child_walk(node, scope)
      end
    end

    def child_walk(node, scope)
      return unless node&.respond_to?(:child_nodes)
      node.child_nodes.compact.each { |child| walk(child, scope) }
    end

    def collect_struct_declarations(node, scope)
      case node
      when Prism::ClassNode, Prism::ModuleNode
        child_scope = scope + [const_name(node.constant_path)]
        node.child_nodes.compact.each { |child| collect_struct_declarations(child, child_scope) } if node.respond_to?(:child_nodes)
        return
      when Prism::ConstantWriteNode
        if struct_new_call?(node.value)
          klass = (scope + [node.name.to_s]).join("::")
          fields = struct_fields(node.value)
          if fields.any?
            rec = { "path" => @rel, "line" => node.location.start_line, "class" => klass, "fields" => fields }
            @struct_declarations << rec
            @struct_fields_by_name[klass] = fields
            @struct_full_by_name[klass] = klass
            short = klass.split("::").last
            unless @struct_fields_by_name.key?(short)
              @struct_fields_by_name[short] = fields
              @struct_full_by_name[short] = klass
            end
          end
        end
      end
      node.child_nodes.compact.each { |child| collect_struct_declarations(child, scope) } if node.respond_to?(:child_nodes)
    end

    def struct_new_call?(node)
      node.is_a?(Prism::CallNode) &&
        node.name == :new &&
        node.receiver.is_a?(Prism::ConstantReadNode) &&
        node.receiver.name == :Struct
    end

    def struct_fields(node)
      (node.arguments&.arguments || []).filter_map do |arg|
        arg.value.to_s if arg.is_a?(Prism::SymbolNode)
      end
    end

    def const_name(node)
      return "" unless node
      node.respond_to?(:full_name) ? (node.full_name rescue node.slice) : node.slice
    end

    def inspect_struct_constructor(node)
      return unless node.name == :new && node.receiver
      klass = const_name(node.receiver)
      fields = @struct_fields_by_name[klass] || @struct_fields_by_name[klass.split("::").last]
      full_class = @struct_full_by_name[klass] || @struct_full_by_name[klass.split("::").last] || klass
      return unless fields
      args = node.arguments&.arguments || []
      args.each_with_index do |arg, idx|
        next if idx >= fields.size || arg.is_a?(Prism::KeywordHashNode)
        @struct_field_static << { "path" => @rel, "line" => node.location.start_line, "class" => full_class,
          "field" => fields[idx], "type" => expression_type(arg), "expression" => arg.slice }
      end
    end

    def inspect_array_literal(node)
      elements = node.elements || []
      return if elements.size < 2 || elements.any? { |elem| elem.is_a?(Prism::SplatNode) }
      types = elements.map { |elem| expression_type(elem) }
      known = types.compact
      return if known.size != elements.size || known.uniq.size < 2
      @tuple_arrays << { "path" => @rel, "line" => node.location.start_line, "size" => elements.size,
        "types" => types, "confidence" => tuple_confidence(types), "code" => node.slice }
    end

    def inspect_hash_literal(node)
      elements = node.elements || []
      return if elements.empty?
      keys = []
      values = []
      elements.each do |assoc|
        next unless assoc.respond_to?(:key) && assoc.respond_to?(:value)
        key = hash_key_name(assoc.key)
        next unless key
        keys << key
        values << expression_type(assoc.value)
      end
      return if keys.size < 2 || keys.size != elements.size
      @hash_shapes << { "path" => @rel, "line" => node.location.start_line, "keys" => keys,
        "value_types" => values, "code" => node.slice }
    end

    def hash_key_name(node)
      case node
      when Prism::SymbolNode
        node.respond_to?(:value) ? node.value.to_s : node.slice.delete_prefix(":")
      when Prism::StringNode
        node.respond_to?(:unescaped) ? node.unescaped : node.slice.delete_prefix("\"").delete_prefix("'").delete_suffix("\"").delete_suffix("'")
      else
        nil
      end
    end

    def tuple_confidence(types)
      constants = types.grep(/\A[A-Z]\w*(?:::[A-Z]\w*)*/)
      namespaces = constants.filter_map { |type| type.include?("::") ? type.split("::").first : nil }.uniq
      return "review" if namespaces.size == 1 && constants.size == types.size
      types.uniq.size == types.size ? "high" : "review"
    end

    def collect_non_nil_method_returns(node)
      if node.is_a?(Prism::DefNode)
        sig = sig_above(node.location.start_line)
        @non_nil_method_returns << node.name.to_s if sig && non_nil_return_sig?(sig)
      end
      node.child_nodes.compact.each { |child| collect_non_nil_method_returns(child) } if node.respond_to?(:child_nodes)
    end

    def non_nil_return_sig?(sig)
      match = sig.match(/\.returns\((.+?)\)/)
      return false unless match
      type = match[1]
      !type.include?("T.nilable") && type != "T.untyped" && type != "NilClass"
    end

    def scoped_facts(method_record)
      old = @non_nil_locals
      @non_nil_locals = Set.new(method_record["non_nil_params"])
      yield
    ensure
      @non_nil_locals = old
    end

    def method_record(node, scope)
      sig = sig_above(node.location.start_line)
      { "path" => @rel, "line" => node.location.start_line, "class" => scope.join("::"),
        "method" => node.name.to_s, "kind" => node.receiver.is_a?(Prism::SelfNode) ? "class" : "instance",
        "has_sig" => !sig.nil?, "sig" => sig, "params" => params(node), "scope" => scope,
        "non_nil_params" => non_nil_sig_params(sig), "uses_yield" => uses_yield?(node.body) }
    end

    def sig_above(line)
      (line - 2).downto([line - 6, 0].max) { |idx| return @lines[idx].strip if @lines[idx]&.match?(/\bsig\s*\{/) }
      nil
    end

    def params(node)
      p = node.parameters
      return [] unless p
      nodes = p.requireds + p.optionals + p.keywords
      nodes.filter_map { |n| n.respond_to?(:name) && n.name ? { "name" => n.name.to_s, "nil_default" => nil_default?(n) } : nil }
    end

    def non_nil_sig_params(sig)
      return [] unless sig
      params_match = sig.match(/params\((.*)\)\./)
      return [] unless params_match
      params_match[1].scan(/\b([a-zA-Z_]\w*):\s*([^,)]+)/).filter_map do |name, type|
        next if type.include?("T.nilable") || type == "T.untyped" || type == "NilClass"
        name
      end
    end

    def nil_default?(node)
      node.respond_to?(:value) && node.value.is_a?(Prism::NilNode)
    end

    def uses_yield?(node)
      return false unless node&.respond_to?(:child_nodes)
      return true if node.is_a?(Prism::YieldNode)
      node.child_nodes.compact.any? { |child| uses_yield?(child) }
    end

    def inspect_call(node)
      if node.name == :let && node.receiver&.slice == "T"
        args = node.arguments&.arguments || []
        @tlet_sites << { "path" => @rel, "line" => node.location.start_line, "tlet" => true, "type" => args[1]&.slice }
      elsif node.safe_navigation? && provably_non_nil?(node.receiver)
        @dead_nil_checks << { "path" => @rel, "line" => node.location.start_line, "kind" => "safe_nav",
          "code" => node.slice, "reason" => "#{node.receiver.slice} is provably non-nil" }
      elsif node.name == :nil? && node.receiver && provably_non_nil?(node.receiver)
        @dead_nil_checks << { "path" => @rel, "line" => node.location.start_line, "kind" => "nil_check",
          "code" => node.slice, "reason" => "#{node.receiver.slice} is provably non-nil; .nil? is always false" }
      end
    end

    def provably_non_nil?(node)
      case node
      when Prism::LocalVariableReadNode
        @non_nil_locals.include?(node.name.to_s)
      when Prism::CallNode
        !node.safe_navigation? && @non_nil_method_returns.include?(node.name.to_s)
      when Prism::SelfNode
        true
      else
        !!non_nil_literal?(node)
      end
    end

    def update_local_fact(node)
      name = node.name.to_s
      non_nil_literal?(node.value) ? @non_nil_locals.add(name) : @non_nil_locals.delete(name)
    end

    def inspect_variable_write(node)
      return if node.value.is_a?(Prism::CallNode) && node.value.name == :let && node.value.receiver&.slice == "T"
      type = literal_type(node.value)
      return unless type
      @tlet_sites << { "path" => @rel, "line" => node.location.start_line, "tlet" => false, "name" => node.name.to_s, "candidate_type" => type }
    end

    def expression_type(node)
      return nil unless node
      if node.is_a?(Prism::CallNode) && node.name == :let && node.receiver&.slice == "T"
        return node.arguments&.arguments&.[](1)&.slice
      end
      if node.is_a?(Prism::CallNode) && node.name == :must && node.receiver&.slice == "T"
        return expression_type(node.arguments&.arguments&.first)
      end
      literal_type(node)
    end

    def non_nil_literal?(node)
      literal_type(node) || node.is_a?(Prism::TrueNode) || node.is_a?(Prism::FalseNode)
    end

    def literal_type(node)
      case node
      when Prism::StringNode then "String"
      when Prism::SymbolNode then "Symbol"
      when Prism::IntegerNode then "Integer"
      when Prism::FloatNode then "Float"
      when Prism::TrueNode, Prism::FalseNode then "T::Boolean"
      when Prism::ArrayNode then "T::Array[T.untyped]"
      when Prism::HashNode then "T::Hash[T.untyped, T.untyped]"
      else
        node.is_a?(Prism::CallNode) && node.name == :new && node.receiver ? node.receiver.slice : nil
      end
    end
  end

  class Apply
    def initialize(argv)
      @dry_run = argv.include?("--dry-run") || ENV["DRY_RUN"] == "1"
      @all = argv.include?("--all")
      @evidence = Store.read
    end

    def run
      actions = @evidence["actions"].select { |a| @all || a["confidence"] == HIGH }
      apply_actions(actions)
    end

    def apply_actions(actions)
      changed = 0
      actions.group_by { |a| a["path"] }.each do |rel_path, list|
        path = File.join(ROOT, rel_path)
        next unless File.exist?(path)
        lines = File.readlines(path)
        list.sort_by { |a| -a["line"].to_i }.each { |action| changed += 1 if apply_one(lines, action) }
        ensure_sorbet_runtime(lines) if list.any? { |a| %w[add_sig add_tlet narrow_tlet].include?(a["kind"]) }
        ensure_sig_extensions(lines, rel_path, list.select { |a| a["kind"] == "add_sig" })
        File.write(path, lines.join) unless @dry_run
      end
      puts "#{@dry_run ? "would apply" : "applied"} #{changed} action(s)"
      changed
    end

    def apply_one(lines, action)
      idx = action["line"].to_i - 1
      return false if idx.negative? || idx >= lines.length
      case action["kind"]
      when "add_sig"
        return false if find_sig_idx(lines, idx)
        lines.insert(idx, "#{lines[idx][/^\s*/]}#{action["data"]["sig"]}\n")
      when "fix_sig_param"
        sig_idx = find_sig_idx(lines, idx)
        return false unless sig_idx
        name = Regexp.escape(action["data"]["name"])
        lines[sig_idx] = lines[sig_idx].sub(/\b#{name}:\s*T\.untyped\b/, "#{action["data"]["name"]}: #{action["data"]["type"]}")
      when "fix_sig_return"
        sig_idx = find_sig_idx(lines, idx)
        return false unless sig_idx
        lines[sig_idx] = lines[sig_idx].sub(/\.returns\(T\.untyped\)/, ".returns(#{action["data"]["type"]})")
      when "narrow_tlet"
        lines[idx] = lines[idx].sub(/T\.let\((.*),\s*T\.untyped\)/, "T.let(\\1, #{action["data"]["type"]})")
      when "add_tlet"
        name = Regexp.escape(action["data"]["name"])
        lines[idx] = lines[idx].sub(/(#{name}\s*=\s*)(.+?)(\s*(?:#.*)?\n)\z/, "\\1T.let(\\2, #{action["data"]["type"]})\\3")
      when "remove_dead_safe_nav"
        code = action.dig("data", "code")
        if code && lines[idx].include?(code)
          lines[idx] = lines[idx].sub(code, code.gsub("&.", "."))
        else
          lines[idx] = lines[idx].gsub("&.", ".")
        end
      when "replace_dead_nil_check"
        code = action.dig("data", "code")
        return false unless code && lines[idx].include?(code)
        lines[idx] = lines[idx].sub(code, "false")
      when "replace_nil_with_default"
        return false unless lines[idx].scan(/\bnil\b/).size == 1
        lines[idx] = lines[idx].sub(/\bnil\b/, action.dig("data", "default").to_s)
      else
        return false
      end
      true
    end

    def ensure_sorbet_runtime(lines)
      return if lines.any? { |line| line.match?(/require ["']sorbet-runtime["']/) }
      insert_at = 0
      lines.each_with_index do |line, idx|
        if line.start_with?("#") || line.strip.empty?
          insert_at = idx + 1
        else
          break
        end
      end
      lines.insert(insert_at, "require \"sorbet-runtime\"\n", "\n")
    end

    def ensure_sig_extensions(lines, rel_path, sig_actions)
      scopes = sig_actions.filter_map { |action| action.dig("data", "scope") }.uniq
      return if scopes.empty?
      parsed = Prism.parse(lines.join)
      return unless parsed.success?
      insertions = []
      scopes.each do |scope|
        next if scope.empty?
        node = find_scope_node(parsed.value, scope)
        next unless node
        body_range = node.location.start_line..node.location.end_line
        next if body_range.any? { |line_no| lines[line_no - 1]&.match?(/\bextend\s+T::Sig\b/) }
        indent = lines[node.location.start_line - 1][/^\s*/] + "  "
        insertions << [node.location.start_line, "#{indent}extend T::Sig\n", "\n"]
      end
      insertions.sort_by { |line_no, _text, _blank| line_no }.reverse_each do |line_no, *text|
        lines.insert(line_no, *text)
      end
    rescue StandardError => e
      warn "#{rel_path}: could not ensure extend T::Sig: #{e.message}"
    end

    def find_scope_node(root, scope)
      found = nil
      walk = lambda do |node, stack|
        return if found
        case node
        when Prism::ClassNode, Prism::ModuleNode
          new_stack = stack + [node.constant_path.slice]
          found = node if new_stack == scope
          node.child_nodes.compact.each { |child| walk.call(child, new_stack) } if node.respond_to?(:child_nodes)
        else
          node.child_nodes.compact.each { |child| walk.call(child, stack) } if node.respond_to?(:child_nodes)
        end
      end
      walk.call(root, [])
      found
    end

    def find_sig_idx(lines, def_idx)
      (def_idx - 1).downto([def_idx - 5, 0].max) { |i| return i if lines[i]&.match?(/\bsig\s*\{/) }
      nil
    end
  end

  class InteractiveReview
    def initialize(argv)
      @kind = option_value(argv, "--kind") || "replace_nil_with_default"
      @dry_run = argv.include?("--dry-run")
      @evidence = Store.read
      @selected = Set.new
    end

    def run
      actions = @evidence["actions"].select { |action| action["kind"] == @kind }
      abort "no #{@kind} actions found; run `tools/nil-kill.rb infer` first" if actions.empty?
      if !$stdin.tty?
        print_noninteractive(actions)
        return
      end
      loop do
        render(actions)
        print "nil-kill review> "
        input = $stdin.gets&.strip
        break if input.nil? || input == "q"
        case input
        when "a"
          selected = @selected.map { |idx| actions[idx] }
          Apply.new(@dry_run ? ["--dry-run"] : []).apply_actions(selected)
          break
        when "all"
          actions.each_index { |idx| @selected.add(idx) }
        when "none"
          @selected.clear
        when /\Ao\s+(\d+)\z/
          open_context(actions, $1.to_i - 1)
        when /\A\d+\z/
          toggle(input.to_i - 1, actions.size)
        else
          puts "commands: number toggles, o N opens context, all, none, a applies, q quits"
        end
      end
    end

    def option_value(argv, flag)
      idx = argv.index(flag)
      idx ? argv[idx + 1] : nil
    end

    def render(actions)
      puts ""
      puts "Review #{@kind} actions"
      actions.each_with_index do |action, idx|
        mark = @selected.include?(idx) ? "x" : " "
        puts "#{idx + 1}. [#{mark}] #{action["path"]}:#{action["line"]} #{action["message"]}"
      end
      puts "commands: number toggles, o N opens context, all, none, a applies, q quits"
    end

    def print_noninteractive(actions)
      actions.each_with_index do |action, idx|
        puts "#{idx + 1}. [ ] #{action["path"]}:#{action["line"]} #{action["message"]}"
      end
    end

    def toggle(idx, size)
      return puts "out of range" if idx.negative? || idx >= size
      @selected.include?(idx) ? @selected.delete(idx) : @selected.add(idx)
    end

    def open_context(actions, idx)
      action = actions[idx]
      return puts "out of range" unless action
      path = File.join(ROOT, action["path"])
      line = action["line"].to_i
      lines = File.readlines(path)
      first = [line - 4, 1].max
      last = [line + 4, lines.size].min
      puts ""
      puts "#{action["path"]}:#{line}"
      puts "#{action["message"]}"
      (first..last).each do |line_no|
        marker = line_no == line ? ">" : " "
        puts "#{marker} #{line_no.to_s.rjust(5)}  #{lines[line_no - 1]}"
      end
    rescue Errno::ENOENT
      puts "missing file: #{action["path"]}"
    end
  end

  class Loop
    def initialize(argv)
      if argv.delete("--defaults")
        ENV["NIL_KILL_AUTO_DEFAULTS"] = "1"
      end
      sep = argv.index("--")
      @verify_cmd = sep ? argv[(sep + 1)..] : []
      @max_iters = ENV.fetch("NIL_KILL_MAX_ITERS", "10").to_i
      @skipped = Set.new
    end

    def run
      abort "usage: tools/nil-kill.rb loop -- <verify command...>" if @verify_cmd.empty?
      iter = 0
      loop do
        iter += 1
        puts "nil-kill loop iteration #{iter}"
        Infer.new([]).run
        evidence = Store.read
        high_actions = evidence["actions"].select { |action| action["confidence"] == HIGH && !@skipped.include?(fingerprint(action)) }
        high = high_actions.size
        puts "high-confidence actions: #{high}"
        break if high.zero?

        applied = apply_verified(high_actions)
        puts "verified actions applied: #{applied}; skipped this run: #{@skipped.size}"
        break if applied.zero?
        break if iter >= @max_iters
      end
    end

    def apply_verified(actions)
      return 0 if actions.empty?
      snapshot = snapshot_files(actions)
      Apply.new([]).apply_actions(actions)
      return actions.size if verify

      restore_files(snapshot)
      if actions.size == 1
        action = actions.first
        @skipped << fingerprint(action)
        warn "skipping failing action: #{action["path"]}:#{action["line"]} #{action["kind"]}: #{action["message"]}"
        return 0
      end

      mid = actions.size / 2
      apply_verified(actions.first(mid)) + apply_verified(actions.drop(mid))
    end

    def verify
      puts @verify_cmd.shelljoin
      system(*@verify_cmd)
    end

    def snapshot_files(actions)
      actions.map { |action| action["path"] }.uniq.each_with_object({}) do |rel_path, snapshot|
        path = File.join(ROOT, rel_path)
        snapshot[path] = File.read(path) if File.file?(path)
      end
    end

    def restore_files(snapshot)
      snapshot.each { |path, content| File.write(path, content) }
    end

    def fingerprint(action)
      JSON.generate([action["kind"], action["path"], action["line"], action["message"], action["data"]])
    end
  end

  class Report
    def run
      evidence = Store.read
      actions = evidence["actions"]
      by_conf = actions.group_by { |a| a["confidence"] }
      lines = ["# Nil Kill Report", ""]
      lines << "- Target dirs: #{evidence["target_dirs"].join(", ")}"
      lines << "- Methods indexed: #{evidence["methods"].size}"
      lines << "- Runtime-observed methods: #{evidence["methods"].count { |m| m["calls"].to_i.positive? }}"
      lines << "- Missing sigs: #{evidence["facts"]["unsigned_methods"].size}"
      lines << "- Existing sigs: #{evidence["facts"]["existing_sigs"].size}"
      lines << "- Existing/candidate T.let sites: #{evidence["facts"]["tlet_sites"].size}"
      lines << "- Sorbet errors captured: #{evidence["diagnostics"]["sorbet_errors"].size}"
      append_signature_coverage(lines, evidence)
      [HIGH, REVIEW, GAP].each do |conf|
        list = by_conf[conf] || []
        lines << ""
        lines << "## #{conf} actions (#{list.size})"
        list.first(50).each { |a| lines << "- #{a["path"]}:#{a["line"]} #{a["kind"]}: #{a["message"]}" }
        lines << "- ... #{list.size - 50} more" if list.size > 50
      end
      unless evidence["diagnostics"]["nil_origins"].empty?
        lines << ""
        lines << "## Nil origins"
        evidence["diagnostics"]["nil_origins"].first(20).each { |o| lines << "- #{o["origin"]}: #{o["count"]}" }
      end
      append_callsite_pressure(lines, actions)
      append_struct_report(lines, evidence)
      append_tuple_report(lines, evidence)
      FileUtils.mkdir_p(TMP_DIR)
      File.write(REPORT_PATH, lines.join("\n") + "\n")
      puts File.read(REPORT_PATH)
    end

    def append_callsite_pressure(lines, actions)
      nil_pressure = callsite_pressure(actions, "nil_param_observed")
      union_pressure = merge_pressure(
        callsite_pressure(actions, "union_observed"),
        callsite_pressure(actions, "bad_input_type_candidate")
      )
      lines << ""
      lines << "## Nilability Pressure By Root Callsite"
      append_pressure_list(lines, nil_pressure, "T.nilable")
      lines << ""
      lines << "## Union Pressure Downgraded To T.untyped"
      lines << "Changing these to T.any(...) can be dangerous unless you are certain the runtime sample includes every type that can reach the slot. Static analysis can separately look for other types that could be passed without breaking the function."
      append_pressure_list(lines, union_pressure, "T.any")
      lines << ""
      lines << "## T.any Downgrades By Signature"
      actions.select { |a| a["kind"] == "union_observed" }.first(50).each do |action|
        classes = Array(action.dig("data", "classes")).join(", ")
        lines << "- #{action["path"]}:#{action["line"]} #{action.dig("data", "name")}: observed #{classes}; kept as T.untyped"
      end
    end

    def append_signature_coverage(lines, evidence)
      param_counts = empty_type_counts
      return_counts = empty_type_counts
      evidence["facts"]["existing_sigs"].each do |method|
        sig = method["sig"].to_s
        extract_param_types(sig).each { |type| classify_type!(param_counts, type) }
        return_type = extract_return_type(sig)
        classify_type!(return_counts, return_type) if return_type
      end
      lines << ""
      lines << "## Signature Coverage"
      lines << "- Param slots: #{format_type_counts(param_counts)}"
      lines << "- Return slots: #{format_type_counts(return_counts)}"
      lines << "- Nilable param slots: #{param_counts["nilable"]}"
      lines << "- Nilable return slots: #{return_counts["nilable"]}"
    end

    def append_struct_report(lines, evidence)
      facts = evidence["facts"]
      runtime = Array(facts["struct_field_runtime"])
      static = Array(facts["struct_field_static"])
      declarations = Array(facts["struct_declarations"])
      lines << ""
      lines << "## Struct Shape Report"
      lines << "- Struct declarations: #{declarations.size}"
      lines << "- Runtime-observed struct field slots: #{runtime.map { |r| [r["class"], r["field"]] }.uniq.size}"
      lines << "- Static constructor field observations: #{static.size}"
      append_struct_field_candidates(lines, runtime, static)
      append_hash_shape_candidates(lines, Array(facts["hash_shapes"]))
    end

    def append_struct_field_candidates(lines, runtime, static)
      candidates = struct_field_candidates(runtime, static)
      lines << ""
      lines << "### Struct Field Type Candidates"
      if candidates.empty?
        lines << "- none"
        return
      end
      candidates.first(50).each do |candidate|
        source = candidate["runtime_calls"].positive? ? "runtime" : "static"
        parts = ["#{candidate["class"]}.#{candidate["field"]}", candidate["type"], "#{source}"]
        parts << "#{candidate["runtime_calls"]} call(s)" if candidate["runtime_calls"].positive?
        parts << "#{candidate["nil_count"]} nil observation(s)" if candidate["nil_count"].positive?
        lines << "- #{parts.join("; ")}"
      end
    end

    def struct_field_candidates(runtime, static)
      by_slot = Hash.new { |h, k| h[k] = { "class" => k[0], "field" => k[1], "classes" => [], "elem_classes" => [], "runtime_calls" => 0, "static_count" => 0 } }
      runtime.each do |rec|
        key = [rec["class"], rec["field"]]
        slot = by_slot[key]
        slot["classes"] |= Array(rec["classes"])
        slot["elem_classes"] |= Array(rec["elem_classes"])
        slot["runtime_calls"] += rec["calls"].to_i
      end
      static.each do |rec|
        key = [rec["class"], rec["field"]]
        slot = by_slot[key]
        slot["classes"] |= [rec["type"]].compact
        slot["static_count"] += 1
      end
      by_slot.values.filter_map do |slot|
        type = struct_slot_type(slot)
        next unless type && type != "T.untyped"
        slot.merge("type" => type, "nil_count" => slot["classes"].count("NilClass"))
      end.sort_by { |slot| [-slot["runtime_calls"], -slot["static_count"], slot["class"], slot["field"]] }
    end

    def struct_slot_type(slot)
      classes = Array(slot["classes"]).compact.reject(&:empty?)
      if classes == ["Array"] && !slot["elem_classes"].empty?
        elem = NilKill.sorbet_type(slot["elem_classes"], allow_nilable: true)
        return elem == "T.untyped" ? "T::Array[T.untyped]" : "T::Array[#{elem}]"
      end
      NilKill.sorbet_type(classes, allow_nilable: true)
    end

    def append_hash_shape_candidates(lines, shapes)
      grouped = Hash.new { |h, k| h[k] = { "count" => 0, "sites" => [] } }
      shapes.each do |shape|
        key = Array(shape["keys"]).sort.join(", ")
        grouped[key]["count"] += 1
        grouped[key]["sites"] << "#{shape["path"]}:#{shape["line"]}"
      end
      lines << ""
      lines << "### Hash Shapes That May Want Data/Struct"
      if grouped.empty?
        lines << "- none"
        return
      end
      grouped.sort_by { |_keys, data| -data["count"] }.first(30).each do |keys, data|
        lines << "- {#{keys}} appears #{data["count"]} time(s); first site #{data["sites"].first}"
      end
    end

    def append_tuple_report(lines, evidence)
      tuples = Array(evidence["facts"]["tuple_arrays"])
      grouped = Hash.new { |h, k| h[k] = { "count" => 0, "sites" => [], "confidence" => "review" } }
      tuples.each do |tuple|
        key = Array(tuple["types"]).join(", ")
        grouped[key]["count"] += 1
        grouped[key]["sites"] << "#{tuple["path"]}:#{tuple["line"]}"
        grouped[key]["confidence"] = "high" if tuple["confidence"] == "high"
      end
      lines << ""
      lines << "## Tuple-Like Array Report"
      lines << "- Tuple-like array literals: #{tuples.size}"
      if grouped.empty?
        lines << "- none"
        return
      end
      grouped.sort_by { |_types, data| [-data["count"], data["confidence"] == "high" ? 0 : 1] }.first(50).each do |types, data|
        lines << "- [#{types}] appears #{data["count"]} time(s), confidence #{data["confidence"]}; first site #{data["sites"].first}"
      end
    end

    def empty_type_counts
      { "strong" => 0, "weak" => 0, "untyped" => 0, "nilable" => 0 }
    end

    def classify_type!(counts, type)
      type = type.to_s.strip
      return if type.empty?
      counts["nilable"] += 1 if nilable_type?(type)
      inner = strip_nilable(type)
      if untyped_type?(inner)
        counts["untyped"] += 1
      elsif weak_type?(inner)
        counts["weak"] += 1
      else
        counts["strong"] += 1
      end
    end

    def format_type_counts(counts)
      "strong #{counts["strong"]}, weak #{counts["weak"]}, untyped #{counts["untyped"]}"
    end

    def extract_param_types(sig)
      params = extract_call_args(sig, "params")
      return [] unless params
      split_top_level(params).filter_map do |entry|
        _name, type = entry.split(/:\s*/, 2)
        type&.strip
      end
    end

    def extract_return_type(sig)
      extract_call_args(sig, "returns")
    end

    def extract_call_args(source, name)
      idx = source.index("#{name}(")
      return nil unless idx
      start = idx + name.length + 1
      depth = 1
      i = start
      while i < source.length
        case source[i]
        when "(" then depth += 1
        when ")"
          depth -= 1
          return source[start...i] if depth.zero?
        end
        i += 1
      end
      nil
    end

    def split_top_level(source)
      parts = []
      start = 0
      depth = 0
      source.each_char.with_index do |char, idx|
        case char
        when "(", "[", "{"
          depth += 1
        when ")", "]", "}"
          depth -= 1 if depth.positive?
        when ","
          if depth.zero?
            parts << source[start...idx].strip
            start = idx + 1
          end
        end
      end
      parts << source[start..].to_s.strip
      parts.reject(&:empty?)
    end

    def nilable_type?(type)
      type.start_with?("T.nilable(") || type == "NilClass"
    end

    def strip_nilable(type)
      return type unless type.start_with?("T.nilable(")
      extract_call_args(type, "T.nilable") || type
    end

    def untyped_type?(type)
      type == "T.untyped" || type == "NilClass"
    end

    def weak_type?(type)
      type.include?("T.any(") ||
        type.include?("T.untyped") ||
        type.match?(/\AT::(?:Array|Hash|Enumerable|Set)\b.*\[T\.untyped/)
    end

    def callsite_pressure(actions, kind)
      pressure = Hash.new { |h, k| h[k] = { "slots" => Set.new, "calls" => 0 } }
      actions.select { |a| a["kind"] == kind }.each do |action|
        slot = "#{action["path"]}:#{action["line"]}:#{action.dig("data", "name")}"
        (action.dig("data", "callsites") || {}).each do |site, count|
          root = site.sub(/:[^:]+\z/, "")
          pressure[root]["slots"] << slot
          pressure[root]["calls"] += count.to_i
        end
      end
      pressure
    end

    def merge_pressure(*groups)
      merged = Hash.new { |h, k| h[k] = { "slots" => Set.new, "calls" => 0 } }
      groups.each do |group|
        group.each do |site, data|
          merged[site]["slots"].merge(data["slots"])
          merged[site]["calls"] += data["calls"].to_i
        end
      end
      merged
    end

    def append_pressure_list(lines, pressure, label)
      if pressure.empty?
        lines << "- none"
        return
      end
      pressure.sort_by { |_site, data| pressure_sort_key(data) }.first(50).each do |site, data|
        slots = data["slots"].size
        calls = data["calls"].to_i
        score = pressure_priority(slots, calls)
        lines << "- #{site} priority #{format("%.2f", score)}; affects #{label} in #{slots} signature slot(s), #{calls} observed call(s)"
      end
    end

    def pressure_sort_key(data)
      slots = data["slots"].size
      calls = data["calls"].to_i
      case ENV.fetch("NIL_KILL_PRESSURE_SORT", "priority")
      when "slots"
        [-slots, -calls]
      when "hotness", "calls"
        [-calls, -slots]
      else
        [-pressure_priority(slots, calls), -slots, -calls]
      end
    end

    def pressure_priority(slots, calls)
      Math.sqrt([slots, 1].max) * (Math.log10([calls, 0].max + 1) + 1.0)
    end
  end

  class Doctor
    def run
      puts "ruby: #{RUBY_VERSION}"
      puts "prism: #{Prism::VERSION}"
      puts "targets: #{NilKill.target_dirs.map { |d| NilKill.rel(d) }.join(File::PATH_SEPARATOR)}"
      puts "runtime traces: #{Dir.glob(File.join(RUNTIME_DIR, "*.jsonl")).size}"
      puts "sorbet: #{command_ok?(%w[bundle exec srb --version])}"
      puts "tapioca: #{command_ok?(%w[bundle exec tapioca --version])}"
      puts "rbs-trace: #{gem_ok?("rbs/trace") || gem_ok?("rbs-trace")}"
      puts "parlour: #{gem_ok?("parlour")}"
    end

    def command_ok?(cmd)
      _out, _err, status = Open3.capture3(*cmd)
      status.success? ? "ok" : "missing/error"
    end

    def gem_ok?(feature)
      require feature
      "ok"
    rescue LoadError
      nil
    end
  end
end

NilKill::CLI.new(ARGV).run if $PROGRAM_NAME == __FILE__
