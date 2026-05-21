#!/usr/bin/env ruby
# Audit: every transpile-test site where a frame container is classified
# as :list_with_elem_cleanup -- i.e. a frame @list whose elements own
# heap. Each such site is one source location where CLEAR's
# "one collection = one allocator" principle is violated; the runtime
# papers over the mismatch via the :cleanup allocator vtable + the
# ptrIsFrameOwned address-range check.
#
# A clean compiler should produce ZERO such sites. The path to zero is
# uniform container_alloc inheritance at every COPY/dupeValue/auto-COPY
# emit site (annotator.rb:ensure_owned_value!, union variant construction,
# struct field initializers, append/insert/put argument auto-COPY).
#
# Usage:
#   bundle exec ruby tools/audit_provenance_mismatch.rb
#     -> walks transpile-tests/*.cht, summarizes mismatches per file.
#   bundle exec ruby tools/audit_provenance_mismatch.rb foo.cht
#     -> single-file, prints per-decl mismatches.
#
# Mechanism: this tool sets AUDIT_PROVENANCE_MISMATCH=1 and invokes the
# real transpiler (src/backends/transpiler.rb) per file as a subprocess
# so it sees the full compile pipeline. CleanupEntry.build emits one
# line per :list_with_elem_cleanup entry it produces. We aggregate.

require "open3"

TRANSPILER = File.expand_path("../src/backends/transpiler.rb", __dir__)
FILES = ARGV.any? ? ARGV : Dir.glob("transpile-tests/*.cht").sort

per_file = Hash.new { |h, k| h[k] = [] }
total = 0

FILES.each do |f|
  cmd = ["ruby", TRANSPILER, f]
  env = { "AUDIT_PROVENANCE_MISMATCH" => "1", "AUDIT_CURRENT_FILE" => f }
  _out, err, _status = Open3.capture3(env, *cmd)
  err.each_line do |line|
    next unless line.start_with?("[mismatch]")
    per_file[f] << line.chomp
    total += 1
  end
end

puts "frame @list / heap elements mismatch sites (cleanupAlloc workaround)\n\n"
per_file.sort_by { |_, v| -v.size }.each do |f, lines|
  printf "  %4d  %s\n", lines.size, f
end

if FILES.size == 1
  puts "\nDetailed sites for #{FILES.first}:\n"
  per_file[FILES.first].each { |l| puts "  #{l}" }
end

puts
puts "TOTAL: #{total} mismatch sites across #{per_file.size} files (out of #{FILES.size} scanned)"
puts
puts "Each site forces the runtime to use cleanupAlloc + ptrIsFrameOwned"
puts "to dispatch per-element cleanup at runtime instead of comptime."
