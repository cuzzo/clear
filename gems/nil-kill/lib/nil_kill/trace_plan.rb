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
      files = NilKill.target_files
      unless files.empty?
        static = StaticEvidence.build(files, root: ROOT, language: :ruby, include_annotations: true)
        static.fetch("methods", []).each { |method| add_static_method(method) }
        facts = Hash(static["facts"])
        tlet_types = Array(facts["tlet_sites"]).to_h do |site|
          add_tlet(site)
          [[File.expand_path(site["path"], ROOT), site["line"].to_i], site["type"]]
        end
        Array(facts["struct_declarations"]).each { |decl| add_struct_decl(decl) }
        static.fetch("fields", []).each { |field| add_static_field(field, tlet_types) }
        Array(facts["state_type_records"]).each { |field| add_static_state_type(field) }
        # Flow-derived state records are intentionally conservative and may
        # report T.untyped for assignments to a field whose declaration is
        # already strong. The declaration is the enforceable Sorbet contract,
        # so apply it last and let it suppress redundant runtime sampling.
        Array(facts["type_definitions"]).each { |definition| add_static_type_definition(definition) }
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
      sample_return = !void_signature?(method["sig"]) && !NilKill.strong_trace_type?(return_type)
      sample_method = params.values.any? || sample_return
      @methods[key] = {
        "frame" => sample_method,
        "params" => params,
        "return" => sample_return,
        "sample" => sample_method,
      }
    end

    def add_static_method(method)
      signature = method["signature"].to_s
      param_types = NilKill.extract_param_entries(signature).to_h
      untraceable = Array(method["untraceable_params"]).map(&:to_s).to_set
      params = Array(method["params"]).reject { |name| untraceable.include?(name.to_s) }.to_h do |name|
        type = param_types[name.to_s]
        [name.to_s, !NilKill.strong_trace_type?(type)]
      end
      return_type = NilKill.extract_return_type(signature)
      sample_return = !void_signature?(signature) && !NilKill.strong_trace_type?(return_type)
      sample_method = params.values.any? || sample_return
      name = method_name(method)
      key = [
        method["owner"].to_s,
        name,
        method_kind(method),
        File.expand_path(method["path"], ROOT),
        method["line"],
      ].join("\0")
      @methods[key] = {
        "frame" => sample_method,
        "params" => params,
        "return" => sample_return,
        "sample" => sample_method,
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

    def add_static_state_type(field)
      klass = field["owner"].to_s
      name = field["field"].to_s.sub(/\A@/, "")
      type = field["declared_type"].to_s
      return if klass.empty? || name.empty? || type.empty?

      @struct_fields[[klass, name].join("\0")] = !NilKill.strong_trace_type?(type)
    end

    def add_static_type_definition(definition)
      return unless definition["kind"].to_s == "state_field"

      klass = definition["owner"].to_s
      name = definition["name"].to_s.sub(/\A@/, "")
      type = definition["declared_type"].to_s
      return if klass.empty? || name.empty? || type.empty?

      @struct_fields[[klass, name].join("\0")] = !NilKill.strong_trace_type?(type)
    end

    def add_static_field(field, tlet_types)
      klass = field["owner"].to_s
      name = (field["name"] || field["field"]).to_s.sub(/\A@/, "")
      path = File.expand_path(field["path"], ROOT)
      type = field["declared_type"]
      type = tlet_types[[path, field["line"].to_i]] if type.to_s.empty?
      return if klass.empty? || name.empty? || type.to_s.empty?

      @struct_fields[[klass, name].join("\0")] = !NilKill.strong_trace_type?(type)
    end

    def method_name(method)
      method["name"].to_s.sub(/\Aself\./, "")
    end

    def method_kind(method)
      raw = method["kind"].to_s
      name = method["name"].to_s
      return "class" if name.start_with?("self.") || raw == "class" || raw == "class_method"
      return "function" if raw == "function" || method["owner"].to_s.empty?

      "instance"
    end

    def void_signature?(signature)
      signature.to_s.match?(/\bvoid\b/)
    end
  end
end
