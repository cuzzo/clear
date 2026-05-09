#! /usr/bin/env ruby

require_relative "grid"
require_relative "gui"

def read_grid(file_path)
  File
    .read(file_path)
    .lines
    .map(&:chomp)
    .map { |line| line.split(',').map(&:to_i) }
end

def main()
  cells = read_grid(ARGV.first)

  while cells.count > 0
    render(cells)
    cells = advance(cells)
    STDIN.gets
  end
end

main()
