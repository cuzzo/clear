FN change %(list) ->
  RETURN %[10, 9, 8, 7, 6];
END

FN add %(list) ->
  RETURN list.map(%(x) -> x + 10);
END

FN combine %(l1, l2) ->
  VAR nl = %[ l1[0], l2[0], l1[1], l2[1] ];
  RETURN nl;
END

FN main %() RETURNS Number ->
  VAR list = %[1, 2, 3,];
  list
    s> change AS @c
    s> add
    s> combine(@c)
    s> print;

  RETURN 1;
END

main();
