class StateBranchChecker { public: bool checked; void check(bool admin, string name) { if (admin) { this->checked = true; } if (this->checked && name == "admin") { print("hello"); } } };
