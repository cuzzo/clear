void original() { auto src = fetch(1); check(src); store(src); finalize(src); }
void pasted() { auto dst = fetch(2); check(dst); store(src); finalize(dst); }
