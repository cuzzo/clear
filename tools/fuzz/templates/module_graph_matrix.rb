# Template: module / REQUIRE graph matrix — ENUMERATED, not sampled.
#
# Multi-file REQUIRE graphs are the shape of every real CLEAR program (and
# of the self-hosted compiler), yet single-file templates cannot express
# them. Cells emit a root program plus shared `fuzz_support_mgm_*.clear`
# companion modules (written via the emit contract's support_files) and
# exercise:
#
#   :single  root -> math          one edge; every importable symbol kind
#   :chain   root -> geometry -> math
#            transitive types: geometry returns math's PUB STRUCT, the
#            root reads its fields WITHOUT requiring math directly
#   :diamond root -> {geometry, stats} -> math
#            shared leaf compiled once, reached on two paths; the root
#            also requires math directly (imports are not transitive)
#
# Negative cells lock module hygiene in: PRIVATE functions and PRIVATE
# types must stay invisible across REQUIRE.

MGM_MATH = <<~CLEAR.freeze
  PUB FN mgmAdd(a: Float64, b: Float64) RETURNS Float64 ->
    RETURN a + b;
  END

  FN mgmMul(a: Float64, b: Float64) RETURNS Float64 ->
    RETURN a * b;
  END

  PRIVATE FN mgmSecret(a: Float64) RETURNS Float64 ->
    RETURN a + 999.0;
  END

  PUB STRUCT MgmPoint { x: Float64, y: Float64 }

  PUB UNION MgmResult { Ok: Float64, Err: String }

  PUB ENUM MgmColor { Red, Green, Blue }

  PRIVATE STRUCT MgmSecretBox { code: Float64 }

  PUB FN mgmMakePoint(x: Float64, y: Float64) RETURNS MgmPoint ->
    RETURN MgmPoint{ x: x, y: y };
  END
CLEAR

MGM_GEOMETRY = <<~CLEAR.freeze
  REQUIRE "fuzz_support_mgm_math.clear";

  PUB FN mgmDistSq(a: MgmPoint, b: MgmPoint) RETURNS Float64 ->
    dx = b.x - a.x;
    dy = b.y - a.y;
    RETURN mgmAdd(mgmMul(dx, dx), mgmMul(dy, dy));
  END

  PUB FN mgmOrigin() RETURNS MgmPoint ->
    RETURN mgmMakePoint(0.0, 0.0);
  END
CLEAR

MGM_STATS = <<~CLEAR.freeze
  REQUIRE "fuzz_support_mgm_math.clear";

  PUB FN mgmSum3(a: Float64, b: Float64, c: Float64) RETURNS Float64 ->
    RETURN mgmAdd(mgmAdd(a, b), c);
  END
CLEAR

MGM_SUPPORT = {
  math: { 'fuzz_support_mgm_math.clear' => MGM_MATH }.freeze,
  chain: {
    'fuzz_support_mgm_math.clear' => MGM_MATH,
    'fuzz_support_mgm_geometry.clear' => MGM_GEOMETRY,
  }.freeze,
  diamond: {
    'fuzz_support_mgm_math.clear' => MGM_MATH,
    'fuzz_support_mgm_geometry.clear' => MGM_GEOMETRY,
    'fuzz_support_mgm_stats.clear' => MGM_STATS,
  }.freeze,
}.freeze

MGM_CELLS = [
  { graph: :single, symbol: :pub_fn },
  { graph: :single, symbol: :pkg_fn },
  { graph: :single, symbol: :struct_type },
  { graph: :single, symbol: :union_type },
  { graph: :single, symbol: :enum_type },
  { graph: :chain, symbol: :pub_fn },
  { graph: :chain, symbol: :struct_type },
  { graph: :diamond, symbol: :pub_fn },
  { graph: :single, symbol: :private_fn, expected: :compile_error },
  { graph: :single, symbol: :private_struct, expected: :compile_error },
].freeze

