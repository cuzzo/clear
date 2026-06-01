# Template: CLEAR test-framework grammar through annotator and MIR lowering.
#
# These cells intentionally use TEST/WHEN/TEST THAT instead of plain `main`.
# They cover the test-specific annotator and MIR lowering paths under the same
# source-level fuzz harness as normal programs.

TEST_FRAMEWORK_CELLS = [
  { shape: :hooks_lets_assert_raises },
  { shape: :stub_returns_captures_sequence },
  { shape: :stub_with_and_pending },
  { shape: :benchmark },
  { shape: :smash },
  { shape: :profile },
].freeze

FuzzGenerator.register(:test_framework_matrix, cells: TEST_FRAMEWORK_CELLS) do |p|
  case p[:shape]
  when :hooks_lets_assert_raises
    <<~CHT
      FN risky(flag: Bool) RETURNS !Int64 ->
        IF flag THEN RAISE Input; END
        RETURN 7_i64;
      END

      FN main() RETURNS Void -> RETURN; END

      TEST Harness DO
        LET base = 10_i64;
        LET total = base + 5_i64;

        BEFORE ALL DO
          ASSERT 1_i64 == 1_i64, "before all";
        END

        AFTER ALL DO
          ASSERT 2_i64 == 2_i64, "after all";
        END

        WHEN "hooks" TAGS [unit, fuzz] DO
          LET inner = total + 1_i64;

          BEFORE EACH DO
            counter: Int64 = inner;
          END

          AFTER EACH DO
            ASSERT counter >= 16_i64, "after each";
          END

          TEST THAT "uses lazy lets and hooks" DO
            ASSERT counter == 16_i64, "before each counter";
            ASSERT total == 15_i64, "test let";
          END
        END
      END
    CHT

  when :stub_returns_captures_sequence
    <<~CHT
      FN fetchName() RETURNS String -> RETURN "real"; END
      FN nextName() RETURNS String -> RETURN "real"; END
      FN send(msg: String) RETURNS Void -> RETURN; END
      FN main() RETURNS Void -> RETURN; END

      TEST Stubs DO
        WHEN "return capture sequence" DO
          STUB fetchName RETURNS "mock";
          STUB send CAPTURES sends;
          STUB nextName SEQUENCE ["one", "two", "three"];

          TEST THAT "uses all stub kinds" DO
            ASSERT fetchName() == "mock", "stub returns";
            send("one");
            send("two");
            ASSERT sends == 2_i64, "stub captures";
            ASSERT nextName() == "one", "seq first";
            ASSERT nextName() == "two", "seq second";
          END
        END

        WHEN "unstubbed" DO
          TEST THAT "scope restores real function" DO
            ASSERT fetchName() == "real", "real function";
          END
        END
      END
    CHT

  when :stub_with_and_pending
    <<~CHT
      FN compute(x: Int64, y: Int64) RETURNS Int64 -> RETURN x * y; END
      FN label(prefix: String, value: Int64) RETURNS String -> RETURN prefix; END
      FN main() RETURNS Void -> RETURN; END

      TEST StubWith DO
        WHEN "lambda" DO
          STUB compute WITH %(x: Int64, y: Int64) -> x + y;
          STUB label WITH %(prefix: String, value: Int64) -> prefix;

          TEST THAT "uses lambda stubs" DO
            ASSERT compute(2_i64, 3_i64) == 5_i64, "compute stub";
            ASSERT label("ok", 4_i64) == "ok", "label stub";
          END

          PENDING TEST THAT "skips body" DO
            ASSERT FALSE, "pending body should not run";
          END
        END
      END
    CHT

  when :benchmark
    <<~CHT
      FN compute(n: Float64) RETURNS Float64 -> RETURN n * 2.0; END
      FN main() RETURNS Void -> RETURN; END

      TEST Perf DO
        WHEN "tools" DO
          BENCHMARK compute(100.0) x5;
        END
      END
    CHT

  when :smash
    <<~CHT
      FN compute(n: Float64) RETURNS Float64 -> RETURN n * 2.0; END
      FN main() RETURNS Void -> RETURN; END

      TEST Perf DO
        WHEN "tools" DO
          SMASH compute(100.0);
        END
      END
    CHT

  when :profile
    <<~CHT
      FN compute(n: Float64) RETURNS Float64 -> RETURN n * 2.0; END
      FN main() RETURNS Void -> RETURN; END

      TEST Perf DO
        WHEN "tools" DO
          PROFILE compute(100.0);
        END
      END
    CHT
  end
end
