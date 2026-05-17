# typed: false
# frozen_string_literal: true

module NilKill
  class TracePlan
    def self.write(path = TRACE_PLAN_PATH)
      new.write(path)
    end

    def initialize
      @methods = {}
      @tlets = {}
      @struct_fields = {}
    end

    def write(path)
      NilKill.target_files.each do |file|
        idx = SourceIndex.new(file)
        idx.methods.each { |method| add_method(method) }
        idx.tlet_sites.each { |site| add_tlet(site) }
        idx.struct_declarations.each { |decl| add_struct_decl(decl) }
        idx.struct_field_static.each { |field| add_struct_static(field) }
      end
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, JSON.pretty_generate({
        "version" => 1,
        "generated_at" => Time.now.utc.iso8601,
        "target_dirs" => NilKill.target_dirs.map { |dir| File.expand_path(dir, ROOT) }.sort,
        "target_exclude_dirs" => NilKill.target_exclude_dirs.map { |dir| File.expand_path(dir, ROOT) }.sort,
        "methods" => @methods,
        "tlets" => @tlets,
        "struct_fields" => @struct_fields,
      }))
    end

    private

    def add_method(method)
      abs = File.expand_path(method["path"], ROOT)
      key = [method["class"], method["method"], method["kind"], abs, method["line"]].join("\0")
      param_types = NilKill.extract_param_entries(method["sig"]).to_h
      params = {}
      method["params"].each do |param|
        name = param["name"].to_s
        type = param_types[name] || param["type"]
        params[name] = !NilKill.strong_trace_type?(type)
      end
      return_type = NilKill.extract_return_type(method["sig"])
      sample_return = !method["sig"].to_s.include?(".void") && !NilKill.strong_trace_type?(return_type)
      @methods[key] = {
        "frame" => true,
        "params" => params,
        "return" => sample_return,
        "sample" => params.values.any? || sample_return,
      }
    end

    def add_tlet(site)
      return unless site["tlet"]
      type = site["type"]
      return if NilKill.strong_trace_type?(type)
      @tlets[[File.expand_path(site["path"], ROOT), site["line"]].join("\0")] = true
    end

    def add_struct_decl(decl)
      decl.fetch("fields", []).each do |field|
        @struct_fields[[decl["class"], field.to_s].join("\0")] = true
      end
    end

    def add_struct_static(field)
      klass = field["class"].to_s
      name = field["field"].to_s
      type = field["type"] || field["candidate_type"]
      key = [klass, name].join("\0")
      @struct_fields[key] = !NilKill.strong_trace_type?(type)
    end
  end
end
