const std = @import("std");
const CheatHeader = @import("runtime-header.zig");
const CheatLib = CheatHeader.CheatLib;
const Runtime = CheatHeader.Runtime;
const EbrContext = CheatHeader.EbrContext;

// -------------------------------------------------------------------------
// 2. User Types & Functions (Transpiled)
// -------------------------------------------------------------------------
const Env = struct {
    vars: CheatLib.StringMap(Value),
};

const Value_Lambda = struct {
    params: []Value,
    body: *Value,
    envId: u64,
};

const Value = union(enum) {
    Nil: void,
    TrueVal: void,
    FalseVal: void,
    Number: f64,
    Str: []const u8,
    Symbol: []const u8,
    List: []Value,
    Lambda: Value_Lambda,
    NativeFn: []const u8,
    EnvRef: u64,
};

fn boolVal(b: bool) Value {
    
    if (b) {
    return Value{ .TrueVal = {} };
    }
return Value{ .FalseVal = {} };
}


fn isTruthy(v: Value) bool {
    
    if (std.meta.activeTag(v) == .Nil) {
    return false;
    } else if (std.meta.activeTag(v) == .FalseVal) {
    return false;
    } else {
    return true;
    }
return true;
}


fn getSymName(v: Value) []const u8 {
    
    if (std.meta.activeTag(v) == .Symbol) {
    const s = v.Symbol;
    return s;
    } else {
    return @as([]const u8, "");
    }
return @as([]const u8, "");
}


fn getNum(v: Value) f64 {
    
    if (std.meta.activeTag(v) == .Number) {
    const n = v.Number;
    return n;
    } else {
    return 0.0;
    }
return 0.0;
}


fn getStr(v: Value) []const u8 {
    
    if (std.meta.activeTag(v) == .Str) {
    const s = v.Str;
    return s;
    } else {
    return @as([]const u8, "");
    }
return @as([]const u8, "");
}


fn getNativeName(v: Value) []const u8 {
    
    if (std.meta.activeTag(v) == .NativeFn) {
    const s = v.NativeFn;
    return s;
    } else {
    return @as([]const u8, "");
    }
return @as([]const u8, "");
}


fn isList(v: Value) bool {
    
    if (std.meta.activeTag(v) == .List) {
    return true;
    } else {
    return false;
    }
return false;
}


fn listLen(v: Value) i64 {
    
    if (std.meta.activeTag(v) == .List) {
    const items = v.List;
    return CheatLib.len(items);
    } else {
    return 0;
    }
return 0;
}


fn isLambda(v: Value) bool {
    
    if (std.meta.activeTag(v) == .Lambda) {
    return true;
    } else {
    return false;
    }
return false;
}


fn valEqual(a: Value, b: Value) bool {
    
    if (std.meta.activeTag(a) == .Nil) {
    if (std.meta.activeTag(b) == .Nil) {
    return true;
    } else {
    return false;
    }
    } else if (std.meta.activeTag(a) == .TrueVal) {
    if (std.meta.activeTag(b) == .TrueVal) {
    return true;
    } else {
    return false;
    }
    } else if (std.meta.activeTag(a) == .FalseVal) {
    if (std.meta.activeTag(b) == .FalseVal) {
    return true;
    } else {
    return false;
    }
    } else if (std.meta.activeTag(a) == .Number) {
    const na = a.Number;
    if (std.meta.activeTag(b) == .Number) {
    const nb = b.Number;
    return (na == nb);
    } else {
    return false;
    }
    } else if (std.meta.activeTag(a) == .Str) {
    const sa = a.Str;
    if (std.meta.activeTag(b) == .Str) {
    const sb = b.Str;
    return CheatLib.eql(sa, sb);
    } else {
    return false;
    }
    } else if (std.meta.activeTag(a) == .Symbol) {
    const sa = a.Symbol;
    if (std.meta.activeTag(b) == .Symbol) {
    const sb = b.Symbol;
    return CheatLib.eql(sa, sb);
    } else {
    return false;
    }
    } else if (std.meta.activeTag(a) == .List) {
    const la = a.List;
    if (std.meta.activeTag(b) == .List) {
    const lb = b.List;
    if ((CheatLib.len(la) != CheatLib.len(lb))) {
    return false;
    }
var ci: i64 = 0; 


while ((ci < CheatLib.len(la))) {
 if ((valEqual(CheatLib.getAt(la, ci), CheatLib.getAt(lb, ci)) == false)) {
    return false;
    }
ci = (ci + 1);  
}
return true;
    } else {
    return false;
    }
    } else {
    return false;
    }
return false;
}


fn readAtom(rt: *Runtime, token: []const u8) !Value {
    _ = &rt;
    if ((CheatLib.len(token) == 0)) {
    return Value{ .Nil = {} };
    }
if (CheatLib.eql(token, "nil")) {
    return Value{ .Nil = {} };
    }
if (CheatLib.eql(token, "true")) {
    return Value{ .TrueVal = {} };
    }
if (CheatLib.eql(token, "false")) {
    return Value{ .FalseVal = {} };
    }
if (CheatLib.eql(CheatLib.charAt(token, 0), "\"")) {
    return Value{ .Str = try CheatLib.substr(rt.frameAlloc(), token, 1, (CheatLib.len(token) - 2)) };
    }
const n: f64 = (((std.fmt.parseFloat(f64, token) catch null)) orelse (0.0 - 999999.0)); 


if ((n != (0.0 - 999999.0))) {
    return Value{ .Number = n };
    }
return Value{ .Symbol = token };
}


