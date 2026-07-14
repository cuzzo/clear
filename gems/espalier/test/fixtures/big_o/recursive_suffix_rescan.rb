class RecursiveSuffixRescan
  def initialize(items)
    @items = items
    @position = 0
  end

  def walk
    return if @position >= @items.length

    scan_remaining
    @position += 1
    walk
  end

  def scan_remaining
    cursor = @position
    while cursor < @items.length
      consume(@items[cursor])
      cursor += 1
    end
  end
end
