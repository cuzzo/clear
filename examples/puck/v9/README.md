# The V9 Implementation - Strings Are Arrays

V9 finishes the VM. Two related additions:

1. **Strings become arrays of codepoints.** The special "scalar string payload" we introduced in V5 goes away. Every heap entry is now an array. One representation, one allocator, one release path.
2. **Three small VM additions surface this generality to user code:** `ARRAY_LEN` (length of any heap value), `LEN(x)` source-level builtin, and a `SYSCALL` dispatch table for stdin / file I/O so Puck programs can do real work.

That's it. The VM is essentially done. Everything downstream — a string library, integer↔string conversion, even a Puck-in-Puck compiler — is now expressible in Puck itself.

---

## The Program

See [example.puck](example.puck). It defines `reverse(s)` in pure Puck using `LEN` and indexed access:

```pascal
PROCEDURE reverse(s);
  n := LEN(s);
  result := ARRAY(n);
  i := 0;
  WHILE(i < n) DO
    result[i] := s[n - i - 1];
    i := i + 1;
  END;
  RETURN result;
END;
```

`s` is just an array of codepoints. `LEN(s)` returns 4 for `"puck"`. `s[i]` returns one codepoint (an integer). `result` is a new array we build by walking `s` backwards. The procedure returns the heap ref to the new array; the caller prints it with `SYSCALL(1, ...)`, which packs the codepoints back into a string.

Output:

```text
OUTPUT: kcup
OUTPUT: 104
OUTPUT: 105
```

The `104` and `105` come from `print_char_codes("hi")` — proof that you really can poke at individual characters now.

Run:

```bash
ruby examples/puck/v9/vm.rb
```

---

## Generalizing Strings to Arrays

This is the unification we've been pointing at since V5.

**V5 introduced a heap.** Heap entries held strings. The `HeapValue.value` field was a Ruby `String`. Allocation: `allocate_string("hello")`. Display: read the string out and `puts` it.

**V8 added arrays.** Heap entries could *also* hold an Array of values (cells for `VAR` refs, longer arrays for `ARRAY(N)`). The `HeapValue.value` field became polymorphic — either a `String` or an `Array`.

By V8 we had two heap shapes for what was conceptually one mechanism: "refcounted heap-allocated values." The `release` recursion handled the array case (peer into the payload, release nested refs); strings short-circuited because they couldn't contain refs.

**V9 collapses the two shapes.** A string `"hello"` is allocated as `[104, 101, 108, 108, 111]` — codepoints, in an Array. The `allocate_string` path becomes `allocate_codepoints(value.codepoints)`, which just delegates to V8's `allocate_cells`. There is no longer a special string shape on the heap.

```ruby
# V8                                # V9
def allocate_string(value)          def allocate_codepoints(str)
  HeapValue.new(value, 1)             allocate_cells(str.codepoints)
end                                 end
```

The Ruby `puts` side is the symmetric pack:

```ruby
def display(value)
  return value unless value.is_a?(HeapRef)
  @heap[value.id].value.pack("U*")  # codepoints -> string
end
```

`Array#pack("U*")` turns the codepoint array back into a UTF-8 string. For ASCII (which is the subset we care about for self-hosting), this is exact and lossless.

**One consequence:** `release`'s recursion is no longer "if it's an Array." It's always. Every heap payload is now an Array, including strings — which is fine because strings hold codepoint integers (no nested refs to release). The `if payload.is_a?(Array)` guard from V8 goes away.

---

## `ARRAY_LEN` and `LEN(x)`

Now that strings are arrays, "string length" and "array length" are the same operation. One new VM op:

```text
ARRAY_LEN
  pop ref
  push @heap[ref.id].value.length
  release ref
```

And one builtin in source:

```pascal
LEN(s)        # works on strings AND arrays — same op
LEN(nums)     # also LEN
```

The parser sees `LEN(expr)` and emits an `:Length` expression node. The compiler lowers it to "compile the expression, then `ARRAY_LEN`." That's the entire end-to-end addition: ~10 lines across parser + compiler + VM.

---

## SYSCALLs: Real I/O

We promoted SYSCALL to a small dispatch table. Each ID is one host primitive:

| ID | Effect | Stack before | Stack after |
|---|---|---|---|
| 1 | `puts` value (the existing print) | `[value]` | `[]` |
| 2 | `INPUT()` — read a line from stdin | `[]` | `[string_ref]` |
| 3 | open file by name; push integer handle | `[name_ref]` | `[handle]` |
| 4 | read a line from open file | `[handle]` | `[string_ref]` or `[0]` at EOF |
| 5 | close open file | `[handle]` | `[]` |

`INPUT()` has its own source-level form (an expression) because it's the most common one. The others can be called as ordinary procedures if we add stubs to `core.puck`, but they're not exercised by the V9 demo.

```ruby
def handle_syscall(id, stack)
  case id
  when 1 then ...
  when 2 then stack.push(allocate_codepoints($stdin.gets&.chomp || ""))
  when 3 then @files << File.open(display(stack.pop), "r"); stack.push(@files.length - 1)
  when 4 then handle = stack.pop; line = @files[handle].gets
                stack.push(line.nil? ? 0 : allocate_codepoints(line.chomp))
  when 5 then @files[stack.pop].close
  end
end
```

Ruby handles cross-platform: `gets`, `File.open`, `File.gets`, `File.close` all work on Linux, macOS, and Windows without changes. Adding a new syscall is ~5 lines.

---

## What We Can Now Write in Puck

After V9, the value model is exactly **integers and arrays**. The standard library — string functions, int↔string conversion, anything else — is just Puck procedures over those primitives.

`equals`, `concat`, `substring`, `indexOf` are loops with `LEN` and array indexing.

`intToString` is divmod 10 plus appending digit codepoints to a buffer.

`stringToInt` is reading codepoints in a loop, subtracting `'0'`, accumulating.

A tokenizer reads `INPUT()`, walks the codepoint array, recognizes keywords, builds tokens. A parser walks tokens, builds AST nodes (records-as-arrays, via macros). A compiler walks AST, emits bytecodes.

All of that lives in `core.puck` and `compiler.puck` — files alongside this tutorial, written in Puck.

---

## V10 Preview

V9 is the last time the Ruby VM changes. V10 takes the same bytecode shape and reimplements the VM in C for speed, with a profiling lesson showing how to identify what the Ruby VM spent its time on. After V10 the tutorial ends. The Puck source for the standard library and the self-hosted compiler ships alongside the tutorial as plain files, not as new versions.
