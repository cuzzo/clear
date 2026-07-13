# Modules & Build System

CLEAR uses a simple, explicit module system based on the `REQUIRE` keyword. It separates code into **Files**, **Packages**, and **Native Modules**.

## REQUIRE — Importing Code

Importing a CLEAR module makes its `PUB` and package-private symbols available under a namespace.

### Local File Imports

Use a relative path string to import files in your own project:

```ruby clear illustrative
REQUIRE "math_utils.clear";

FN main() RETURNS Void ->
    res = math_utils.add(10, 20);
END
```

### Package Imports

Use the `pkg:` prefix to import registered libraries:

```ruby clear illustrative
REQUIRE "pkg:geometry";

FN main() RETURNS Void ->
    p = geometry.Point{ x: 1, y: 2 };
END
```

### Aliasing (AS)

You can rename any import to avoid collisions:

```ruby clear illustrative
REQUIRE "math_utils.clear" AS m;
REQUIRE "pkg:geometry" AS geo;

FN main() RETURNS Void ->
    sq = m.square(geo.distance(p1, p2));
END
```

---

## Visibility

CLEAR enforces three levels of visibility. Access control is checked at compile-time by the semantic annotator.

| Keyword | Level | Visibility |
|---------|-------|------------|
| `PRIVATE` | File Private | Only accessible within the `.clear` file where it is defined. |
| *(None)* | Package Private | Accessible to any file in the **same directory**. |
| `PUB` | Public | Accessible to any file that `REQUIRE`s this module or package. |

### Example

```ruby clear illustrative
# internal_helper.clear

PRIVATE FN secret_calc() RETURNS Int64 -> ... END

FN package_helper() RETURNS Int64 ->
    RETURN secret_calc();  # OK: same file
END

PUB FN public_api() RETURNS Int64 ->
    RETURN package_helper(); # OK: same package
END
```

```ruby clear illustrative
# main.clear
REQUIRE "internal_helper.clear";

FN main() RETURNS Void ->
    internal_helper.public_api();     # OK: PUB
    internal_helper.package_helper();  # OK: same directory
    # internal_helper.secret_calc();  -- ERROR: PRIVATE
END
```

### Future: STRICT Mode

In future versions (v0.2+), `PUB` declarations at a package boundary will require **explicit effect declarations** (e.g., `EFFECTS :alloc`) when compiled in `STRICT` mode. This ensures that library side-effects are always documented and verified.

---

## Build System

CLEAR features a built-in dependency manager that handles recursive `REQUIRE` calls, prevents circular dependencies, and manages the transpilation graph.

### Package Registration

Packages are mapped to file paths at compile-time using the `--pkg` flag:

```bash
ruby src/transpiler.rb --pkg geometry=./libs/geometry/lib.clear main.clear > main.zig
```

### Module Transpilation

To compile a library as a standalone Zig module (without the CLEAR runtime footer), use the `--module` flag. This is useful when building CLEAR code to be consumed by native Zig applications.

```bash
ruby src/transpiler.rb --module my_lib.clear > my_lib.zig
```

### How it Works

1.  **Local Imports**: The transpiler inlines the generated Zig code of the local file into a `const struct` namespace in the caller's Zig file.
2.  **Package Imports**: The transpiler emits a Zig `@import("namespace")`. The actual wiring of these modules is handled by the Zig build system using the `--dep` and `-M` flags.
3.  **Deduplication**: Each file is parsed and annotated exactly once, even if required by multiple files.

## Project Structure (Recommended)

```text
my_project/
├── main.clear            # Entry point
├── logic.clear           # Local module
└── lib/
    └── math/
        ├── lib.clear     # Package entry point (exports PUB symbols)
        └── private.clear  # Internal logic (default visibility)
```