fn prStr(rt: *Runtime, v: Value, readably: bool) anyerror![]const u8 {
    _ = &rt;
    if (std.meta.activeTag(v) == .Nil) {
    return @as([]const u8, "nil");
    } else if (std.meta.activeTag(v) == .TrueVal) {
    return @as([]const u8, "true");
    } else if (std.meta.activeTag(v) == .FalseVal) {
    return @as([]const u8, "false");
    } else if (std.meta.activeTag(v) == .Number) {
    const n = v.Number;
    if ((n == @floor(n))) {
    return try CheatLib.intToString(rt.frameAlloc(), @intFromFloat(n));
    }
return try CheatLib.intToString(rt.frameAlloc(), @intFromFloat(n));
    } else if (std.meta.activeTag(v) == .Str) {
    const s = v.Str;
    if (readably) {
    return try CheatLib.concat(rt.frameAlloc(), try CheatLib.concat(rt.frameAlloc(), "\"", s), "\"");
    }
return s;
    } else if (std.meta.activeTag(v) == .Symbol) {
    const s = v.Symbol;
    return s;
    } else if (std.meta.activeTag(v) == .List) {
    const items = v.List;
    var out: []const u8 = "("; 


var li: i64 = 0; 


while ((li < CheatLib.len(items))) {
 if ((li > 0)) {
    out = try CheatLib.concat(rt.frameAlloc(), out, " "); 
    }
out = @as([]const u8, try CheatLib.concat(rt.frameAlloc(), out, try prStr(rt, CheatLib.getAt(items, li), readably))); 
li = (li + 1);  
rt.checkYield();
}
return @as([]const u8, try CheatLib.concat(rt.frameAlloc(), out, ")"));
    } else if (std.meta.activeTag(v) == .NativeFn) {
    return @as([]const u8, "#<function>");
    } else if (std.meta.activeTag(v) == .Lambda) {
    return @as([]const u8, "#<function>");
    } else if (std.meta.activeTag(v) == .EnvRef) {
    return @as([]const u8, "#<envref>");
    }
return @as([]const u8, "");
}


fn tokenizeToEnv(rt: *Runtime, _m_penv: anytype, str: []const u8) !void {
    _ = &rt;
    var penv = _m_penv; _ = &penv;
    var count: i64 = 0; 


var i: i64 = 0; 


while ((i < CheatLib.len(str))) {
 const c: []const u8 = CheatLib.charAt(str, i); 


if ((((CheatLib.eql(c, " ") or CheatLib.eql(c, ",")) or CheatLib.eql(c, "\n")) or CheatLib.eql(c, "\t"))) {
    i = (i + 1); 
    } else {
    if ((((CheatLib.eql(c, "(") or CheatLib.eql(c, ")")) or CheatLib.eql(c, "[")) or CheatLib.eql(c, "]"))) {
    try penv.put(rt.frameAlloc(), rt.frameAlloc(), try CheatLib.concat(rt.frameAlloc(), "__t", try CheatLib.intToString(rt.frameAlloc(), count)), Value{ .Str = c });
count = (count + 1); 
i = (i + 1); 
    } else {
    if (CheatLib.eql(c, ";")) {
    while (((i < CheatLib.len(str)) and !CheatLib.eql(CheatLib.charAt(str, i), "\n"))) {
 i = (i + 1);  
rt.checkYield();
}
    } else {
    if (CheatLib.eql(c, "\"")) {
    var s: []const u8 = "\""; 


i = (i + 1); 
while (((i < CheatLib.len(str)) and !CheatLib.eql(CheatLib.charAt(str, i), "\""))) {
 if (CheatLib.eql(CheatLib.charAt(str, i), "\\")) {
    s = @as([]const u8, try CheatLib.concat(rt.frameAlloc(), s, CheatLib.charAt(str, i))); 
i = (i + 1); 
if ((i < CheatLib.len(str))) {
    s = @as([]const u8, try CheatLib.concat(rt.frameAlloc(), s, CheatLib.charAt(str, i))); 
i = (i + 1); 
    }
    } else {
    s = @as([]const u8, try CheatLib.concat(rt.frameAlloc(), s, CheatLib.charAt(str, i))); 
i = (i + 1); 
    } 
rt.checkYield();
}
s = try CheatLib.concat(rt.frameAlloc(), s, "\""); 
try penv.put(rt.frameAlloc(), rt.frameAlloc(), try CheatLib.concat(rt.frameAlloc(), "__t", try CheatLib.intToString(rt.frameAlloc(), count)), Value{ .Str = s });
count = (count + 1); 
i = (i + 1); 
    } else {
    var s: []const u8 = ""; 


while ((((((((((((i < CheatLib.len(str)) and !CheatLib.eql(CheatLib.charAt(str, i), " ")) and !CheatLib.eql(CheatLib.charAt(str, i), ",")) and !CheatLib.eql(CheatLib.charAt(str, i), "\n")) and !CheatLib.eql(CheatLib.charAt(str, i), "\t")) and !CheatLib.eql(CheatLib.charAt(str, i), "(")) and !CheatLib.eql(CheatLib.charAt(str, i), ")")) and !CheatLib.eql(CheatLib.charAt(str, i), "[")) and !CheatLib.eql(CheatLib.charAt(str, i), "]")) and !CheatLib.eql(CheatLib.charAt(str, i), "\"")) and !CheatLib.eql(CheatLib.charAt(str, i), ";"))) {
 s = @as([]const u8, try CheatLib.concat(rt.frameAlloc(), s, CheatLib.charAt(str, i))); 
i = (i + 1);  
rt.checkYield();
}
if ((CheatLib.len(@as([]const u8, s)) > 0)) {
    try penv.put(rt.frameAlloc(), rt.frameAlloc(), try CheatLib.concat(rt.frameAlloc(), "__t", try CheatLib.intToString(rt.frameAlloc(), count)), Value{ .Str = s });
count = (count + 1); 
    }
    }
    }
    }
    } 
rt.checkYield();
}
try penv.put(rt.frameAlloc(), rt.frameAlloc(), "__tc", Value{ .Number = @as(f64, @floatFromInt(count)) });
return ;
}


