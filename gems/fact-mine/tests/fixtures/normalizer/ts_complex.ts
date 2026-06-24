const fn = (x: number, y: number): number => x + y;
interface X {
  a: number;
}
class Y implements X {
  a: number = 1;
  constructor(public b: string) {}
}
const z = cond ? true : false;
switch(z) {
  case true: break;
  default: break;
}
try { throw new Error(); } catch (e) { } finally { }
