VAR is_happy = TRUE;
VAR is_sad = !is_happy;
VAR n = NIL;

IF !is_sad THEN
  print(1); -- Should print 1
ELSE
  print(0);
END

print(!!TRUE); -- Should print true
print(n); -- Should print nil
