# typed: false
# frozen_string_literal: true

module NilKill
  module Runtime
    class StaticIndex
      attr_reader :static, :methods_by_id, :fields_by_id

      def initialize(static, root: NilKill::ROOT)
        @root = root
        @static = Schema::EvidenceBundle.canonical_static(static || {})
        @methods_by_id = {}
        @method_lookup = Hash.new { |h, k| h[k] = [] }
        @fields_by_id = {}
        build_method_index
        build_field_index
        @static["methods"] = @methods_by_id.values.sort_by { |method| [method["path"].to_s, method["line"].to_i, method["owner"].to_s, method["name"].to_s] }
        @static["fields"] = @fields_by_id.values.sort_by { |field| [field["path"].to_s, field["owner"].to_s, field["name"].to_s] }
      end

      def resolve_method(event)
        id = string_value(event, "method_id")
        return [id, @methods_by_id[id], true] if !id.empty? && @methods_by_id.key?(id)

        language = string_value(event, "language")
        path = rel_path(string_value(event, "path"))
        line = integer_value(event, "line")
        locator = event["locator"] || event[:locator] || {}
        owner = string_value(locator, "owner")
        name = string_value(locator, "name")
        kind = string_value(locator, "kind")

        candidates = []
        candidates.concat(@method_lookup[["line", language, path, line, name]])
        candidates.concat(@method_lookup[["owner", language, path, owner, name, kind]])
        candidates.concat(@method_lookup[["name", language, owner, name, kind]])
        candidates.concat(@method_lookup[["path_line", path, line]]) if candidates.empty?
        candidates.concat(nearby_path_name_candidates(language, path, name, line)) if candidates.empty?
        method = candidates.compact.uniq.first
        return [method["id"], method, true] if method

        synthetic = id.empty? ? synthetic_method_id(language, path, owner, kind, name, line) : id
        [synthetic, synthetic_method(language, path, owner, kind, name, line, id: synthetic), false]
      end

      def method(id)
        @methods_by_id[id]
      end

      def field(id)
        @fields_by_id[id]
      end

      private

      def build_method_index
        Array(@static["methods"]).each do |raw|
          method = normalize_method(raw)
          next if method["id"].to_s.empty?

          @methods_by_id[method["id"]] = method
          language = method["language"].to_s
          path = method["path"].to_s
          line = method["line"].to_i
          owner = method["owner"].to_s
          name = method["name"].to_s
          kind = method["kind"].to_s
          @method_lookup[["line", language, path, line, name]] << method
          @method_lookup[["owner", language, path, owner, name, kind]] << method
          @method_lookup[["name", language, owner, name, kind]] << method
          @method_lookup[["path_name", language, path, name]] << method
          @method_lookup[["path_line", path, line]] << method
        end
      end

      def build_field_index
        Array(@static["fields"]).each do |raw|
          field = normalize_field(raw)
          next if field["id"].to_s.empty?

          @fields_by_id[field["id"]] = field
        end
      end

      def normalize_method(raw)
        raw = raw.transform_keys(&:to_s)
        language = (raw["language"] || "unknown").to_s
        path = rel_path(raw["path"].to_s)
        owner = (raw["owner"] || raw["class"] || raw["scope"]).to_s
        name = (raw["name"] || raw["method"]).to_s
        kind = (raw["kind"] || "function").to_s
        line = raw["line"].to_i
        raw.merge(
          "id" => raw["id"].to_s.empty? ? synthetic_method_id(language, path, owner, kind, name, line) : raw["id"].to_s,
          "language" => language,
          "path" => path,
          "owner" => owner,
          "name" => name,
          "kind" => kind,
          "line" => line,
          "params" => normalize_params(raw["params"]),
          "return" => normalize_return(raw["return"]),
        )
      end

      def normalize_field(raw)
        raw = raw.transform_keys(&:to_s)
        language = (raw["language"] || "unknown").to_s
        path = rel_path(raw["path"].to_s)
        owner = (raw["owner"] || raw["class"] || raw["owner_id"]).to_s
        name = (raw["name"] || raw["field"]).to_s
        raw.merge(
          "id" => raw["id"].to_s.empty? ? "#{language}\0#{path}\0#{owner}\0field\0#{name}" : raw["id"].to_s,
          "language" => language,
          "path" => path,
          "owner" => owner,
          "name" => name,
        )
      end

      def normalize_params(params)
        Array(params).map do |param|
          param.is_a?(Hash) ? param.transform_keys(&:to_s) : { "name" => param.to_s }
        end
      end

      def normalize_return(ret)
        return ret.transform_keys(&:to_s) if ret.is_a?(Hash)

        ret.nil? ? {} : { "declared_type" => ret.to_s }
      end

      def synthetic_method(language, path, owner, kind, name, line, id: nil)
        {
          "id" => id || synthetic_method_id(language, path, owner, kind, name, line),
          "language" => language,
          "path" => path,
          "owner" => owner,
          "name" => name,
          "kind" => kind,
          "line" => line,
          "params" => [],
          "return" => {},
          "synthetic" => true,
        }
      end

      def synthetic_method_id(language, path, owner, kind, name, line)
        "#{language}\0#{path}\0#{owner}\0#{kind.empty? ? "function" : kind}\0#{name}\0#{line.to_i}"
      end

      def rel_path(path)
        return "" if path.to_s.empty?

        Pathname.new(File.expand_path(path, @root)).relative_path_from(Pathname.new(@root)).to_s
      rescue StandardError
        path.to_s
      end

      def string_value(hash, key)
        (hash[key] || hash[key.to_sym]).to_s
      end

      def integer_value(hash, key)
        (hash[key] || hash[key.to_sym]).to_i
      end

      def nearby_path_name_candidates(language, path, name, line)
        Array(@method_lookup[["path_name", language, path, name]])
          .select { |method| (method["line"].to_i - line.to_i).abs <= 5 }
          .sort_by { |method| [(method["line"].to_i - line.to_i).abs, method["owner"].to_s] }
      end
    end
  end
end