fn getTokenStr(rt: *Runtime, _m_penv: anytype, idx: i64) ![]const u8 {
    _ = &rt;
    var penv = _m_penv; _ = &penv;
    const val = ((penv.get(try CheatLib.concat(rt.frameAlloc(), "__t", try CheatLib.intToString(rt.frameAlloc(), idx)))) orelse Value{ .Nil = {} }); 


return getStr(val);
}


fn readFormEnv(rt: *Runtime, _m_penv: anytype) anyerror!Value {
    _ = &rt;
    var penv = _m_penv; _ = &penv;
    const posVal = ((penv.get("__rp")) orelse Value{ .Number = 0.0 }); 


const tcVal = ((penv.get("__tc")) orelse Value{ .Number = 0.0 }); 


const pos: i64 = @intFromFloat(getNum(posVal)); 


const tc: i64 = @intFromFloat(getNum(tcVal)); 


const tok: []const u8 = try getTokenStr(rt, penv, pos); 


if ((pos >= tc)) {
    return Value{ .Nil = {} };
    }
if ((CheatLib.eql(tok, "(") or CheatLib.eql(tok, "["))) {
    try penv.put(rt.frameAlloc(), rt.frameAlloc(), "__rp", Value{ .Number = @as(f64, @floatFromInt((pos + 1))) });
return try readListEnv(rt, penv);
    }
try penv.put(rt.frameAlloc(), rt.frameAlloc(), "__rp", Value{ .Number = @as(f64, @floatFromInt((pos + 1))) });
return try readAtom(rt, tok);
}


fn readListEnv(rt: *Runtime, _m_penv: anytype) anyerror!Value {
    _ = &rt;
    var penv = _m_penv; _ = &penv;
    var items = std.ArrayListUnmanaged(Value){}; _ = &items;


var listDone: bool = false; 


while ((listDone == false)) {
 const curPosVal = ((penv.get("__rp")) orelse Value{ .Number = 0.0 }); 


const tcVal2 = ((penv.get("__tc")) orelse Value{ .Number = 0.0 }); 


const curPos: i64 = @intFromFloat(getNum(curPosVal)); 


const tc2: i64 = @intFromFloat(getNum(tcVal2)); 


if ((curPos >= tc2)) {
    listDone = true; 
    } else {
    const curTok: []const u8 = try getTokenStr(rt, penv, curPos); 


if ((CheatLib.eql(curTok, ")") or CheatLib.eql(curTok, "]"))) {
    try penv.put(rt.frameAlloc(), rt.frameAlloc(), "__rp", Value{ .Number = @as(f64, @floatFromInt((curPos + 1))) });
listDone = true; 
    } else {
    const item = try readFormEnv(rt, penv); 


try items.append(rt.frameAlloc(), item);
    }
    } 
rt.checkYield();
}
try CheatLib.promoteList(Value, rt, &items);
return Value{ .List = items.items };
}


fn applyNative(rt: *Runtime, name: []const u8, evaled: []Value) anyerror!Value {
    _ = &rt;
    if (CheatLib.eql(name, "+")) {
    return Value{ .Number = (getNum(CheatLib.getAt(evaled, 1)) + getNum(CheatLib.getAt(evaled, 2))) };
    }
if (CheatLib.eql(name, "-")) {
    return Value{ .Number = (getNum(CheatLib.getAt(evaled, 1)) - getNum(CheatLib.getAt(evaled, 2))) };
    }
if (CheatLib.eql(name, "*")) {
    return Value{ .Number = (getNum(CheatLib.getAt(evaled, 1)) * getNum(CheatLib.getAt(evaled, 2))) };
    }
if (CheatLib.eql(name, "/")) {
    return Value{ .Number = (getNum(CheatLib.getAt(evaled, 1)) / getNum(CheatLib.getAt(evaled, 2))) };
    }
if (CheatLib.eql(name, "=")) {
    return boolVal(valEqual(CheatLib.getAt(evaled, 1), CheatLib.getAt(evaled, 2)));
    }
if (CheatLib.eql(name, "<")) {
    return boolVal((getNum(CheatLib.getAt(evaled, 1)) < getNum(CheatLib.getAt(evaled, 2))));
    }
if (CheatLib.eql(name, ">")) {
    return boolVal((getNum(CheatLib.getAt(evaled, 1)) > getNum(CheatLib.getAt(evaled, 2))));
    }
if (CheatLib.eql(name, "<=")) {
    return boolVal((getNum(CheatLib.getAt(evaled, 1)) <= getNum(CheatLib.getAt(evaled, 2))));
    }
if (CheatLib.eql(name, ">=")) {
    return boolVal((getNum(CheatLib.getAt(evaled, 1)) >= getNum(CheatLib.getAt(evaled, 2))));
    }
if (CheatLib.eql(name, "list")) {
    var litems = std.ArrayListUnmanaged(Value){}; _ = &litems;


var li: i64 = 1; 


while ((li < CheatLib.len(evaled))) {
 try litems.append(rt.frameAlloc(), CheatLib.getAt(evaled, li));
li = (li + 1);  
rt.checkYield();
}
try CheatLib.promoteList(Value, rt, &litems);
return Value{ .List = litems.items };
    }
if (CheatLib.eql(name, "list?")) {
    return boolVal(isList(CheatLib.getAt(evaled, 1)));
    }
if (CheatLib.eql(name, "empty?")) {
    return boolVal((listLen(CheatLib.getAt(evaled, 1)) == 0));
    }
if (CheatLib.eql(name, "count")) {
    return Value{ .Number = @as(f64, @floatFromInt(listLen(CheatLib.getAt(evaled, 1)))) };
    }
if (CheatLib.eql(name, "not")) {
    return boolVal((isTruthy(CheatLib.getAt(evaled, 1)) == false));
    }
if (CheatLib.eql(name, "prn")) {
    std.debug.print("{s}\n", .{try prStr(rt, CheatLib.getAt(evaled, 1), true)});
return Value{ .Nil = {} };
    }
return Value{ .Nil = {} };
}


