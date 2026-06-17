# Rust isn’t hard.
## Its Type System has a steep learning curve.

For excellent (long) resources see [Brown’s Rust Book](https://rust-book.cs.brown.edu/) or the [Rust Language Book](https://doc.rust-lang.org/book/).

The problem is - those books are like ~800 pages.

**Rust isn’t *THAT* hard!**

The point of this guide is to demystify the "hard" parts and make Rust easier to approach.  You can probably "get" Rust in this ~30 page guide, at least enough to read Rust code and understand it fully.

The "hard" part of Rust is the cross section between:

 1. Its Type System,
 2. Its Affine Ownership model,
 3. The Borrow Checker / Memory Lifetimes,
 4. Its concurrency model, AND
 5. Its trait / interface system

The combination of these 5 is a very narrow slice, but it's made especially difficult because the error messages you encounter in this cross section seem like psychobabble... until they don’t.

### Unfortunately, these error messages either:

 1. Crop up very early on in your learning curve, or
 2. Gate Rust’s killer features (fearless concurrency)

Rust’s "learning curve" has little to do with its syntax, its type system, its Affine Ownership model, its Borrow Checker, or its interface system individually.

The learning curve predominately stems from the way its type system interacts with those features, and especially the error messages you encounter at the cross sections.
While learning the language, if you haven’t yet fully grasped the type system AND Affine Ownership, it’s difficult to get anything done!

It’s like a catch-22, where the errors don’t make sense unless you already know the answer.  
The problem is, when you’re learning a language… you don’t know the answers yet!

How do you learn the Affine Ownership and Memory Lifetimes before you learn the type system?  
How do you understand why the type system is the way it is before you learn those models? 
That’s the tough part.  It’s not easily broken down.  They’re all interwoven.

Rust is shockingly expressive, and for the most part, it’s as easy or easier than languages with “easy” reputations like Kotlin or Go or Swift.

## Compare Rust to the highest-level scripting language:

The Hello World (ish) Example:

```python
def add_numbers(a, b):
    return a + b

print(add_numbers(40, 2))
```

```rust
fn add_numbers(a: i32, b: i32) -> i32 {
  a + b
}

fn main() {
  println!("{}", add_numbers(40, 2));
}
```

Here, already, we can see that Rust is a little more complicated than Python, but not much.  Compare to C++, Go, and Kotlin:

```cpp
#include <iostream>

int add_numbers(int a, int b) {
    return a + b;
}

int main() {
    std::cout << add_numbers(40, 2) << std::endl;
    return 0;
}
```

```go
package main

import "fmt"

func addNumbers(a, b int) int {
    return a + b
}

func main() {
    fmt.Println(addNumbers(40, 2))
}
```

```kotlin
fun addNumbers(a: Int, b: Int): Int {
    return a + b
}

func main() {
    println(addNumbers(40, 2))
}
```

Rust requires a param for its print function.  Otherwise, it’s as nice as Kotlin.

The problem is, code is rarely as simple as “Hello World”.  You quickly run into insurmountable and/or frustrating brick walls depending on which language you come from.

Other languages do not have such immediate and frustrating brickwalls.

## Affine Ownership is Simple:

**You can’t have your cake and eat it, too.**

Nearly every language in the world does not have Affine or Linear types.  In these languages, you’re allowed to have your cake and it, too.

This is nice... But it’s not the way the world works.  It’s a confusing default.

In other languages... If you have a dollar, you can "give" it to another object, and when you do, you’ll hold onto it by default.

In Rust, you can’t do that.  Only one object can have the dollar!

If you want to share it, you need to give it permission to be shared.

This is called **Aliasing**, and - in practice - it’s the root of many of the toughest to debug problems.  Languages without Affine/Linear types allow Aliasing by default.  Rust does not.

Rust calls this Affine Movement.  When you give a dollar from one object to another, you move it (transfer ownership).

Example:

```rust
fn main() {
    let account1 = foo();
    let account2 = bar();
    let dollar = getDollar();
    account1.dollar = dollar; // account1 now owns the dollar. It’s `moved`.
    account2.dollar = dollar; // ERROR! `use` after `move`
}
```

This should help you get through many of the following errors:

## Conditionals

Average user: *I think I’ll write an if statement today...*

```rust
fn main() {
  let username = String::from("brian");
  let is_admin = true;

  // A completely innocent conditional check...
  if is_admin {
    login_admin(username); // Ownership of `username` is `moved` here!
  } else {
    login_standard(username); // Or here!
  }
  
  // You just want to print a log statement at the end of the function...
  println!("Log: User {} attempted login.", username); 
}
```

You get an error like:

```
error[E0382]: borrow of moved value: `username`
  --> src/main.rs:13:48
   |
2  |     let username = foo();
   |         -------- move occurs because `username` has type `String`, which does not implement the `Copy` trait
...
6  |         login_admin(username);
   |                     -------- value moved here
...
13 |     println!("Log: User {} attempted login.", username);
   |                                               ^^^^^^^^ value borrowed here after move
```

This error is helpful *IFF* you get Rust. But if you don’t, it seems like psycho-babble:

 * What’s a `moved` value?
 * What’s a `trait`, and what’s the `Copy` trait specifically, and how does it relate to `moved` values?
 * How did it get `moved` by `login_admin`?
 * Why does `println!` need to `borrow` it?
 * And why can’t it `borrow` it just because `login_admin` `moved` it!?

As we discussed, `moved` means ownership was transferred.  A thing can only have one owner (by default).  Therefore, `println!()` can’t `borrow` it, because `login_admin` `moved` it (took it).  You don’t own it anymore for `println!` to borrow it from you.  `login_admin` owns it.

## Lifetimes Aren’t hard:

**Everything dies. Rust just makes a simple process look like sorcery.**

Affine Ownership is simple.  You can’t have your cake and eat it, too.  
But what happens if you have a long string, and you don’t want to copy it just so someone can print it?

You need to let them borrow your string.

In a Rust / Pseudo-C, this is easy:

```rust
fn func_that_borrows(s: &str) { 
  println!("{}", *s); 
}
```

Other systems languages have pointers to solve this problem.  To avoid passing a huge string, you get the pointer to its memory (&str), and then to get the value of the string (rather than the pointer to it) you use `*s` to use it.

Newer languages typically default to something called implicit pass by reference.  
They handle all of this behind the scenes, because >90% of the time, this is what you want to do.  So they make this the default behavior.

```python
def func_that_borrows(s):
    print(s) 
}
```

Even systems-ish languages like Swift will do this for you.

Instead of >90% of the time, getting the reference, passing it, and then dereferencing it - in the rare 10% of cases you EXPLICITLY copy it.

In a Pseudo-Rust that has implicit pass by reference:

```rust
fn print_func(s: str) {  // implicit pass by ref
  println!("{}", s);     // implicit deref of value passed by ref
}

// >90% of the time, you want the fast thing, passing the pointer to the string:
s = hugeStr();
print_func(s);

// Rarely, you want to pass an explicit copy:
print_func(s.copy());
```

This is not hard to understand, but Rust’s syntax here is particularly unintuitive:

```rust
fn func_that_borrows<'a>(s: &'a str) { 
  println!("{}", s); 
}
```

There’s no two ways around this.  There is nothing intuitive about the way that function reads.

 * In `func_that_borrows<'a>` -> `'a` declares this function borrows, therefore it has a lifetime.
 * In `s: &'a str` -> `'a` declares param `s` is the thing that is borrowed.

This is a very simple concept with an unintuitive syntax.

Let’s say you have an Account, and you want to put it into an array, but the Account has a 10GB buffer, and you DON’T want to just copy it.  
Instead, you can give the array a BORROW:

```rust
fn store_borrowed_account<'a>(
  acct: &'a Account, // acct must have a lifetime to be borrowed
  mut accts: Vec<&'a Account>  // accounts must be mutable to append
) { 
  accts.push(acct);  // `accts` must have a lifetime to hold borrowed objects.
}
```

The pieces here that makes Rust confusing if you come from a non-systems language is that:

 * ~90% of the time you want to pass by reference `&Account`.
   * Rust does not default to doing this.
 * Therefore, most function parameters look a little confusing…
 * What’s the `&Account`?  What’s the `&’a Account`?
 * Why do I need to tell it to `borrow` something if I already told it I’m giving it a reference  with `&` ?

These are all very valid questions.

A reference *IS* a borrow.  You cannot have one without the other.

Except, to make life simple, Rust makes it seem like you can! It can **elide** the lifetime:

```rust
fn func_that_borrows(s: &str) { 
  println!("{}", s); 
}
```

Rust can just tell that there’s only one lifetime.  It allows you to write this without spelling out the `'a` lifetimes...

In reality `&str` means, this function takes a BORROWED string (that someone else owns).  It has an implicit lifetime because `s` is a reference / borrowed.

## Iterators

Average user: *I think I’ll try to do some basic iteration today...*

```rust
fn main() {
  // Vec<&str> + collect
  let parts: Vec<&str> = "a,b,c".split(',').collect();
}
```

Most people would likely prefer the ability to do:

```rust
fn main() {
  let parts = "a,b,c".split(',');
  let p = parts[1];
}
```

But Rust doesn’t allow that:

```
error[E0608]: cannot index into a value of type `std::str::Split<'_, char>`
 --> src/main.rs:4:11
  |
4 |   let s = parts[1];
  |           ^^^^^^^^
```

Average person: *WTF is `std::str::Split<'_, char>` ?!*

 * What is `'_` ?
 * What is `Split<x, y>` ?
 * How is that different from an Array of strings?
 * And why don’t I have what I clearly wanted!?

The average person reads online that they need to use `collect`:

```rust
fn main() {
  let parts = "a,b,c".split(',').collect();
  let p = parts[1];
}
```

```
error[E0282]: type annotations needed
 --> src/main.rs:2:34
  |
2 |   let parts = "a,b,c".split(',').collect();
  |                                  ^^^^^^^ cannot infer type for type parameter `B` declared on the associated function `collect`
  |
help: consider giving `parts` an explicit type
  |
2 |   let parts: Vec<&str> = "a,b,c".split(',').collect();
  |            +++++++++++
```

This error *IS* helpful, but the first was not, and the entire process is *NOT* ideal for what the average user would *like* to do.

The average person is likely to wonder:

 * Is `Vec<&str>` what I want?
 * I think I want a `Vec<String>`...

But you do want a `Vec<&str>`!  This is fast!  Instead of copying all the pieces of the string to split it, you get small pointers to the sections (borrows).

## Vector Indexing

Average user: *I think I’ll try to use an array today...*

```rust
fn main() {
    let scores = vec![100, 90, 85];
    
    // You just want the first score...
    let first_score = scores.first();
    
    println!("High score: {}", first_score + 10);
}
```

```
error[E0369]: cannot add `{integer}` to `Option<&{integer}>`
 --> src/main.rs:6:43
  |
6 |     println!("High score: {}", first_score + 10);
  |                                ----------- ^ -- {integer}
  |                                |
  |                                Option<&{integer}>
```

Average user:

 * What’s an `Option<T>` ?
 * What’s a `&{integer}` ??
 * How is that different from an i32 or i64?!

## Optionality Isn’t Hard:

Sometimes you need to know: does an item exist at all?

A vector is the obvious case:

```rust
fn main() {
  let v = getVec();
  let x = v[10].name;
}
```

What happens if the vector is only 8 items long?  It needs to be able to return a Nil value.  And the compiler needs to be able to tell you that you could have an error if you don’t explicitly check for that case.

Most languages simply don’t solve this problem and make it a nightmare.  It is impossible to know if a value can be nil or not:

```go
fn GetUser() *User {
    if rand.Float64() < 0.5 {
        return nil // Legal return
    }
    return &User{Name: "Brian"}
}
```

This becomes a nightmare. You cannot look at the function signature and see whether or not you need to check for nil. 
The compiler cannot tell you that you have a possible error if `random()` returned less than 0.5...

In scripting languages, you don’t have types at all... So, this is sort of expected, but equally nightmarish.  
You typically know what the type of a function is supposed to be, but are often surprised when it’s nil/null, and get unexpected runtime bugs (like in C or Go).

Rust solves this with:

## `Option<T>`

Average user: *I’ll try to work on some nilable / nullable / Option<T> object today...*

```rust
use std::collections::HashMap;

fn main() {
    let mut user_roles = HashMap::new();
    user_roles.insert("brian", "Admin");

    // You just want to grab the role and print it uppercase...
    let role = user_roles.get("brian");
    
    println!("User role is: {}", role.to_uppercase());
}
```

```
error[E0599]: no method named `to_uppercase` found for enum `Option<&&str>` in the current scope
  --> src/main.rs:10:39
   |
10 |     println!("User role is: {}", role.to_uppercase());
   |                                       ^^^^^^^^^^^^ method not found in `Option<&&str>`
   |
help: consider using `Option::map` to operate on the contained value
   |
10 |     println!("User role is: {}", role.map(|s| s.to_uppercase()).unwrap_or_default());
   |                                      ++++++++++++++++++++++++++++++++++++++++++++++
```

Again, this is a relatively easy fix, to a relatively common problem, and the error again looks like psycho-babble.  It is also suggesting a pretty bad option...


What you want to do is `unwrap` the `Option<T>` from the start:

```rust
use std::collections::HashMap;

fn main() {
    let mut user_roles = HashMap::new();
    user_roles.insert("brian", "Admin");

    let role = user_roles.get("brian").unwrap();
    
    println!("User role is: {}", role.to_uppercase());
}
```

But now you run into another psycho-babble error:

```
error[E0599]: no method named `to_uppercase` found for reference `&&str` in the current scope
```

Average user: *Wait.. What?*

 * What’s a `&&str` ?
 * How did I get that, and what do I do about it?!

You need to dereference the `.unwrap()` value:

```rust
use std::collections::HashMap;

fn main() {
    let mut user_roles = HashMap::new();
    user_roles.insert("brian", "Admin");

    let role = *user_roles.get("brian").unwrap();
    
    println!("User role is: {}", role.to_uppercase());
}
```

Rust is a language designed for complete control, zero-cost abstractions, and all cost signals visible.

Manual dereferencing is a price you must pay to achieve that.

Everyone would like a perfectly safe language, with zero cost abstractions, that looked like Python or Ruby exactly.

The average person that would like to use Rust, probably doesn’t to do manual dereferencing `*`. 
Deref costs rarely exceed 1% of program runtimes, but can easily exceed far more than 1% of the cognitive complexity.

But Rust wasn’t made for the average person who would like to use it.  
It was made for a specific user that wants complete cost-signal visibility and the ability to achieve perfect performance (at any cognitive cost).  

This is just an unfortunate but necessary reality.

## Conditional Option<T>

Average user: *I’ll try an if statement on something optional today...*

```rust
fn main() {
    let scores = vec![100, 90, 85];
    let first_score = scores.first();
    if first_score {
        println!("High score: {}", first_score + 10); 
    }
    // ...
}
```

```text
error[E0308]: mismatched types
 --> src/main.rs:4:8
  |
4 |     if first_score {
  |        ^^^^^^^^^^^ expected `bool`, found `Option<&{integer}>`
  |
help: consider using `Option::is_some`
  |
4 |     if first_score.is_some() {
  |                   ++++++++++
```

Average user, okay:

```rust
fn main() {
    let scores = vec![100, 90, 85];
    let first_score = scores.first();
    if first_score.is_some() {
        println!("High score: {}", first_score + 10); 
    }
    // ...
}
```

Here, you get the same error that you got before about `first_score` being an `Option<&{integer}>`.  The error message doesn’t tell you or guide you, but you need to do:

```rust
fn main() {
    let scores = vec![100, 90, 85];
    let first_score = scores.first();  // `score` is an Option<T>. 
    
    
    if let Some(score) = first_score {  // this gets `score` if it exists
        println!("High score: {}", score + 10); // Outputs: High score: 110
    } else { // this has no `score` because it doesn’t exist...
        println!("The vector was empty, there is no score!");
    }
}
```

## Fallibility Isn’t Hard:

Sometimes you need to know: can this function fail?

A transaction is the obvious case:

```rust
fn main() {
  let a = getAccntA();
  let b = getAccntB();
  let amnt = 100;
  if (a.balance < amnt) { // ERROR }
  // ...
}
```

You cannot allow someone to transfer funds if a balance is too low.

C solves this by returning an error code, but that presents a number of problems.  What happens if you want to return a success object?  In C, you need to:

 1. Create the object before hand
 2. Pass by reference
 3. Mutate the object
 4. Make sure the returned error code is 0 / null
 5. Check the mutated object

This is **implicit control flow** and an elaborate dance that’s 1) unintuitive and 2) easy to get wrong.

