# frozen_string_literal: true

def one(x, y, z)
  go(x) if x.p? && y.q? && z.r?
end

def two(x, y, z)
  go(x) if x.p? && y.q? && z.r?
end

def three(x, y, z)
  go(x) if x.p? && y.q? && z.r?
end

def bug(x, y, z)
  go(x) if x.p? && y.q?
end