def mgm_single_body(symbol)
  case symbol
  when :pub_fn
    "ASSERT mgmAdd(3.0, 4.0) == 7.0;"
  when :pkg_fn
    # Package-private (no PUB): importable because the modules share a dir.
    "ASSERT mgmMul(5.0, 6.0) == 30.0;"
  when :struct_type
    <<~CLEAR.strip
      p = MgmPoint{ x: 3.0, y: 4.0 };
          ASSERT p.x == 3.0;
          p2 = mgmMakePoint(10.0, 20.0);
          ASSERT p2.y == 20.0;
    CLEAR
  when :union_type
    <<~CLEAR.strip
      ok = MgmResult{ Ok: 42.0 };
          MUTABLE got = 0.0;
          PARTIAL MATCH ok START
              MgmResult.Ok AS val -> got = val;,
              MgmResult.Err -> got = 0.0 - 1.0;,
          END
          ASSERT got == 42.0;
    CLEAR
  when :enum_type
    <<~CLEAR.strip
      c = MgmColor.Red;
          MUTABLE isRed = FALSE;
          PARTIAL MATCH c START
              MgmColor.Red -> isRed = TRUE;,
              MgmColor.Green -> isRed = FALSE;,
              MgmColor.Blue -> isRed = FALSE;,
          END
          ASSERT isRed;
    CLEAR
  when :private_fn
    "ASSERT mgmSecret(1.0) == 1000.0;"
  when :private_struct
    <<~CLEAR.strip
      box = MgmSecretBox{ code: 1.0 };
          ASSERT box.code == 1.0;
    CLEAR
  end
end

def mgm_render(graph, symbol)
  case graph
  when :single
    source = <<~CLEAR
      REQUIRE "fuzz_support_mgm_math.clear";

      FN main() RETURNS Void ->
          #{mgm_single_body(symbol)}
      END
    CLEAR
    { source: source, support_files: MGM_SUPPORT.fetch(:math) }
  when :chain
    body =
      if symbol == :pub_fn
        <<~CLEAR.strip
          o = mgmOrigin();
              p = MgmPoint{ x: 3.0, y: 4.0 };
              ASSERT mgmDistSq(o, p) == 25.0;
        CLEAR
      else
        # Transitive type flow: math's struct reaches the root through
        # geometry's return type without a direct REQUIRE of math.
        <<~CLEAR.strip
          o = mgmOrigin();
              ASSERT o.x == 0.0;
              ASSERT o.y == 0.0;
        CLEAR
      end
    requires =
      if symbol == :pub_fn
        # mgmDistSq's MgmPoint parameters are constructed here, so math's
        # constructor must be imported directly (imports are not transitive).
        "REQUIRE \"fuzz_support_mgm_math.clear\";\nREQUIRE \"fuzz_support_mgm_geometry.clear\";"
      else
        "REQUIRE \"fuzz_support_mgm_geometry.clear\";"
      end
    source = <<~CLEAR
      #{requires}

      FN main() RETURNS Void ->
          #{body}
      END
    CLEAR
    { source: source, support_files: MGM_SUPPORT.fetch(:chain) }
  when :diamond
    source = <<~CLEAR
      REQUIRE "fuzz_support_mgm_math.clear";
      REQUIRE "fuzz_support_mgm_geometry.clear";
      REQUIRE "fuzz_support_mgm_stats.clear";

      FN main() RETURNS Void ->
          o = mgmOrigin();
          p = mgmMakePoint(3.0, 4.0);
          ASSERT mgmDistSq(o, p) == 25.0;
          ASSERT mgmSum3(1.0, 2.0, 3.0) == 6.0;
      END
    CLEAR
    { source: source, support_files: MGM_SUPPORT.fetch(:diamond) }
  end
end

FuzzGenerator.register(:module_graph_matrix, cells: MGM_CELLS) do |params|
  mgm_render(params[:graph], params[:symbol])
end