Go solves some of this by having functions return two values:

```go
fn main() {
  user, err := getUser();
  if (err) { // handle error }
  // otherwise, user is set
}
```

In scripting languages like Python and Ruby - you just raise errors willy nilly:

```python
def transact(a, b, amnt):
    if a.balance < amnt: raise “balance too low.”
    # ...
```

This seems nice, but the problem is - this introduces **Global Complexity**.  
You cannot know if a function raises an error, or what errors it might raise by looking at the signature, or even reading the entire function.

You need to read the entire delegation chain and track it yourself to figure it out.  Imagine if the error was moved into a helper:

```python
def check_balance(acc, amnt):
    if acc.balance < amnt: raise “balance too low.”

def transact(a, b, amnt):
    check_balance(a, amnt)
    # ...
```

Rust solves this with:

## `Result<T, E>`

```rust
use std::fs::File;

fn main() {
    // You just want to open a configuration file...
    let file = File::open("config.txt");

    // ...and see how big it is.
    println!("File size: {} bytes", file.metadata().unwrap().len());
}
```

```
error[E0599]: no method named `metadata` found for enum `Result<File, Error>` in the current scope
 --> src/main.rs:7:42
  |
7 |     println!("File size: {} bytes", file.metadata().unwrap().len());
  |                                          ^^^^^^^^ method not found in `Result<File, Error>`
```

