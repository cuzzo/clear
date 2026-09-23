require "rspec"
require_relative "/home/yahn/cheat/compiler/ruby/backends/transpiler" unless defined?(ZigTranspiler)
SRC = <<~CLEAR
  STRUCT P { name: String }
  FN base_names(params: []P, paths: []String) RETURNS !Bool ->
    MUTABLE base_paths = paths |> UNNEST (IF _ == "*" THEN [COPY "wildcard"] ELSE [UNWRAP (_.split(".").first())] END);
    FOR p IN params DO
      IF !((base_paths.contains?("wildcard") OR base_paths.contains?(p.name))) THEN
        RETURN TRUE;
      END
    END
    RETURN FALSE;
  END
  FN main() RETURNS Int64 -> RETURN 0; END
CLEAR
begin
  ZigTranspiler.new(source_dir: Dir.pwd).transpile(SRC, source_dir: Dir.pwd)
  puts "TRANSPILED"
rescue => e
  puts "FAILED: #{e.message.gsub(/\e\[[0-9;]*m/,'')[0,200]}"
end
