class TemporalOrderExample { public: int a; int b; void one() { this->a = 1; } void two() { this->a = 2; this->b = 3; } void three() { this->b = 4; } int reader() { return this->a; } };
