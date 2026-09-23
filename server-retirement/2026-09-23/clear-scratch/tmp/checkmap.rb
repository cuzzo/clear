$PROGRAM_NAME = 'x'
ROOT = File.expand_path('.')
require_relative '/home/yahn/cheat/tools/parser_compat'
require_relative '/home/yahn/cheat/compiler/ruby/compiler/package_source'
GEN = File.join(ROOT, 'compiler', 'src')
groups = ParserCompat.package_groups(GEN)
entry = groups.find { |_n, m| m.include?('annotator/annotator.clear') }
pkg_paths = {}
groups.each { |name, members| pkg_paths[name] = members.map { |rel| File.join(GEN, rel) }.join(',') }
merged = PackageSource.merge(entry.last.map { |rel| File.join(GEN, rel) }, resolve_pkg: ->(n) { pkg_paths[n] })
lines = merged.source.split("\n", -1)
puts "merged lines: #{lines.length}"
[15888, 15890].each { |n| puts "#{n}: #{lines[n-1].to_s[0,140]}" }
