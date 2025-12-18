STRUCT User { id: Int64 }

FN cheatMain() RETURNS User ->

  VAR path = "./test_output.txt";
  VAR content = "12345";

  -- 1. Write
  writeFile(path, content);

  -- 2. Read
  VAR read_back = readFile(path);

  -- 3. Check Logic
  IF eql(read_back, content) THEN
    print("File Integrity: OK");
  ELSE
    print("File Integrity: FAIL");
  END

  VAR u = %User{ id: 12345 };
  RETURN u;
END
