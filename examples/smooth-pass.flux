FN step1 %() -> RETURN 10; END
FN step2 %(n) -> RETURN n * 2; END
FN step3 %(n) -> RETURN n + 5; END

FN main %() ->
  -- Should be ((10 * 2) + 5) = 25
  RETURN step1() s> step2 s> step3;
END

main();
