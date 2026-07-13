def cartesian_product(xs, ys)
  xs.each do |x|
    ys.each do |y|
      consume(x, y)
    end
  end
end

def fixed_matrix
  4.times do |row|
    8.times do |column|
      consume(row, column)
    end
  end
end
