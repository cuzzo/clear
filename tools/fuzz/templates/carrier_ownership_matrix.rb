# Retained-identity v5 carrier-ownership matrix
# (docs/agents/retained-identity-design.md, "Declaration-Sited Cost,
# Callee-Sited Correctness").
#
# Cross of source carrier {plain, @multiowned, @shared} x parameter contract
# {polymorphic, unique, shared} x fan-out {none/move, KEEP, COPY} x post-call
# source use. Positive cells run leak-clean under the testing allocator;
# every negative cell REQUIRES its CLEAR diagnostic code (diagnostic_code_
# required) so an invalid-Zig failure can never masquerade as a passing
# rejection.
#
# BLOCKED and intentionally OMITTED: KEEP of a carrier-polymorphic parameter
# whose concrete carrier is plain. That is the carrier-specialization case
# (Phase 4b); it fails CLOSED today with a clear boundary message and is not
# yet end-to-end lowerable. Logged below so the omission is never silent.

CARRIER_OWNERSHIP_CELLS = []

# --- Positive cells: compile and run leak-free ---------------------------
# @multiowned KEEP = non-atomic retain (two live owners observe one identity)
CARRIER_OWNERSHIP_CELLS << { scenario: :keep_multiowned }
# @shared KEEP = atomic retain
CARRIER_OWNERSHIP_CELLS << { scenario: :keep_shared }
# OWN COPY of @multiowned at a UNIQUE boundary = shared->unique detach
CARRIER_OWNERSHIP_CELLS << { scenario: :copy_to_unique }
# last-use move: no retain emitted
CARRIER_OWNERSHIP_CELLS << { scenario: :last_use_move }
# SHARED param with two consuming uses auto-retains (no per-use KEEP)
CARRIER_OWNERSHIP_CELLS << { scenario: :shared_multi_consume }
# OWN COPY detaches an independent payload from a handle into a plain slot
CARRIER_OWNERSHIP_CELLS << { scenario: :own_copy_detach }
# MONOMORPHIC threads each carrier (plain/@multiowned/@shared), leak-free
CARRIER_OWNERSHIP_CELLS << { scenario: :monomorphic_thread }
# KEEP inside a MONOMORPHIC variant resolves per carrier (retain / copy)
CARRIER_OWNERSHIP_CELLS << { scenario: :monomorphic_keep }

# --- Negative cells: each pins its diagnostic ----------------------------
CARRIER_OWNERSHIP_CELLS << { scenario: :keep_plain_local, expected: :compile_error, code: :KEEP_ON_KNOWN_CARRIER }
CARRIER_OWNERSHIP_CELLS << { scenario: :copy_polymorphic_param, expected: :compile_error, code: :COPY_ON_POLYMORPHIC_PARAM }
CARRIER_OWNERSHIP_CELLS << { scenario: :copy_retained_non_unique, expected: :compile_error, code: :COPY_RETAINED_NEEDS_UNIQUE }
CARRIER_OWNERSHIP_CELLS << { scenario: :polymorphic_fanout, expected: :compile_error, code: :CARRIER_POLYMORPHIC_FANOUT }
CARRIER_OWNERSHIP_CELLS << { scenario: :plain_into_shared, expected: :compile_error, code: :ARG_NEEDS_SHARED }
# bare handle into a plain user parameter must be rejected (no silent detach)
CARRIER_OWNERSHIP_CELLS << { scenario: :bare_retained_plain, expected: :compile_error, code: :RETAINED_NEEDS_OWN_COPY }
# bare OWN (move payload out of a handle) is deferred
CARRIER_OWNERSHIP_CELLS << { scenario: :own_alone, expected: :compile_error, code: :OWN_ALONE_UNSUPPORTED }

