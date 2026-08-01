#!/usr/bin/env ruby
# frozen_string_literal: true

# Connect source-proven CRuby C functions to the stable runtime identities
# emitted by NilKill.  Registration is the authoritative ownership relation:
# no Ruby method is admitted unless both its registration and the exact C
# declaration symbol appear in the producer's generated summary.

require "json"
require "zlib"

producer_path, profile_path, source_root, output, runtime_version = ARGV
abort "usage: build_symbol_bridge.rb PRODUCER.json.gz PROFILE.json SOURCE_ROOT OUTPUT.json RUBY_VERSION" unless runtime_version
abort "invalid Ruby runtime version #{runtime_version.inspect}" unless runtime_version.match?(/\A\d+\.\d+\.\d+\z/)

producer = Zlib::GzipReader.open(producer_path) { |gzip| JSON.parse(gzip.read) }
profile = JSON.parse(File.read(profile_path))
source_root = File.expand_path(source_root)

def ruby_owner(receiver)
  return unless receiver.match?(/\Arb_[cme][A-Za-z0-9_]+\z/)

  receiver.delete_prefix("rb_")[1..]
end

def runtime_atom(name)
  operators = %w[[] []= + - * / % ** << >> < <= > >= == === =~ !~ & | ^ ~ +@ -@ <=>]
  operators.include?(name) ? "`#{name}`" : name
end

def runtime_symbol(owner, separator, name, version)
  "nil-kill-runtime ruby ruby #{version} #{owner}#{separator}#{runtime_atom(name)}()."
end

def registrations(source_root)
  rows = []
  Dir.glob(File.join(source_root, "**", "*.c")).sort.each do |path|
    source = File.read(path)
    relative = path.delete_prefix("#{source_root}#{File::SEPARATOR}")
    source.scan(
      /rb_define_(singleton_method|method|module_function|private_method)\s*\(\s*(rb_[cme][A-Za-z0-9_]+)\s*,\s*"([^"]+)"\s*,\s*([A-Za-z_][A-Za-z0-9_]*)/m
    ) do |kind, receiver, name, function|
      owner = ruby_owner(receiver)
      next unless owner

      separators = case kind
                   when "singleton_method" then ["."]
                   when "module_function" then ["#", "."]
                   else ["#"]
                   end
      separators.each do |separator|
        rows << { "path" => relative, "function" => function, "owner" => owner,
                  "separator" => separator, "name" => name }
      end
    end
    source.scan(
      /rb_define_global_function\s*\(\s*"([^"]+)"\s*,\s*([A-Za-z_][A-Za-z0-9_]*)/m
    ) do |name, function|
      rows << { "path" => relative, "function" => function, "owner" => "Kernel",
                "separator" => "#", "name" => name }
    end
    # file.c intentionally registers FileTest module functions and File
    # singleton methods through this macro.  Preserve both exact public
    # identities rather than hard-coding their costs.
    source.scan(
      /define_filetest_function\s*\(\s*"([^"]+)"\s*,\s*([A-Za-z_][A-Za-z0-9_]*)/m
    ) do |name, function|
      rows << { "path" => relative, "function" => function, "owner" => "FileTest",
                "separator" => "#", "name" => name }
      rows << { "path" => relative, "function" => function, "owner" => "File",
                "separator" => ".", "name" => name }
    end
  end
  rows.uniq
end

exact_summary_symbols = producer.fetch("symbols").select do |_symbol, row|
  row.fetch("bound_quality", "") == "upper_bound_exact_symbol"
end.keys.to_h { |symbol| [symbol, true] }

methods = profile.fetch("methods").filter_map do |method|
  symbol = method["semantic_symbol"].to_s
  next unless exact_summary_symbols[symbol]

  path = method.fetch("path").to_s
  relative = path.delete_prefix("#{source_root}#{File::SEPARATOR}")
  next if relative == path

  [[relative, method.fetch("name").to_s], symbol]
end.to_h

# A registration may be repeated, but one runtime method must never be
# assigned an arbitrary implementation when CRuby has multiple declarations.
targets = Hash.new { |hash, key| hash[key] = [] }
registrations(source_root).each do |registration|
  symbol = methods[[registration.fetch("path"), registration.fetch("function")]]
  next unless symbol

  target = runtime_symbol(
    registration.fetch("owner"), registration.fetch("separator"), registration.fetch("name"), runtime_version
  )
  targets[target] << symbol unless targets[target].include?(symbol)
end

symbols = Hash.new { |hash, key| hash[key] = [] }
targets.each do |target, candidates|
  next unless candidates.length == 1

  symbols[candidates.fetch(0)] << target
end
symbols.transform_values!(&:sort)
abort "no source-proven CRuby registrations matched the producer summary" if symbols.empty?

File.write(output, JSON.pretty_generate({
  "schema" => "fact-mine.symbol-bridge.v1",
  "symbols" => symbols.sort.to_h
}))
