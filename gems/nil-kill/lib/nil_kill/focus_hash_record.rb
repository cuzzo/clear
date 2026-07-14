# typed: false
# frozen_string_literal: true

module NilKill
  class FocusHashRecord
    def initialize(argv)
      @struct_name = argv.shift.to_s
      abort "usage: bundle exec tools/nil-kill focus-hash-record STRUCT [--targets path[:path...]]" if @struct_name.empty?
      @targets = []
      @two_pass = !!argv.delete("--two-pass")
      while (idx = argv.index("--targets"))
        value = argv[idx + 1] || abort("--targets requires a #{File::PATH_SEPARATOR}-separated path list")
        argv.slice!(idx, 2)
        @targets.concat(value.split(File::PATH_SEPARATOR))
      end
      @targets.concat(argv)
    end

    def run
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      paths = focus_paths
      abort "no focused paths found for #{@struct_name}; pass --targets path[:path...]" if paths.empty?

      store = Store.new
      StaticAnalysis.index_store(store: store, targets: paths, root: ROOT)
      evidence = store.to_h
      report = Report.new([], evidence: evidence)
      candidate = report.send(:hash_record_struct_candidates, evidence)
        .find { |row| row["struct_name"].to_s == @struct_name }
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      puts "focused hash-record #{@struct_name}"
      puts "files: #{paths.map { |path| NilKill.rel(path) }.join(", ")}"
      puts "elapsed: #{format("%.3f", elapsed)}s"
      if candidate
        puts "pressure: #{candidate["total_pressure"]}; producers: #{Array(candidate["producers"]).size}; consumers: #{Array(candidate["consumers"]).size}; signatures: #{Array(candidate["signatures"]).size}"
        puts "blockers: #{Array(candidate["blockers"]).empty? ? "none" : Array(candidate["blockers"]).join("; ")}"
        puts JSON.pretty_generate(candidate)
      else
        puts "no #{@struct_name} action produced from focused evidence"
      end
    end

    def focus_paths
      explicit = @targets.map { |path| File.expand_path(path, ROOT) }.select { |path| File.file?(path) }
      return explicit.uniq.sort unless explicit.empty?

      evidence = Store.read
      report = Report.new([], evidence: evidence)
      candidate = report.send(:hash_record_struct_candidates, evidence)
        .find { |row| row["struct_name"].to_s == @struct_name }
      return [] unless candidate
      (Array(candidate["producers"]) + Array(candidate["consumers"]) + Array(candidate["signatures"]))
        .map { |site| site["path"].to_s }
        .reject(&:empty?)
        .map { |path| File.expand_path(path, ROOT) }
        .select { |path| File.file?(path) }
        .uniq
        .sort
    end
  end
end