fn envGet(envId: u64, name: []const u8, _m_pool: anytype) Value {
    var pool = _m_pool; _ = &pool;
    const val = ((pool.get(envId).?.vars.get(name)) orelse Value{ .Number = (0.0 - 777777.0) }); 


if (std.meta.activeTag(val) == .Number) {
    const n = val.Number;
    if ((n == (0.0 - 777777.0))) {
    const parentVal = ((pool.get(envId).?.vars.get("__p")) orelse Value{ .Nil = {} }); 


if (std.meta.activeTag(parentVal) == .EnvRef) {
    const pid = parentVal.EnvRef;
    return envGet(pid, name, pool);
    } else {
    return Value{ .Nil = {} };
    }
    }
return val;
    } else {
    return val;
    }
return Value{ .Nil = {} };
}


fn eval(rt: *Runtime, ast: Value, envId: u64, _m_pool: anytype) anyerror!Value {
    _ = &rt;
    var pool = _m_pool; _ = &pool;
    if (std.meta.activeTag(ast) == .Symbol) {
    const sym = ast.Symbol;
    return envGet(envId, sym, pool);
    } else if (std.meta.activeTag(ast) == .List) {
    const items = ast.List;
    return try evalList(rt, (if (@hasField(@TypeOf(items), "items")) items.items else items), envId, pool);
    } else if (std.meta.activeTag(ast) == .Nil) {
    return ast;
    } else if (std.meta.activeTag(ast) == .TrueVal) {
    return ast;
    } else if (std.meta.activeTag(ast) == .FalseVal) {
    return ast;
    } else if (std.meta.activeTag(ast) == .Number) {
    return ast;
    } else if (std.meta.activeTag(ast) == .Str) {
    return ast;
    } else if (std.meta.activeTag(ast) == .NativeFn) {
    return ast;
    } else if (std.meta.activeTag(ast) == .Lambda) {
    return ast;
    } else if (std.meta.activeTag(ast) == .EnvRef) {
    return ast;
    }
return ast;
}


fn evalList(rt: *Runtime, items: []Value, envId: u64, _m_pool: anytype) anyerror!Value {
    _ = &rt;
    var pool = _m_pool; _ = &pool;
    if ((CheatLib.len(items) == 0)) {
    return Value{ .List = items };
    }
const formName: []const u8 = getSymName(CheatLib.getAt(items, 0)); 


if (CheatLib.eql(formName, "def!")) {
    const defName: []const u8 = getSymName(CheatLib.getAt(items, 1)); 


const val = try eval(rt, CheatLib.getAt(items, 2), envId, pool); 


try pool.get(envId).?.vars.put(rt.frameAlloc(), rt.frameAlloc(), defName, val);
const result = ((pool.get(envId).?.vars.get(defName)) orelse Value{ .Nil = {} }); 


return result;
    } else {
    if (CheatLib.eql(formName, "let*")) {
    var letResult = Value{ .Nil = {} }; 


if (std.meta.activeTag(CheatLib.getAt(items, 1)) == .List) {
    const binds = CheatLib.getAt(items, 1).List;
    const letId = try pool.insert(rt.heapAlloc(), Env{ .vars = @as(CheatLib.StringMap(Value), CheatLib.StringMap(Value){ .alloc = rt.frameAlloc() }) }); 


try pool.get(letId).?.vars.put(rt.frameAlloc(), rt.frameAlloc(), "__p", Value{ .EnvRef = envId });
var bi: i64 = 0; 


while ((bi < CheatLib.len(binds))) {
 const bName: []const u8 = getSymName(CheatLib.getAt(binds, bi)); 


const bVal = try eval(rt, CheatLib.getAt(binds, (bi + 1)), letId, pool); 


try pool.get(letId).?.vars.put(rt.frameAlloc(), rt.frameAlloc(), bName, bVal);
bi = (bi + 2);  
rt.checkYield();
}
letResult = try eval(rt, CheatLib.getAt(items, 2), letId, pool); 
    } else {
    {}
    }
return letResult;
    } else {
    if (CheatLib.eql(formName, "fn*")) {
    if (std.meta.activeTag(CheatLib.getAt(items, 1)) == .List) {
    const pnames = CheatLib.getAt(items, 1).List;
    return Value{ .Lambda = Value_Lambda{ .params = pnames, .body = blk_body: {
    const __p = try rt.heapAlloc().create(Value);
    __p.* = CheatLib.getAt(items, 2);
    break :blk_body __p;
}, .envId = envId } };
    } else {
    return Value{ .Nil = {} };
    }
return Value{ .Nil = {} };
    } else {
    if (CheatLib.eql(formName, "do")) {
    var doResult = Value{ .Nil = {} }; 


var di: i64 = 1; 


while ((di < CheatLib.len(items))) {
 doResult = try eval(rt, CheatLib.getAt(items, di), envId, pool); 
di = (di + 1);  
rt.checkYield();
}
return doResult;
    } else {
    if (CheatLib.eql(formName, "if")) {
    const cond = try eval(rt, CheatLib.getAt(items, 1), envId, pool); 


const truthy: bool = isTruthy(cond); 


if (truthy) {
    return try eval(rt, CheatLib.getAt(items, 2), envId, pool);
    } else {
    if ((CheatLib.len(items) > 3)) {
    return try eval(rt, CheatLib.getAt(items, 3), envId, pool);
    }
return Value{ .Nil = {} };
    }
    } else {
    var evaled = std.ArrayListUnmanaged(Value){}; _ = &evaled;
defer evaled.deinit(rt.frameAlloc());


var ei: i64 = 0; 


while ((ei < CheatLib.len(items))) {
 try evaled.append(rt.frameAlloc(), try eval(rt, CheatLib.getAt(items, ei), envId, pool));
ei = (ei + 1);  
rt.checkYield();
}
const f = CheatLib.getAt(evaled, 0); 


if (isLambda(f)) {
    return try evalLambdaCall(rt, f, (if (@hasField(@TypeOf(evaled), "items")) evaled.items else evaled), pool);
    } else {
    const fname: []const u8 = getNativeName(f); 


if ((CheatLib.len(fname) > 0)) {
    return try applyNative(rt, fname, (if (@hasField(@TypeOf(evaled), "items")) evaled.items else evaled));
    }
return Value{ .Nil = {} };
    }
    }
    }
    }
    }
    }
}


