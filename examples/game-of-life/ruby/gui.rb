def render(cells)
  grid = cells.reduce({}) do |acc, cell|
    acc[cell] = 1
    acc
  end

  xs = cells.map { |x, y| x }
  ys = cells.map { |x, y| y }

  puts "---GENERATION---"
  puts "(#{xs.min},#{ys.min}) (#{xs.max},#{ys.max})"
  puts graph(grid, xs, ys)
end

def graph(grid, xs, ys)
  ((xs.min - 1)..(xs.max + 1)).to_a.reduce([]) do |acc, x|
    acc << ((ys.min - 1)..(ys.max + 1)).to_a.reduce("") do |bcc, y|
      bcc += grid.has_key?([x, y]) ? "X" : "O"
      bcc
    end
    acc
  end
end
