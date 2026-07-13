fn fixedGrid() void {
    for (0..4) |row| {
        for (0..8) |column| {
            consume(row, column);
        }
    }
}