Average person: *What do you mean metadata isn't found? I looked at the docs, File absolutely has a metadata method!*

The catch-22 strikes again. You don't have a File. You have a Result wrapper that might contain a file, or might contain a disk error.

Remembering the lesson from the `Option<T>` saga, you decide to just `unwrap()` it right away to get the file out:

```rust
use std::fs::File;

fn main() {
    // Just unwrap it to get the File out, right?
    let file = File::open("config.txt").unwrap();

    println!("File size: {} bytes", file.metadata().unwrap().len());
}
```

You run it, and it compiles! Success! But this is kind of ugly.  You try to do it the idiomatic way:

```rust
use std::fs::File;

fn main() {
    // Let's use the idiomatic '?' operator instead of unwrapping everything
    let file = File::open("config.txt")?;
    let metadata = file.metadata()?;

    println!("File size: {} bytes", metadata.len());
}
```

## Idiomatic Rust with `?`

```
error[E0277]: the `?` operator can only be used in a function that returns `Result` or `Option`
 --> src/main.rs:5:40
  |
4 | fn main() {
  | --------- this function should return `Result` or `Option` to accept `?`
5 |     let file = File::open("config.txt")?;
  |                                        ^ cannot use the `?` operator in a function that returns `()`
  |
  = help: the trait `FromResidual<Result<Infallible, std::io::Error>>` is not implemented for `()`
```

