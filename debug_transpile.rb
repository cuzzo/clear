require_relative "src/transpiler"

src = File.read("transpile-tests/64_big_struct_return.cht")
zig = ZigTranspiler.new.transpile(src)
puts zig
