class TemporalOrderExample { int a; int b; public void one() { this.a = 1; } public void two() { this.a = 2; this.b = 3; } public void three() { this.b = 4; } public int reader() { return this.a; } }