Average user: *Trait FromResidual Infallible?! I just wanted to read a file size!*

> I guess I’ll just write shitty ugly Rust code... at least it runs!

The solution is this:

```rust
use std::fs::File;
use std::error::Error;

// You have to change the return type of main itself!
fn main() -> Result<(), Box<dyn Error>> {
    let file = File::open("config.txt")?;
    let metadata = file.metadata()?;

    println!("File size: {} bytes", metadata.len());
    
    // And you have to explicitly return an "Ok" empty tuple at the end
    Ok(())
}
```


## Concurrency Isn’t Hard:

TODO - analogize...

## Synchronization

Average user: *I think I’ll try fearless concurrency today...*

```rust
use std::thread;

fn main() {
    let mut items = vec![1, 2, 3];

    let handle = thread::spawn({
        items.push(4); // Value is moved into the closure here
    });
    // ...
}
```

```
error[E0308]: mismatched types
 --> src/main.rs:7:32
  |
7 |     let handle = thread::spawn({ items.push(4) });
  |                  ------------- ^^^^^^^^^^^^^^^^^ expected closure, found `()`
  |                  |
  |                  arguments to this function are incorrect
```

Hmm... Okay, I see I can create a closure with `|| { }`, that’s a little unintuitive, and it would’ve been nice if the error message told me so, but whatever, I’ll try it:

