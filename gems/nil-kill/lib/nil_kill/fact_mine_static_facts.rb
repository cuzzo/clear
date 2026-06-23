# typed: false
# frozen_string_literal: true

require "tempfile"
require "json"
require "pathname"

module NilKill
  # Shim that delegates to the compiled Rust fact-mine-rust binary.
  # Retained for test compatibility and backward compatibility.
  module FactMineStaticFacts
    FACT_MINE_RUST_BINARY = ENV.fetch(
      "FACT_MINE_RUST_BINARY",
      File.join(NilKill::ROOT, "gems", "fact-mine", "target", "release", "fact-mine-rust")
    ).freeze

    module_function

    def build(document, structural_facts = nil, root: NilKill::ROOT, profile: :nil_kill)
      ext = case document.language.to_s
            when "python" then ".py"
            when "javascript" then ".js"
            when "typescript" then ".ts"
            when "go" then ".go"
            when "rust" then ".rs"
            when "zig" then ".zig"
            else ".rb"
            end

      src_tmp = Tempfile.new(["fact-mine-doc", ext])
      begin
        src_tmp.write(Array(document.lines).join)
        src_tmp.flush
        src_tmp.close

        out_tmp = Tempfile.new(["fact-mine-out", ".json"])
        out_tmp.close

        args = [FACT_MINE_RUST_BINARY, "profile", profile.to_s, "--output", out_tmp.path, src_tmp.path]
        ok = system(*args)
        raise "fact-mine-rust failed with status #{$?.exitstatus}" unless ok

        data = JSON.parse(File.read(out_tmp.path))
        
        symbolized = {}
        data.each do |key, val|
          symbolized[key.to_sym] = val
        end

        if document.respond_to?(:file) && document.file
          rel_doc_path = Pathname.new(document.file).relative_path_from(Pathname.new(root)).to_s rescue document.file
          replace_temp_path(symbolized, src_tmp.path, rel_doc_path)
        end

        symbolized
      ensure
        src_tmp&.unlink
        out_tmp&.unlink
      end
    end

    def replace_temp_path(data, temp_path, real_path)
      temp_name = File.basename(temp_path)
      case data
      when Hash
        data.each do |k, v|
          if v.is_a?(String) && (v == temp_path || v == temp_name || v.include?(temp_name))
            data[k] = real_path
          else
            replace_temp_path(v, temp_path, real_path)
          end
        end
      when Array
        data.each_with_index do |v, idx|
          if v.is_a?(String) && (v == temp_path || v == temp_name || v.include?(temp_name))
            data[idx] = real_path
          else
            replace_temp_path(v, temp_path, real_path)
          end
        end
      end
    end
  end
end