fn evalLambdaCall(rt: *Runtime, f: Value, evaled: []Value, _m_pool: anytype) anyerror!Value {
    _ = &rt;
    var pool = _m_pool; _ = &pool;
    var result = Value{ .Nil = {} }; 


if (std.meta.activeTag(f) == .Lambda) {
    const lam = f.Lambda;
    const callId = try pool.insert(rt.heapAlloc(), Env{ .vars = @as(CheatLib.StringMap(Value), CheatLib.StringMap(Value){ .alloc = rt.frameAlloc() }) }); 


try pool.get(callId).?.vars.put(rt.frameAlloc(), rt.frameAlloc(), "__p", Value{ .EnvRef = lam.envId });
var pi: i64 = 0; 


while ((pi < CheatLib.len(lam.params))) {
 const pname: []const u8 = getSymName(CheatLib.getAt(lam.params, pi)); 


try pool.get(callId).?.vars.put(rt.frameAlloc(), rt.frameAlloc(), pname, CheatLib.getAt(evaled, (pi + 1)));
pi = (pi + 1);  
rt.checkYield();
}
result = try eval(rt, lam.body.*, callId, pool); 
    } else {
    {}
    }
return result;
}


fn runTest(rt: *Runtime, input: []const u8, envId: u64, _m_pool: anytype, _m_penv: anytype) anyerror!Value {
    _ = &rt;
    var pool = _m_pool; _ = &pool;
    var penv = _m_penv; _ = &penv;
    try tokenizeToEnv(rt, penv, input);
try penv.put(rt.frameAlloc(), rt.frameAlloc(), "__rp", Value{ .Number = 0.0 });
const ast = try readFormEnv(rt, penv); 


return try eval(rt, ast, envId, pool);
}