```rust
use std::thread;

fn main() {
    let mut items = vec![1, 2, 3];

    let handle = thread::spawn(|| {
        items.push(4); // Value is moved into the closure here
    });
    // ...
}
```

```
error[E0373]: closure may outlive the current function, but it borrows `items`, which is owned by the current function
 --> src/main.rs:7:32
  |
7 |     let handle = thread::spawn(|| {
  |                                ^^ may outlive borrowed value `items`
8 |         items.push(4); 
  |         ----- borrow occurs due to use in closure
  |
note: function requires argument type to outlive `'static`
 --> src/main.rs:7:18
  |
7 |       let handle = thread::spawn(|| {
  |  __________________^
8 | |         items.push(4); 
9 | |     });
  | |______^
help: to force the closure to take ownership of `items` (and any other referenced variables), use the `move` keyword
  |
7 |     let handle = thread::spawn(move || {
  |                                ++++
```

Okay, that error was pretty scary, but at least at the end it does tell me exactly what to do:

```rust
use std::thread;

fn main() {
    let mut items = vec![1, 2, 3];

    let handle = thread::spawn(move || {
        items.push(4);
    });

    println!("Our items: {:?}", items);
}
```

```
error[E0382]: borrow of moved value: `items`
  --> src/main.rs:10:33
   |
4  |     let mut items = vec![1, 2, 3];
   |         --------- move occurs because `items` has type `Vec<i32>`, which does not implement the `Copy` trait
5  | 
6  |     let handle = thread::spawn(move || {
   |                                ------- value moved into closure here
...
10 |     println!("Our items: {:?}", items);
   |                                 ^^^^^ value borrowed here after move
```

This error unfortunately does not give you any insight into how to resolve the problem.  
The problem is, `items` is moved into a thread, and it may not have been resolved.  You `forked` with `thread::spawn`, but did not yet `join`:

> TODO: Switch this error around...

Let’s try joining!


```rust
use std::thread;

fn main() {
    let mut items = vec![1, 2, 3];

    let handle = thread::spawn(move || {
        items.push(4);
    });

    handle.join();
    println!("Our items: {:?}", items);
}
```

Surprise!  You get the *EXACT* same error.  You need to move the `items` back out, and then `unwrap` the `join`, otherwise it’s no good:

```rust
use std::thread;

fn main() {
    let mut items = vec![1, 2, 3];

    let handle = thread::spawn(move || {
        items.push(4);
        items;
    });

    let updated_items = handle.join().unwrap();
    println!("Our items: {:?}", updated_items);
}
```

If you compare the expressiveness of Rust to most other languages, this is great.  It’s also safe.  But there are several components that aren’t intuitive here:

```
    let handle = thread::spawn(move || {
        items.push(4);
        items;
    });
```


 * The `move || { .. }` is unlikely to be intuitive for most people.  
 * As is the fact that you have to move a value `items` back out after updating.
 * But fine, this is easily enough covered by reading an example…

```
    let updated_items = handle.join().unwrap();
``` 

 * You also need to `.join().unwrap()` to get the value back. 
 * A lot of languages don’t have parallelism, so you may not know this.  
 * A lot of languages that do, default to fork/join.
 * Some don’t even have an async option!

Rust does have fork/join, but it is arguably more difficult!

```rust
    thread::scope(|s| {
        s.spawn(|| {
            items.push(4); // No 'move' needed! It just borrows it.
        });
    });
```

## Shared Memory Isn’t Hard:

This, again, is about having your cake and eating it, too.  Lifetimes allow you to easily share memory on a single core.

The unfortunate reality is... The way computers work, to share memory safely across multiple cores requires a little bit more effort.

You need to wrap something in an `Arc<T>`.  `Arc` stands for **A**tomic **R**eference **C**ount.
You shouldn’t need to know all the implementation details of CPU cache-lines to understand how to share memory.

But because Rust wants all cost signals visible at all times... In Rust, you do.

The problem with multiple cores is... 2 things can *literally* happen at the exact same time.

Let’s take the transaction as an example again:

```rust
fn main() {
  let a = getAccntA();
  let b = getAccntB();
  
  // on core 1
  transfer(a, b, 100);
 
  // on core 2
  transfer(a, b, 100);
}
```

You can run into the notorious **double spend** bug:

```rust
fn transfer(a: Account, b: Account, amnt: f64) {
  if (a.balance < amnt) { // ERROR }  // Time of check
  // do transfer - time of use
}
```

Double spend is a class of **TOCTOU** - **T**ime **o**f **C**heck vs **T**ime **o**f **U**se.

Core 1 can check that the amount is sufficient.   Core 2 can do that at the same time and see it’s sufficient.
Then Core 2 can transfer the funds, making Core 1’s check irrelevant.  Now, account a may have only $20 after the $100 transfer.
Core 1 has already made the check, though, and it will transfer another $100 ($80 of which account A doesn’t even have) to account B.

Rust solves this with:

```rust
fn transfer(a: Arc<Mutex<Account>>, b: Arc<Mutex<Account>>, amnt: f64) {
    // .lock() forces Core 1 and Core 2 to queue single-file
    let mut guard_a = a.lock().unwrap();  // it is physically impossible for both cores to do this at the same time. 
    let mut guard_b = b.lock().unwrap();  // One of the two cores cannot get here until the other core finishes the entire work

    if guard_a.balance < amnt {  // Because of that, this check is always valid
        println!("Error: Insufficient funds!");
        return;
    }

    // Because of that, this mutation cannot “race” / it is guaranteed valid:
    guard_a.balance -= amnt;
    guard_b.balance += amnt;

    // Here, both locks are automatically released due to RAII.
    // When guards go out of scope, they release their locks.
    // In C and Go and Zig, you must manually release locks.
    // This is extremely error prone.
}
```

A Mutex is just a type of Lock.  The `lock` is the part that’s needed to prevent the data race / TOCTOU.  The `Arc` is the part that’s needed to ensure memory safety.

This is frustrating if you don’t care about the implementation details.
Like how Rust requires lifetimes any time you have a reference / borrow, any time you want to use a borrow across cores, you typically need both an Arc AND a Lock.

You’d probably like to just have one - maybe something like Shared<T>.  But Rust doesn’t really care about your ideal interface.
It cares about all costs being visible and zero cost abstractions.

Physics and hardware don’t work how you would like them to ideally, and because of that, neither does Rust.

## Interfaces Aren’t Hard:

**Unless you want zero-cost abstractions...**

In high-level languages, interfaces or duck-typing are pure bliss. You tell the language: "If it walks like a duck and quacks like a duck, it's a duck."

In Ruby or Python, any struct with a `Quack()` method automatically implements an interface. You don't have to explicitly declare it; it just works.

Rust rejects this loose flexibility entirely. You can't determine at compile time if calling `Quack()` would lead to a segfault...

Rust uses Traits. A trait is an explicit contract. 

If you want a struct to have a behavior, you have to explicitly build that bridge step-by-step:

```rust
trait Speaker {
  fn speak(&self) -> String;
}

struct Human;
impl Speaker for Human {
  fn speak(&self) -> String { 
    String::from("Hello") 
  }
}

struct Dog;
impl Speaker for Dog {
  fn speak(&self) -> String { 
    String::from("Bark") 
  }
}
```
This is not hard.  It’s literally one extra line of code... The problem is the error messages:

## Traits and Interfaces, oh my:

Average user: *I think I’ll try to put a bunch of objects that can speak in a list...*

```rust
fn get_speakers() {
  // A completely innocent array of objects that implement Speaker...
  let speakers: Vec<Speaker> = vec![getHuman(), getDog()]; 
}
```

You get an error that completely derails your evening:

```
error[E0782]: trait objects must include the `dyn` keyword
 --> src/main.rs:2:23
  |
2 |     let speakers: Vec<Speaker> = vec![getHuman(), getDog()];
  |                       ^^^^^^^
  |
help: add `dyn` keyword before the trait name
  |
2 |     let speakers: Vec<dyn Speaker> = vec![getHuman(), getDog()];
  |                       +++
```

Average user: *Okay, fine, I don't know what dyn means, I don’t care and I wish it didn’t exist, but I'll use the help menu suggestion:*

```rust
fn get_speakers() {
  let speakers: Vec<dyn Speaker> = vec![getHuman(), getDog()]; 
}
```

Now you enter the true psychobabble zone:

```
error[E0277]: the size for values of type `(dyn Speaker + 'static)` cannot be known at compilation time
   --> src/main.rs:2:19
    |
2   |     let speakers: Vec<dyn Speaker> = vec![getHuman(), getDog()];
    |                   ^^^^^^^^^^^^^^^^ doesn't have a size known at compile-time
    |
    = help: the trait `Sized` is not implemented for `(dyn Speaker + 'static)`
```

Average user:

 * What on earth does `dyn` mean?
 * What is `+ 'static` doing in my array type? I didn't add a lifetime!
 * What do you mean the size cannot be known? A Human and a Dog are right there in the code! Figure it out, you stupid compiler!
 * What is the `Sized` trait?
 * Why am I responsible for implementing it?!

This is incredibly frustrating if you’re a normal person minding your own business and not wanting to be bothered with the implementation details of how object layout storage in RAM works.

In Go, Java, Python, etc... most (or all) objects are quietly wrapped in a pointer box and thrown onto the managed heap by default.  
Recall our example about borrowing and pass by reference. 

Because a pointer is always the same size (8 bytes on a 64-bit machine), those languages can easily throw different objects into the same array. 
The array is just a list of identical 8-byte boxes.

Rust doesn't hide that cost. Rust defaults to putting things directly on the stack without an expensive heap pointer allocation.

 * The allocation is expensive - even with a fancy allocator like Jemalloc.
 * You have more opportunity to run out of memory - your stack is already allocated.
 * If it’s on the heap, there’s more opportunity to cache miss and memory stall (huge cost).
 * If it’s on the heap, even if you don’t cache miss, you still need to pay the cost to dereference.

For a language that needs zero cost abstractions and all cost signals visible, working with interfaces is going to require some added effort, and for you to know these details you’d probably rather not know!

A `Human` struct might take up 0 bytes of memory. A `Dog` struct might have strings and take up 24 bytes of memory.

When you ask Rust to create a `Vec`, you are asking it to allocate a contiguous block of stack memory.

> [!NOTE]
> Why?  An array needs `O(1)` lookup.  If items are randomly different sizes, you need `O(N)` lookup to find an item.
> You *could* need to scan through *nearly* the entire array to find an item at the end.
> If the items are all the same size, you can find the spot in memory by simply: `memPos = arrOffset + (objSize * lookupIdx)`

How can it reserve memory for an array if slot 1 requires 0 bytes and slot 2 requires 24 bytes? It can't. The compiler hits a physical hardware limitation, drops the mask of a friendly interface language, and screams at you in the math of its type system: `dyn Speaker does not implement Sized`.

To fix it, you must explicitly pay the performance tax for a heap pointer wrapper using `Box<T>`:

```rust
fn get_speakers() {
    // We explicitly box them so they are uniform 8-byte pointer addresses
    let speakers: Vec<Box<dyn Speaker>> = vec![Box::new(getHuman()), Box::new(getDog())]; 
}
```

In Go or in Java, you can just stick them in the array, they are in a box by default.  It’s a minimal cost to make your life easy.

In Rust, you need to know this cost exists and acknowledge it. C’est la vie to achieve perfect performance.

## The actual hard part: when worlds collide

Average user: *Okay, I have learned painfully, and I am ready for the payoff!  Let me try Tokio...*

```rust
use std::sync::{Arc, Mutex};

#[tokio::main]
async fn main() {
    let counter = Arc::new(Mutex::new(0));
    let counter_clone = counter.clone();

    tokio::spawn(async move {
        let _guard = counter_clone.lock().unwrap(); // Grab the lock
        tokio::time::sleep(std::time::Duration::from_secs(1)).await; // Hold it across an await
    });
}
```

```
error[E0277]: `std::sync::MutexGuard<'_, i32>` cannot be sent between threads safely
   --> src/main.rs:9:18
    |
9   |     tokio::spawn(async move {
    |                  ^^^^^^^^^^ `std::sync::MutexGuard<'_, i32>` cannot be sent between threads safely
    |
    = help: within `impl std::future::Future<Output = ()>`, the trait `std::marker::Send` is not implemented for `std::sync::MutexGuard<'_, i32>`
    = note: required because it captures the following types: `ResumeTy`, `std::sync::MutexGuard<'_, i32>`, `impl std::future::Future<Output = ()>`, `()`
```

Average user: *Hmm... That error doesn’t make any sense… maybe I’ll try Tokio in a few weeks...*

But... We’re no longer an average user.  We should be able to break this down and make sense of it.

```
`std::sync::MutexGuard<'_, i32>` cannot be sent between threads safely
```

`'_` is the part that would trip most people.  But, that means we have a placeholder value that is borrowed WITH a lifetime.

```
`std::sync::MutexGuard<'_, i32>` cannot be sent between threads safely
```

Average user: *Hmm... Why’s that?  I created an Arc specifically to do this...*


```
    = help: within `impl std::future::Future<Output = ()>`, the trait `std::marker::Send` is not implemented for `std::sync::MutexGuard<'_, i32>`
    = note: required because it captures the following types: `ResumeTy`, `std::sync::MutexGuard<'_, i32>`, `impl std::future::Future<Output = ()>`, `()`
```

The problem is... Tokio needs to `Resume` at the end of a `tokio::spawn` block.  It’s saying that `MutexGuard` from this line:

```
let _guard = counter_clone.lock().unwrap();
```

Is incompatible as written with Tokio’s `Resume`.

The nature of Rust’s type system, and the fact that Tokio is not part of the language, means that you’re going to end up with errors with traits and implications that resemble this.

This is as far as this guide can get you.

Essentially, you should be able to see now what the problem is.  Now you can easily Google or LLM how to fix it, or at least make sense of the error message.

We would like the error message to be more explicit:

```
Error! `_guard` could cross Tokio’s `await` boundary. To do this, it needs to implement `Resume` via `trait::send`, but it does not:

Solution: use `counter_clone.lock().await;` to make it compatible, or:
Drop the guard before the next `await`, eg:

```rust
    tokio::spawn(async move {
        let _guard = counter_clone.lock().unwrap(); // Grab the lock
        // Do your work
        drop(_guard);
        tokio::time::sleep(std::time::Duration::from_secs(1)).await; // Hold it across an await
    });
```

Rust’s biggest hurdle is... This is the killer feature.  Even if you read the ~800 page book, this error alone is unlikely to be very helpful, or point you to a real solution.

## Why Use Rust?

When people say: “Rust is hard” - I disagree.
There’s a very small cross section of Rust which is hard, namely because the way the language works makes it almost impossible to give good error messages.

Most of Rust is substantially easier than C (to get correct, working code).

The problem is, this cross section is Rust’s killer feature!

It’s not much harder to write sequential code that doesn’t use shared mutable memory in Rust than in Ruby or Python or TypeScript (the same thing).

But it is substantially “harder” to do the killer features than in Go (the thing you really need these languages for).

Go, on the other hand - in my opinion - is substantially harder than Python or Ruby to do the same thing - sequential code that doesn’t use shared mutable memory.

But it’s significantly easier than Rust to do concurrent shared mutable memory (the killer feature).

The problem is: Go isn’t safe!

So pick your poison: either use ~2x more memory, accept GC gitter / unpredictability, and potential race conditions - or deal with the fact that Rust’s error messages in the killer cross section will feel like Goblygook.

In the era of AI - in my opinion - Rust wins considerably.  It’s typically half as much code as Go to accomplish similar concurrent tasks [1], and - apples to apples - will use considerably less memory.

Go has the best runtime in the world. It can often beat Rust/Tokio on throughput, even though you wouldn’t think it could.

But LLMs are quite good at writing exactly the type of bug that will plague you and be very difficult to fix in any common language BESIDES Rust.  Rust makes most of those bugs impossible, the rest of them easy to test.

If an LLM is writing your code, you don’t need to understand the error messages.  The LLM can understand them just fine.

If you’ve read this guide - you should be able to understand written Rust easier than you can understand written Go, and you have far better insight into what’s safe and what’s not safe.

For those reasons, I think Rust is currently the best language in the world if you’re going to have an LLM write your code.

[1] [CLEAR Concurrent Benchmarks](/benchmarks/README.md)
