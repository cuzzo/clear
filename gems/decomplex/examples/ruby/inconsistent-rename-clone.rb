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
