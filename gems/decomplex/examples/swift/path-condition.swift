func one(x: X,y: Y,z: Z) { if x.p() && y.q() && z.r() { go(x) } }
func two(x: X,y: Y,z: Z) { if x.p() && y.q() && z.r() { go(x) } }
func three(x: X,y: Y,z: Z) { if x.p() && y.q() && z.r() { go(x) } }
func bug(x: X,y: Y,z: Z) { if x.p() && y.q() { go(x) } }