fn cheatMain(rt: *Runtime) !void {
    _ = &rt;
    var pool = CheatLib.Pool(Env){}; _ = &pool;
var pool_moved = false; _ = &pool_moved;
defer if (!pool_moved) pool.deinit(rt.heapAlloc());


var penv = @as(CheatLib.StringMap(Value), CheatLib.StringMap(Value){ .alloc = rt.frameAlloc() }); _ = &penv;
defer penv.deinit(rt.heapAlloc(), rt.heapAlloc());


const rootId = try pool.insert(rt.heapAlloc(), Env{ .vars = @as(CheatLib.StringMap(Value), CheatLib.StringMap(Value){ .alloc = rt.frameAlloc() }) }); 


try pool.get(rootId).?.vars.put(rt.frameAlloc(), rt.frameAlloc(), "+", Value{ .NativeFn = "+" });
try pool.get(rootId).?.vars.put(rt.frameAlloc(), rt.frameAlloc(), "-", Value{ .NativeFn = "-" });
try pool.get(rootId).?.vars.put(rt.frameAlloc(), rt.frameAlloc(), "*", Value{ .NativeFn = "*" });
try pool.get(rootId).?.vars.put(rt.frameAlloc(), rt.frameAlloc(), "/", Value{ .NativeFn = "/" });
try pool.get(rootId).?.vars.put(rt.frameAlloc(), rt.frameAlloc(), "=", Value{ .NativeFn = "=" });
try pool.get(rootId).?.vars.put(rt.frameAlloc(), rt.frameAlloc(), "<", Value{ .NativeFn = "<" });
try pool.get(rootId).?.vars.put(rt.frameAlloc(), rt.frameAlloc(), ">", Value{ .NativeFn = ">" });
try pool.get(rootId).?.vars.put(rt.frameAlloc(), rt.frameAlloc(), "<=", Value{ .NativeFn = "<=" });
try pool.get(rootId).?.vars.put(rt.frameAlloc(), rt.frameAlloc(), ">=", Value{ .NativeFn = ">=" });
try pool.get(rootId).?.vars.put(rt.frameAlloc(), rt.frameAlloc(), "list", Value{ .NativeFn = "list" });
try pool.get(rootId).?.vars.put(rt.frameAlloc(), rt.frameAlloc(), "list?", Value{ .NativeFn = "list?" });
try pool.get(rootId).?.vars.put(rt.frameAlloc(), rt.frameAlloc(), "empty?", Value{ .NativeFn = "empty?" });
try pool.get(rootId).?.vars.put(rt.frameAlloc(), rt.frameAlloc(), "count", Value{ .NativeFn = "count" });
try pool.get(rootId).?.vars.put(rt.frameAlloc(), rt.frameAlloc(), "not", Value{ .NativeFn = "not" });
try pool.get(rootId).?.vars.put(rt.frameAlloc(), rt.frameAlloc(), "prn", Value{ .NativeFn = "prn" });
var result = try runTest(rt, (if (@hasField(@TypeOf(@as([]const u8, "(+ 1 2)")), "items")) @as([]const u8, "(+ 1 2)").items else @as([]const u8, "(+ 1 2)")), rootId, &pool, &penv); 


std.debug.print("{s}\n", .{try prStr(rt, result, true)});
CheatLib.assert(CheatLib.eql(try prStr(rt, result, true), "3"), "test 1: (+ 1 2) = 3");
result = try runTest(rt, (if (@hasField(@TypeOf(@as([]const u8, "(def! a 10)")), "items")) @as([]const u8, "(def! a 10)").items else @as([]const u8, "(def! a 10)")), rootId, &pool, &penv); 
std.debug.print("{s}\n", .{try prStr(rt, result, true)});
CheatLib.assert(CheatLib.eql(try prStr(rt, result, true), "10"), "test 2");
result = try runTest(rt, (if (@hasField(@TypeOf(@as([]const u8, "(def! f (fn* (x) (+ x a)))")), "items")) @as([]const u8, "(def! f (fn* (x) (+ x a)))").items else @as([]const u8, "(def! f (fn* (x) (+ x a)))")), rootId, &pool, &penv); 
std.debug.print("{s}\n", .{try prStr(rt, result, true)});
CheatLib.assert(CheatLib.eql(try prStr(rt, result, true), "#<function>"), "test 3");
result = try runTest(rt, (if (@hasField(@TypeOf(@as([]const u8, "(f 5)")), "items")) @as([]const u8, "(f 5)").items else @as([]const u8, "(f 5)")), rootId, &pool, &penv); 
std.debug.print("{s}\n", .{try prStr(rt, result, true)});
CheatLib.assert(CheatLib.eql(try prStr(rt, result, true), "15"), "test 4");
result = try runTest(rt, (if (@hasField(@TypeOf(@as([]const u8, "(let* (b 2 c 3) (+ b c))")), "items")) @as([]const u8, "(let* (b 2 c 3) (+ b c))").items else @as([]const u8, "(let* (b 2 c 3) (+ b c))")), rootId, &pool, &penv); 
std.debug.print("{s}\n", .{try prStr(rt, result, true)});
CheatLib.assert(CheatLib.eql(try prStr(rt, result, true), "5"), "test 5");
result = try runTest(rt, (if (@hasField(@TypeOf(@as([]const u8, "(if true 7 8)")), "items")) @as([]const u8, "(if true 7 8)").items else @as([]const u8, "(if true 7 8)")), rootId, &pool, &penv); 
std.debug.print("{s}\n", .{try prStr(rt, result, true)});
CheatLib.assert(CheatLib.eql(try prStr(rt, result, true), "7"), "test 6");
result = try runTest(rt, (if (@hasField(@TypeOf(@as([]const u8, "(if false 7 8)")), "items")) @as([]const u8, "(if false 7 8)").items else @as([]const u8, "(if false 7 8)")), rootId, &pool, &penv); 
std.debug.print("{s}\n", .{try prStr(rt, result, true)});
CheatLib.assert(CheatLib.eql(try prStr(rt, result, true), "8"), "test 7");
result = try runTest(rt, (if (@hasField(@TypeOf(@as([]const u8, "(if nil 7 8)")), "items")) @as([]const u8, "(if nil 7 8)").items else @as([]const u8, "(if nil 7 8)")), rootId, &pool, &penv); 
std.debug.print("{s}\n", .{try prStr(rt, result, true)});
CheatLib.assert(CheatLib.eql(try prStr(rt, result, true), "8"), "test 8");
result = try runTest(rt, (if (@hasField(@TypeOf(@as([]const u8, "(do (def! d 6) 7 (+ d 8))")), "items")) @as([]const u8, "(do (def! d 6) 7 (+ d 8))").items else @as([]const u8, "(do (def! d 6) 7 (+ d 8))")), rootId, &pool, &penv); 
std.debug.print("{s}\n", .{try prStr(rt, result, true)});
CheatLib.assert(CheatLib.eql(try prStr(rt, result, true), "14"), "test 9");
result = try runTest(rt, (if (@hasField(@TypeOf(@as([]const u8, "(= 1 1)")), "items")) @as([]const u8, "(= 1 1)").items else @as([]const u8, "(= 1 1)")), rootId, &pool, &penv); 
std.debug.print("{s}\n", .{try prStr(rt, result, true)});
CheatLib.assert(CheatLib.eql(try prStr(rt, result, true), "true"), "test 10");
result = try runTest(rt, (if (@hasField(@TypeOf(@as([]const u8, "(= 1 2)")), "items")) @as([]const u8, "(= 1 2)").items else @as([]const u8, "(= 1 2)")), rootId, &pool, &penv); 
std.debug.print("{s}\n", .{try prStr(rt, result, true)});
CheatLib.assert(CheatLib.eql(try prStr(rt, result, true), "false"), "test 11");
result = try runTest(rt, (if (@hasField(@TypeOf(@as([]const u8, "(> 2 1)")), "items")) @as([]const u8, "(> 2 1)").items else @as([]const u8, "(> 2 1)")), rootId, &pool, &penv); 
std.debug.print("{s}\n", .{try prStr(rt, result, true)});
CheatLib.assert(CheatLib.eql(try prStr(rt, result, true), "true"), "test 12");
result = try runTest(rt, (if (@hasField(@TypeOf(@as([]const u8, "(< 1 2)")), "items")) @as([]const u8, "(< 1 2)").items else @as([]const u8, "(< 1 2)")), rootId, &pool, &penv); 
std.debug.print("{s}\n", .{try prStr(rt, result, true)});
CheatLib.assert(CheatLib.eql(try prStr(rt, result, true), "true"), "test 13");
result = try runTest(rt, (if (@hasField(@TypeOf(@as([]const u8, "(list 1 2 3)")), "items")) @as([]const u8, "(list 1 2 3)").items else @as([]const u8, "(list 1 2 3)")), rootId, &pool, &penv); 
std.debug.print("{s}\n", .{try prStr(rt, result, false)});
CheatLib.assert(CheatLib.eql(try prStr(rt, result, false), "(1 2 3)"), "test 14");
result = try runTest(rt, (if (@hasField(@TypeOf(@as([]const u8, "(count (list 1 2 3))")), "items")) @as([]const u8, "(count (list 1 2 3))").items else @as([]const u8, "(count (list 1 2 3))")), rootId, &pool, &penv); 
std.debug.print("{s}\n", .{try prStr(rt, result, true)});
CheatLib.assert(CheatLib.eql(try prStr(rt, result, true), "3"), "test 15");
result = try runTest(rt, (if (@hasField(@TypeOf(@as([]const u8, "(empty? (list))")), "items")) @as([]const u8, "(empty? (list))").items else @as([]const u8, "(empty? (list))")), rootId, &pool, &penv); 
std.debug.print("{s}\n", .{try prStr(rt, result, true)});
CheatLib.assert(CheatLib.eql(try prStr(rt, result, true), "true"), "test 16");
result = try runTest(rt, (if (@hasField(@TypeOf(@as([]const u8, "(not false)")), "items")) @as([]const u8, "(not false)").items else @as([]const u8, "(not false)")), rootId, &pool, &penv); 
std.debug.print("{s}\n", .{try prStr(rt, result, true)});
CheatLib.assert(CheatLib.eql(try prStr(rt, result, true), "true"), "test 17");
result = try runTest(rt, (if (@hasField(@TypeOf(@as([]const u8, "(def! sumdown (fn* (n) (if (> n 0) (+ n (sumdown (- n 1))) 0)))")), "items")) @as([]const u8, "(def! sumdown (fn* (n) (if (> n 0) (+ n (sumdown (- n 1))) 0)))").items else @as([]const u8, "(def! sumdown (fn* (n) (if (> n 0) (+ n (sumdown (- n 1))) 0)))")), rootId, &pool, &penv); 
std.debug.print("{s}\n", .{try prStr(rt, result, true)});
CheatLib.assert(CheatLib.eql(try prStr(rt, result, true), "#<function>"), "test 18");
result = try runTest(rt, (if (@hasField(@TypeOf(@as([]const u8, "(sumdown 6)")), "items")) @as([]const u8, "(sumdown 6)").items else @as([]const u8, "(sumdown 6)")), rootId, &pool, &penv); 
std.debug.print("{s}\n", .{try prStr(rt, result, true)});
CheatLib.assert(CheatLib.eql(try prStr(rt, result, true), "21"), "test 19");
result = try runTest(rt, (if (@hasField(@TypeOf(@as([]const u8, "(def! fib (fn* (n) (if (<= n 1) 1 (+ (fib (- n 1)) (fib (- n 2))))))")), "items")) @as([]const u8, "(def! fib (fn* (n) (if (<= n 1) 1 (+ (fib (- n 1)) (fib (- n 2))))))").items else @as([]const u8, "(def! fib (fn* (n) (if (<= n 1) 1 (+ (fib (- n 1)) (fib (- n 2))))))")), rootId, &pool, &penv); 
std.debug.print("{s}\n", .{try prStr(rt, result, true)});
CheatLib.assert(CheatLib.eql(try prStr(rt, result, true), "#<function>"), "test 20");
result = try runTest(rt, (if (@hasField(@TypeOf(@as([]const u8, "(fib 4)")), "items")) @as([]const u8, "(fib 4)").items else @as([]const u8, "(fib 4)")), rootId, &pool, &penv); 
std.debug.print("{s}\n", .{try prStr(rt, result, true)});
CheatLib.assert(CheatLib.eql(try prStr(rt, result, true), "5"), "test 21");
std.debug.print("{s}\n", .{"All 21 Mal interpreter tests PASSED!"});
}


