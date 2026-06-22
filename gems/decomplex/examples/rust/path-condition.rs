fn one(x: X, y: Y, z: Z) {
    if x.p() && y.q() && z.r() { go(x); }
}

fn two(x: X, y: Y, z: Z) {
    if x.p() && y.q() && z.r() { go(x); }
}

fn three(x: X, y: Y, z: Z) {
    if x.p() && y.q() && z.r() { go(x); }
}

fn bug(x: X, y: Y, z: Z) {
    if x.p() && y.q() { go(x); }
}
