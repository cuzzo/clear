STRUCT Vec { x: Number, y: Number, z: Number }
FN make_opt() RETURNS Vec ->
  RETURN Vec{ x: 10, y: 10, z: 10 };
END
print(make_opt().x);
