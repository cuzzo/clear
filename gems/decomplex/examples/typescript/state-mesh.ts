class StateMeshExample { initialize() { this.a = 1; this.b = 2; } writer() { this.a = 3; } reader() { return this.a + this.b; } a_alias() { return this.a; } }
