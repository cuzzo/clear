$LOAD_PATH.unshift File.expand_path('lib', '/home/yahn/cheat/gems/ruby-to-clear')
require 'ruby_to_clear'
src = <<~RB
  class Foo
    def bar(opts)
      if opts["size"]
        v = opts["size"].to_f
        puts "neg" if v <= 0
      end
    end
  end
RB
puts RubyToClear.transpile(src) rescue puts $!.message
