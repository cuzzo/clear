def cartesian_product(xs, ys)
  xs.each do |x|
    ys.each do |y|
      consume(x, y)
    end
  end
end

def same_domain_product(xs)
  xs.each do |left|
    xs.each do |right|
      consume(left, right)
    end
  end
end

def three_domain_product(xs, ys, zs)
  xs.each do |x|
    ys.each do |y|
      zs.each do |z|
        consume(x, y, z)
      end
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
