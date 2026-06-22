class TemporalOrderExample { one() { this.a = 1; } two() { this.a = 2; this.b = 3; } three() { this.b = 4; } reader() { return this.a; } }
