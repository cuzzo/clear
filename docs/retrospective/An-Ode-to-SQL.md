# An Ode to SQL

A lot of developers seem to love to hate SQL.  I love to love it.  It's continuously made *very* hard problems in my life *extraordinarily* easy.  And I like things to be easy, so for that, I will forever be grateful to SQL.

This is my attempt to give it the praise it deserves, and the hope that I can help you realize its powers fully in the process.

## Why Is SQL Magic

The cool kids in programming tend to cluster toward functional programming languages.

They know that all the problems in software stem from **state** and **control flow**.

Pure functional languages technically forbid state (though in a Turing Complete language, you can always find a way to get around that).

SQL on the other hand truthfully does not allow *you* to write state and *severly* limits your ability to write control flow.

Thus, it allows you to write bug-free concurrent code that can be *nearly* as performant as optimized C code - almost effortlessly.

## Why is it Imperfect

SQL's fatal flaw is mainly math... Or rather, its implementation of set arithmetic. In pure mathematics, sets are clean. In *most* databases, they are not - due to `NULL`s.

Pure math handles empty sets beautifully, but SQL has `NULL`, which unfortunately makes things messy.  Why?  Because the real world is messy.  Observe:

### Users Table

| id | name | bonus |
|----|------|-------|
| 1 | Alice | 500 |
| 2 | Bob | 0 |
| 3 | Charlie | NULL (We don't know yet) |

```sql
SELECT name FROM users WHERE bonus != 0;
```

```text
> 1, Alice, 500
```

You get only Alice...  What?!  You love this?  Are you crazy?

## Why SQL Is the Way It Is (Ternary Logic)

An ordinary person expects to get Alice and Charlie.  After all, Charlie's bonus is not 0. But SQL uses Three-Value Logic (Ternary Logic). In SQL, `NULL` is not a value like 0 or an empty string. `NULL` represents an unknown absence of value.

When the engine evaluates Charlie, it computes: `NULL != 0.`

The answer to "Is an unknown value not equal to zero?" is `UNKNOWN (NULL)`.

A `WHERE` clause passes rows only if the condition evaluates strictly to `TRUE`. So Charlie is quietly dropped. This is the simplest place where `NULL` makes mathematical sense under relational algebra, but it completely violates human intuition.

You can't weasle your way out of needing `NULL`.  Rust has `Optional<T>`.  SQL has `NULL`.  The problem is: SQL's implementation can be unintuitive and that part is hidden.

## And It Gets Worse With JOINs!

The moment `NULL` enters a `JOIN` clause, predicates drop rows silently because `UNKNOWN` behavior propagates like a virus through control flow.

The intersection of `JOIN`, control flow, and ternary logic (`TRUE`, `FALSE`, `UNKNOWN` via `NULL`) can create large, invisible state matrices. A `LEFT JOIN` introduces `NULL` values for unmatched rows on the fly. If a downstream `WHERE` clause or subsequent `JOIN` evaluates a condition against those dynamically generated `NULL`s, rows are dropped silently.

Unless you train yourself, these `UNKNOWN`/`NULL` behaviors are *probably* unexpected, and thus likely to be buggy.

SQL doesn't allow *you* to write control flow.  But it does it for you.  It has *hidden* control flow.  And, unfortunately, the part it hides is exactly the unintuitive part!

The translation from a relational schema to a flat row-stream introduces hidden structural side effects.

 * In a normal language, if you double the data, you write an explicit loop or an append to do so. 
 * In SQL, the syntax for a 1:1 relation and a 1:Many relation looks identical (`JOIN table ON id`). 
   * The code looks completely passive, but the execution engine is secretly performing data multiplication under the hood.
 * In an ideal language like Rust, if a value can be Optional / `NULL`, you must explicitly handle it.
   * In SQL it does something that is consistent, but hidden & unintuitive.

## What's a JOIN actually?

### Users Table

| id | name | bonus |
|----|------|-------|
| 1 | Alice | 500 |
| 2 | Bob | 0 |
| 3 | Charlie | NULL (We don't know yet) |

### Subscriptions Table

| user_id | status |
| ------- | ------ |
| 1 | 'active' |
| NULL | 'active' (An orphaned web-hook record) |

You want a list of users and their subscription statuses, but you only care about active subscriptions. You write a standard `LEFT JOIN` because you want to make sure you don't lose users who don't have a subscription record yet:

```sql
SELECT
  u.name,
  s.status
FROM
  users AS u
LEFT JOIN
  subscriptions AS s 
  ON
    u.id = s.user_id
WHERE
  s.status = 'active'
```

```text
> Alice, 'active'
```

Okay, all good.  Now, what if we flip the WHERE condition to: `s.status != 'active'`.

You probably expect to get: 

```text
> Bob, NULL
> Charlie, NULL
```

Instead you get:

```text
```

Nothing!  Bob and Charlie completely vanish from the result set. Your `LEFT JOIN` acted exactly like an `INNER JOIN`.

If that's not unintuitive, you've probably been doing a lot of SQL!

## So Why Do I Love SQL?!

The problem is actually pretty constrained.  It *mainly* only impacts double negatives.  `WHERE x != <blah>`.  Intuitively, people expect `NULL` to `!=` everything.  Instead it is `UNKNOWN` to everything.

This is not hard!  But it is *very* easily forgotten and *very* unintuitive for most people.

It also impacts `IN`, `NOT IN`, `ANY`, and `ALL` in mysterious ways:

```sql
-- IN
3 IN (1, 2, 3)     -- TRUE
3 IN (1, 2)        -- FALSE
3 IN (1, 2, NULL)  -- UNKNOWN (you probably expect false)!

-- NOT IN
2 NOT IN (1, 3)        -- TRUE
2 NOT IN (1, 2, NULL)  -- FALSE
3 NOT IN (1, 2, NULL)  -- UNKNOWN (you probably expect false)!

-- ANY
2 = ANY (ARRAY[1, 2, NULL]) -- TRUE
3 = ANY (ARRAY[1, 2])       -- FALSE
3 = ANY (ARRAY[1, 2, NULL]) -- UNKNOWN (you probably expect false)!

-- ALL
2 = ALL (ARRAY[2, 2])        -- TRUE
2 = ALL (ARRAY[2, 3])        -- FALSE
2 = ALL (ARRAY[2, 2, NULL])  -- UNKNOWN (you probably expect false)!
```

If you take the time to *get* that, you can work magic with SQL.  You can write bug-free concurrent, highly-efficient, multi-object consistent code to solve any problem you *don't* need explicit control flow for...

It turns out, that's a lot of problems!  And it also turns out that efficient, bug-free, multi-object consistency is *extraordinarily* difficult to roll-it yourself.

And even for the class of problem that *does* require control-flow, you can write User-Defined Functions (UDFs) to do the inherently bug-prone parts - which is typically far easier than the part SQL handles for you.

> [!NOTE]
> See [What Even Is Complexity Anyway?](what-even-is-complexity-anyway.md) to learn more about why state & control flow are the source of most problems in programming, and what you can do about it - besides trying to shoe-horn all your problems into SQL.

