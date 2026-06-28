# frozen_string_literal: true

require_relative "../boobytrap"
require "json"

opts = { repo: ".", output: nil, json: nil, top: 40, only: [], files: [], exclude: [], go_data_path: nil }
args = ARGV.dup
until args.empty?
  a = args.shift
  case a
  when /\A--repo=(.+)/      then opts[:repo] = Regexp.last_match(1)
  when /\A--output=(.+)/    then opts[:output] = Regexp.last_match(1)
  when /\A--json=(.+)/      then opts[:json] = Regexp.last_match(1)
  when /\A--top=(\d+)/      then opts[:top] = Regexp.last_match(1).to_i
  when /\A--only=(.+)/      then opts[:only] << Regexp.last_match(1)
  when /\A--files=(.+)/     then opts[:files].concat(Regexp.last_match(1).split(","))
  when /\A--exclude=(.+)/   then opts[:exclude] << Regexp.last_match(1)
  when /\A--go-data-path=(.+)/ then opts[:go_data_path] = Regexp.last_match(1)
  end
end

if opts[:go_data_path] && File.file?(opts[:go_data_path])
  go_data = JSON.parse(File.read(opts[:go_data_path]))
else
  abort "Error: --go-data-path is required and must exist"
end

report = Boobytrap::Report.new(
  repo: opts[:repo],
  top: opts[:top],
  only: opts[:only],
  files: opts[:files],
  exclude: opts[:exclude],
  go_data: go_data
)

if opts[:json]
  File.write(opts[:json], report.to_json)
end

md = report.to_markdown

if opts[:output]
  File.write(opts[:output], md)
else
  puts md
end
