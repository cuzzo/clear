CellState = Struct.new(:life, :neighbors)

def grid(live_cells)
  live_cells
    .reduce({}) do |acc, cell|
      cell_neighbors(cell).each do |neighbor|
        acc[neighbor] ||= CellState.new(false, 0)
        acc[neighbor].neighbors += 1
      end
      acc[cell] ||= CellState.new(true, 0)
      acc[cell].life = true
      acc
    end
end

def cell_neighbors(cell)
  dimensions = cell.map { |coord| ((coord - 1)..(coord + 1)).to_a }
  dimensions[0].product(*dimensions.drop(1)) - [cell]
end

# TODO: pass these rules in to revive?/survive?
def revive?(life_state, live_neighbors)
  life_state == false && live_neighbors >= 3 && live_neighbors <= 3
end

def survive?(life_state, live_neighbors)
  life_state == true && live_neighbors >= 2 && live_neighbors <= 3
end

# @return bool
#   cell's life state
def evolve(state)
  return true if survive?(state.life, state.neighbors) || revive?(state.life, state.neighbors)
  return false
end

# @return array
#   list of cells that lived to the next generation.
def advance(live_cells)
  grid = grid(live_cells)

  grid
    .reduce({}) do |acc, (cell, state)|
      acc[cell] = evolve(state)
      acc
    end
    .to_a
    .select { |_cell, life_state| life_state }
    .map(&:first)
end
