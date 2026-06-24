# frozen_string_literal: true

def original
  src = fetch(1)
  check(src)
  store(src)
  finalize(src)
end

def pasted
  dst = fetch(2)
  check(dst)
  store(src)
  finalize(dst)
end

def original_two
  a = fetch(1)
  check(a)
  store(a)
  finalize(a)
  finish(a)
end

def pasted_two
  b = fetch(2)
  check(b)
  store(a)
  finalize(b)
  finish(b)
end

def small
  a = 1.5
end
