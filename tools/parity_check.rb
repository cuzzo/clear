
require "json"
require "open3"
require "fileutils"

ROOT = File.expand_path("..", __dir__)
EXE = File.join(ROOT, "gems/nil-kill/exe/nil-kill")
RUST_BIN = File.join(ROOT, "gems/nil-kill/rust/target/release/nil-kill-rust")

def canonicalize(json_str)
  data = JSON.parse(json_str)
  # Sort keys and arrays of objects to ensure deterministic comparison
  sort_json(data)
end

def sort_json(obj)
  case obj
  when Hash
    obj.keys.sort.each_with_object({}) { |k, h| h[k] = sort_json(obj[k]) }
  when Array
    obj.map { |v| sort_json(v) }.sort_by(&:to_s)
  else
    obj
  end
end

def run_parity(file)
  print "Testing #{file}... "
  
  # Ruby
  ruby_out, err, status = Open3.capture3("bundle exec #{EXE} source-index --engine ruby #{file}")
  unless status.success?
    puts "Ruby FAILED: #{err}"
    return false
  end
  
  # Rust
  rust_out, err, status = Open3.capture3("bundle exec #{EXE} source-index --engine rust #{file}")
  unless status.success?
    puts "Rust FAILED: #{err}"
    return false
  end
  
  ruby_data = canonicalize(ruby_out)
  rust_data = canonicalize(rust_out)
  
  if ruby_data == rust_data
    puts "OK"
    return true
  else
    puts "DIFF"
    File.write("parity_ruby.json", JSON.pretty_generate(ruby_data))
    File.write("parity_rust.json", JSON.pretty_generate(rust_data))
    return false
  end
end

targets = ARGV.empty? ? ["gems/nil-kill/lib/nil_kill/store.rb"] : ARGV
failed = []

targets.each do |target|
  if File.directory?(target)
    Dir.glob(File.join(target, "**/*.rb")).each do |file|
      failed << file unless run_parity(file)
    end
  else
    failed << target unless run_parity(target)
  end
end

if failed.empty?
  puts "\nAll parity tests PASSED!"
else
  puts "\nParity tests FAILED for #{failed.size} files."
  puts "First failure diff can be inspected via: diff parity_ruby.json parity_rust.json"
end
