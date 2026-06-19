function original() local src = fetch(1); check(src); store(src); finalize(src) end
function pasted() local dst = fetch(2); check(dst); store(src); finalize(dst) end
