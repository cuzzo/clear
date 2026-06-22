void original() { int src = fetch(1); check(src); store(src); finalize(src); }
void pasted() { int dst = fetch(2); check(dst); store(src); finalize(dst); }
