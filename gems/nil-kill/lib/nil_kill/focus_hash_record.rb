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
      SourceIndex.reset_global_shape_indexes
      paths.each { |path| SourceIndex.new(path) } if @two_pass
      paths.each do |path|
        idx = SourceIndex.new(path)
        store.facts["files"][NilKill.rel(path)] = idx.summary
        store.facts["unsigned_methods"].concat(idx.methods.reject { |method| method["has_sig"] })
        store.facts["existing_sigs"].concat(idx.methods.select { |method| method["has_sig"] })
        store.facts["tlet_sites"].concat(idx.tlet_sites)
        store.facts["dead_nil_checks"].concat(idx.dead_nil_checks)
        store.facts["struct_declarations"].concat(idx.struct_declarations)
        store.facts["struct_field_static"].concat(idx.struct_field_static)
        store.facts["tuple_arrays"].concat(idx.tuple_arrays)
        store.facts["hash_shapes"].concat(idx.hash_shapes)
        store.facts["collection_index_lookups"].concat(idx.collection_index_lookups)
        store.facts["hash_record_blockers"].concat(idx.hash_record_blockers)
        store.facts["hash_record_member_calls"].concat(idx.hash_record_member_calls)
        store.facts["type_normalizers"].concat(idx.type_normalizers)
        store.facts["dispatcher_inferences"].concat(idx.dispatcher_inferences)
        store.facts["return_origins"].concat(idx.return_origins)
        store.facts["param_origins"].concat(idx.param_origins)
        idx.methods.each do |method|
          rec = store.method_record([method["class"], method["method"], method["kind"], File.expand_path(method["path"], ROOT), method["line"]])
          rec["source"] = method
          rec["has_sig"] = method["has_sig"]
        end
      end

      infer = Infer.allocate
      infer.instance_variable_set(:@store, store)
      infer.send(:propose_hash_record_cluster_actions)
      action = store.actions.find { |candidate| candidate.dig("data", "struct_name").to_s == @struct_name }
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      puts "focused hash-record #{@struct_name}"
      puts "files: #{paths.map { |path| NilKill.rel(path) }.join(", ")}"
      puts "elapsed: #{format("%.3f", elapsed)}s"
      if action
        data = action["data"] || {}
        puts "pressure: #{data.dig("pressure", "total")}; producers: #{Array(data["producers"]).size}; consumers: #{Array(data["consumers"]).size}; signatures: #{Array(data["signatures"]).size}"
        puts "blockers: #{Array(data["blockers"]).empty? ? "none" : Array(data["blockers"]).join("; ")}"
        puts JSON.pretty_generate(action)
      else
        puts "no #{@struct_name} action produced from focused evidence"
      end
    end

    def focus_paths
      explicit = @targets.map { |path| File.expand_path(path, ROOT) }.select { |path| File.file?(path) }
      return explicit.uniq.sort unless explicit.empty?

      evidence = Store.read
      action = Array(evidence["actions"]).find { |candidate| candidate.dig("data", "struct_name").to_s == @struct_name }
      return [] unless action
      data = action["data"] || {}
      (Array(data["producers"]) + Array(data["consumers"]) + Array(data["signatures"]))
        .map { |site| site["path"].to_s }
        .reject(&:empty?)
        .map { |path| File.expand_path(path, ROOT) }
        .select { |path| File.file?(path) }
        .uniq
        .sort
    end
  end
end