// -------------------------------------------------------------------------
// 3. Main Entry (Test Harness)
// -------------------------------------------------------------------------
// Multi-threaded bootstrapper.
//
// Spawns N schedulers (N = CPU count), each with its own io_uring ring and
// epoll instance.  The main thread runs Scheduler 0 (which owns cheatMain);
// N-1 worker threads run idle schedulers that steal work via the existing
// Chase-Lev work-stealing deque in RunQueue.
//
// Shared state (heap-allocated, outlives all threads):
//   - GPA allocator
//   - EbrContext  (thread-safe — has its own registry_lock)
//   - StackPool   (thread-safe — slab allocator with atomic free lists)
//   - shutdown    (atomic bool — signals workers to exit after cheatMain)
//
// Per-thread:
//   - Scheduler   (owns io_uring ring + epoll + ready_queue + inbox)
//   - active_scheduler threadlocal (set before sched.run)

pub fn main() !void {
    // 1. Setup Allocator
    // Compile-time flag: USE_C_ALLOCATOR = true uses libc malloc (thread-safe,
    // per-thread arenas in glibc/musl). Otherwise uses GPA for leak detection.
    // Multi-threaded builds should always set USE_C_ALLOCATOR.
    const use_c_alloc = if (@hasDecl(@import("root"), "USE_C_ALLOCATOR")) @import("root").USE_C_ALLOCATOR else false;

    var gpa = if (use_c_alloc) {} else std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    defer if (!use_c_alloc) {
        _ = gpa.deinit();
    };
    const allocator = if (use_c_alloc) std.heap.c_allocator else gpa.allocator();

    // 2. Setup Contexts
    var global_ctx = EbrContext{};
    defer global_ctx.deinit(allocator);

    // 3. Init Runtime (4 MB frame arena for the main fiber).
    var rt = try Runtime.init(allocator, 4 * 1024 * 1024, &global_ctx);
    defer rt.deinit();
    rt.wireAllocator();

    // Register the main runtime's ThreadLocalEbr with the global
    // EbrContext so EbrContext.reclaim() observes its pinned epoch
    // during Versioned.read() critical sections. Without this, reclaim
    // can advance past a still-pinned reader's local_epoch -> UAF.
    // BG fibers get their own per-task ThreadLocalEbr registered by the
    // scheduler (see drainChannels.Spawn); main runtime registers here.
    try global_ctx.register(allocator, rt.ebr);
    defer global_ctx.unregister(rt.ebr);

    // 4. Shared infrastructure
    const fm = @import("fiber-memory.zig");
    const fp = @import("scheduler.zig");
    var stack_pool = fm.StackPool.init(allocator);
    defer stack_pool.deinit();

    // Global shutdown flag — workers check this each loop iteration.
    var shutdown = std.atomic.Value(bool).init(false);

    // 5. Determine thread count.
    //    CLEAR_THREADS=N overrides; default = 1 (single scheduler, zero overhead).
    //    On machines with many cores + large workloads, set CLEAR_THREADS=0 (auto)
    //    or CLEAR_THREADS=N to spawn N-1 worker schedulers.
    const num_workers = blk: {
        if (std.c.getenv("CLEAR_THREADS")) |env_ptr| {
            const n = std.fmt.parseInt(usize, std.mem.span(env_ptr), 10) catch 1;
            if (n == 0) {
                // Auto: use all CPUs
                const cpus = std.Thread.getCpuCount() catch 1;
                break :blk if (cpus > 1) cpus - 1 else 0;
            }
            break :blk if (n > 1) n - 1 else 0;
        }
        break :blk @as(usize, 0); // Default: single scheduler
    };

    // 6. Spawn worker schedulers.
    const WorkerCtx = struct {
        allocator: std.mem.Allocator,
        global_ctx: *EbrContext,
        stack_pool: *fm.StackPool,
        shutdown: *std.atomic.Value(bool),
    };
    var worker_ctx = WorkerCtx{
        .allocator = allocator,
        .global_ctx = &global_ctx,
        .stack_pool = &stack_pool,
        .shutdown = &shutdown,
    };

    const workerMain = struct {
        fn run(ctx: *WorkerCtx) void {
            var worker_sched = fp.Scheduler.init(ctx.allocator, ctx.global_ctx, ctx.stack_pool) catch return;
            defer worker_sched.deinit();
            worker_sched.shutdown_on_idle = false; // stay alive until explicit shutdown
            worker_sched.global_shutdown = ctx.shutdown;
            fp.active_scheduler = &worker_sched;
            fp.scheduler_running = true;
            worker_sched.run();
            fp.scheduler_running = false;
        }
    }.run;

    var workers: [64]std.Thread = undefined;
    for (0..num_workers) |i| {
        workers[i] = std.Thread.spawn(.{}, workerMain, .{&worker_ctx}) catch break;
    }

    // Wait for all workers to register before starting main scheduler.
    // This prevents ensureOwnership from seeing partial scheduler state.
    if (num_workers > 0) {
        while (fp.global_registry.count() < num_workers) {
            std.posix.nanosleep(0, 1 * std.time.ns_per_ms);
        }
    }

    // 7. Main scheduler (runs on the main thread).
    var sched = try fp.Scheduler.init(allocator, &global_ctx, &stack_pool);
    defer {
        sched.deinit();
        fp.global_registry.deinit(allocator);
    }
    sched.global_shutdown = &shutdown;
    fp.active_scheduler = &sched;
    fp.scheduler_running = true;

    // 8. Submit cheatMain as a fiber on the main scheduler.
    const MainRunner = struct {
        outer_rt: *Runtime,
        fn run(_: *anyopaque, raw_args: ?*anyopaque) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(raw_args.?));
            const result = try cheatMain(self.outer_rt);
            const RType = @TypeOf(result);
            if (@typeInfo(RType) == .pointer) {
                CheatLib.free(self.outer_rt, result);
            }
        }
    };
    var main_runner = MainRunner{ .outer_rt = &rt };
    try sched.submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(CheatHeader.TaskFn, @ptrCast(&MainRunner.run)),
        &main_runner,
        .{ .stack_size = .Large },
    );
    sched.run();

    // 9. Signal workers to shut down and join.
    shutdown.store(true, .release);
    fp.global_registry.notifyAll(); // wake workers from epoll_wait
    for (0..num_workers) |i| {
        workers[i].join();
    }
}

