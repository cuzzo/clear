class Example { static void original() { var src = fetch(1); check(src); store(src); finalize(src); } static void pasted() { var dst = fetch(2); check(dst); store(src); finalize(dst); } }
