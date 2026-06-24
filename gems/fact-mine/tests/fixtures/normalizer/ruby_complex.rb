def complex_rescue
  yield 1, 2
  yield
rescue Exception => e
  puts e
rescue => e
  puts e
else
  puts "No error"
ensure
  puts "Finally"
end

x = 1 if y
y = 2 unless x
z = 3 while false
a = 4 until true

text = <<-HTML
  <div>Hello</div>
HTML

str = "Value: #{x}"
chained = "a" "b"

class A
  class << self
    def foo
    end
  end
end

super(1, 2)
super

BEGIN { puts "begin" }
END { puts "end" }
