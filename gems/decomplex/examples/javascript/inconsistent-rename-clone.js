function original() { const src = fetch(1); check(src); store(src); finalize(src); }
function pasted() { const dst = fetch(2); check(dst); store(src); finalize(dst); }
