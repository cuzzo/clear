STRUCT Box { val: Number }

FN set_val!(MUTABLE b) ->
  -- Implicit Deref allows SET_FIELD on a Pointer
  SET b.val = 99;
END

MUTABLE box = %Box{ val: 0 };
set_val!(box);

RETURN box.val;