module CarrierOwnershipMatrixRender
  extend self

  def render(p)
    send(p[:scenario])
  end

  def keep_multiowned
    <<~CLEAR
      STRUCT Cell { n: Int64 }
      FN read(c: Cell) RETURNS Int64 -> RETURN c.n; END
      FN main() RETURNS Void ->
        MUTABLE original = Cell{ n: 7 } @multiowned;
        kept = KEEP original;
        WITH original { ASSERT read(original) == 7, "orig"; }
        WITH kept { ASSERT read(kept) == 7, "kept"; }
        RETURN;
      END
    CLEAR
  end

  def keep_shared
    <<~CLEAR
      STRUCT Cell { n: Int64 }
      FN read(c: Cell) RETURNS Int64 -> RETURN c.n; END
      FN main() RETURNS Void ->
        MUTABLE original = Cell{ n: 11 } @shared;
        kept = KEEP original;
        WITH original { ASSERT read(original) == 11, "orig"; }
        WITH kept { ASSERT read(kept) == 11, "kept"; }
        RETURN;
      END
    CLEAR
  end

  def copy_to_unique
    <<~CLEAR
      STRUCT Doc { version: Int64 }
      FN persist(TAKES d: UNIQUE Doc) RETURNS Int64 -> RETURN d.version; END
      FN main() RETURNS Void ->
        MUTABLE shared = Doc{ version: 3 } @multiowned;
        snap = persist(OWN COPY shared);
        ASSERT snap == 3, "snap";
        shared.version = 9;
        WITH shared { ASSERT shared.version == 9, "advanced"; }
        RETURN;
      END
    CLEAR
  end

  def last_use_move
    <<~CLEAR
      STRUCT Cell { n: Int64 }
      FN main() RETURNS Void ->
        original = Cell{ n: 42 } @multiowned;
        moved = GIVE original;
        WITH moved { ASSERT moved.n == 42, "moved"; }
        RETURN;
      END
    CLEAR
  end

  def shared_multi_consume
    <<~CLEAR
      STRUCT Session { id: Int64 }
      FN sink(TAKES s: SHARED Session) RETURNS Void -> RETURN; END
      FN register(TAKES s: SHARED Session) RETURNS Void -> sink(s); sink(s); RETURN; END
      FN main() RETURNS Void ->
        sess = Session{ id: 4 } @shared;
        register(sess);
        WITH sess { ASSERT sess.id == 4, "intact"; }
        RETURN;
      END
    CLEAR
  end

  def keep_plain_local
    <<~CLEAR
      STRUCT Cell { n: Int64 }
      FN sink(TAKES c: Cell) RETURNS Void -> RETURN; END
      FN main() RETURNS Void ->
        p = Cell{ n: 1 };
        sink(KEEP p);
        sink(p);
        RETURN;
      END
    CLEAR
  end

  def copy_polymorphic_param
    <<~CLEAR
      STRUCT Cell { n: Int64 }
      FN sink(TAKES c: Cell) RETURNS Void -> RETURN; END
      FN foo(TAKES c: Cell) RETURNS Void -> sink(COPY c); sink(c); RETURN; END
      FN main() RETURNS Void -> foo(Cell{ n: 1 }); RETURN; END
    CLEAR
  end

  def copy_retained_non_unique
    <<~CLEAR
      STRUCT Cell { n: Int64 }
      FN sink(TAKES c: Cell) RETURNS Void -> RETURN; END
      FN main() RETURNS Void ->
        MUTABLE s = Cell{ n: 1 } @multiowned;
        sink(COPY s);
        WITH s { ASSERT s.n == 1, "src"; }
        RETURN;
      END
    CLEAR
  end

  def polymorphic_fanout
    <<~CLEAR
      STRUCT Cell { n: Int64 }
      FN sink(TAKES c: Cell) RETURNS Void -> RETURN; END
      FN foo(TAKES c: Cell) RETURNS Void -> sink(c); sink(c); RETURN; END
      FN main() RETURNS Void -> foo(Cell{ n: 1 }); RETURN; END
    CLEAR
  end

  def plain_into_shared
    <<~CLEAR
      STRUCT Session { id: Int64 }
      FN reg(TAKES s: SHARED Session) RETURNS Void -> RETURN; END
      FN main() RETURNS Void ->
        x = Session{ id: 1 };
        reg(x);
        RETURN;
      END
    CLEAR
  end

  def own_copy_detach
    <<~CLEAR
      STRUCT User { id: Int64 }
      FN consume(TAKES u: User) RETURNS Int64 -> RETURN u.id; END
      FN main() RETURNS Void ->
        m = User{ id: 7 } @multiowned;
        ASSERT consume(OWN COPY m) == 7, "detach";
        WITH m { ASSERT m.id == 7, "src alive"; }
        RETURN;
      END
    CLEAR
  end

  def monomorphic_thread
    <<~CLEAR
      STRUCT User { id: Int64 }
      FN consume(TAKES u: MONOMORPHIC User) RETURNS Int64 -> RETURN u.id; END
      FN main() RETURNS Void ->
        p = User{ id: 1 };
        ASSERT consume(p) == 1, "plain";
        m = User{ id: 2 } @multiowned;
        ASSERT consume(m) == 2, "rc";
        s = User{ id: 3 } @shared;
        ASSERT consume(s) == 3, "arc";
        RETURN;
      END
    CLEAR
  end

  def monomorphic_keep
    <<~CLEAR
      STRUCT User { id: Int64 }
      FN cache(TAKES u: MONOMORPHIC User) RETURNS Int64 -> RETURN u.id; END
      FN queue(TAKES u: MONOMORPHIC User) RETURNS Int64 -> RETURN u.id; END
      FN distribute(TAKES u: MONOMORPHIC User) RETURNS Int64 ->
        a = cache(KEEP u);
        b = queue(u);
        RETURN a + b;
      END
      FN main() RETURNS Void ->
        m = User{ id: 2 } @multiowned;
        ASSERT distribute(m) == 4, "rc";
        s = User{ id: 3 } @shared;
        ASSERT distribute(s) == 6, "arc";
        RETURN;
      END
    CLEAR
  end

  def bare_retained_plain
    <<~CLEAR
      STRUCT User { id: Int64 }
      FN consume(TAKES u: User) RETURNS Int64 -> RETURN u.id; END
      FN main() RETURNS Void ->
        m = User{ id: 7 } @multiowned;
        ASSERT consume(m) == 7, "bare handle into plain slot";
        RETURN;
      END
    CLEAR
  end

  def own_alone
    <<~CLEAR
      STRUCT User { id: Int64 }
      FN consume(TAKES u: User) RETURNS Int64 -> RETURN u.id; END
      FN main() RETURNS Void ->
        m = User{ id: 7 } @multiowned;
        ASSERT consume(OWN m) == 7, "bare OWN";
        RETURN;
      END
    CLEAR
  end
end

FuzzGenerator.register(:carrier_ownership_matrix, cells: CARRIER_OWNERSHIP_CELLS) do |p|
  src = CarrierOwnershipMatrixRender.render(p)
  if p[:expected] == :compile_error
    { source: src, error_code: p.fetch(:code), diagnostic_code_required: true }
  else
    src
  end
end
