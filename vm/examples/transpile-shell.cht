STRUCT User { id: Int64 }

FN cheatMain() RETURNS User ->
  print(%"--- Test 1: Basic Echo ---");
  -- Should return "Hello from Shell\n"
  VAR greeting = shell(%"echo 'Hello from Shell'");
  print(%"Raw Output:", greeting);

  -- Verify trimming works on shell output
  VAR clean = greeting.trim();
  IF eql(clean, %"Hello from Shell") THEN
    print(%"PASS: Output captured and trimmed.");
  ELSE
    print(%"FAIL: Content mismatch.");
  END


  print(%"\n--- Test 2: Complex Pipe ---");
  -- Should list files and filter for .flux extensions
  -- This proves we are using /bin/sh, not just raw exec
  VAR files = shell(%"ls examples/ | grep .flux | head -n 3");

  print(%"Found Flux Files:");
  print(files);

  -- Split the output into a list to verify we can work with it
  VAR file_list = files.trim().split("\n");
  print(%"File Count (Top 3):", file_list.length());


  print(%"\n--- Test 3: Dynamic Command ---");
  -- Construct a command dynamically
  VAR who = %"World";
  -- Note: We don't have string interpolation yet, so we concat
  VAR cmd = %"echo " + who;
  VAR dynamic_out = shell(cmd).trim();

  print(%"Dynamic Result:", dynamic_out);

  RETURN %User{ id: file_list.length() };
END
