pub fn one(x: X, y: Y, z: Z) void {
    if (x.p() and y.q() and z.r()) { go(x); }
}

pub fn two(x: X, y: Y, z: Z) void {
    if (x.p() and y.q() and z.r()) { go(x); }
}

pub fn three(x: X, y: Y, z: Z) void {
    if (x.p() and y.q() and z.r()) { go(x); }
}

pub fn bug(x: X, y: Y, z: Z) void {
    if (x.p() and y.q()) { go(x); }
}
