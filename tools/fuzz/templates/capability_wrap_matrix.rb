# Template: capability-wrap composition matrix.
#
# Targets src/mir/mir_lowering.rb#compose_capability_wrap +
# #lower_with_block + the cap path of #lower_var_decl. Dark arms = the
# sync_fn case (lockedCreate / rwLockedCreate / refCellCreate /
# versionedCreate) and the WITH access form per modality -- the corpus
# only ever declared @locked. Each cell declares a wrapped binding,
# enters the matching WITH, mutates/reads, asserts.
#
# Confirmed syntax (access_gate.rb): @locked/@writeLocked/@versioned +
# WITH EXCLUSIVE/SNAPSHOT. @alwaysMutable / @atomic / storage wraps are
# reserved :in_dev (WITH form not yet confirmed -- reserving matrix
# space, not emitting invalid noise).
#
# expected :pass; a failing/leaking :pass cell is a SURFACED bug.

CWM_CELLS = []
# [sync, with_head, expected]
CWM_MODES = [
  [:locked,         "WITH EXCLUSIVE c AS ref", :pass],
  [:write_locked,   "WITH EXCLUSIVE c AS ref", :pass],
  [:versioned,      "WITH SNAPSHOT c AS ref",  :pass],
  [:always_mutable, nil,                       :in_dev],
  [:atomic,         nil,                       :in_dev],
  [:shared_locked,  nil,                       :in_dev],
]
CWM_MODES.each do |sync, head, exp|
  CWM_CELLS << { sync: sync, head: head, expected: exp }
end

def cwm_sync_decl(sync)
  case sync
  when :locked       then "@locked"
  when :write_locked then "@writeLocked"
  when :versioned    then "@versioned"
  end
end

FuzzGenerator.register(:capability_wrap_matrix, cells: CWM_CELLS) do |p|
  # :in_dev cells render a placeholder; the harness emits them as
  # comments and never runs them.
  if p[:expected] == :in_dev
    next "# in_dev: capability wrap #{p[:sync]} (WITH form unconfirmed)\n"
  end

  <<~CHT
    STRUCT Counter { value: Int64 }

    FN main() RETURNS Void ->
        MUTABLE c = Counter{ value: 1_i64 } #{cwm_sync_decl(p[:sync])};
        #{p[:head]} {
            x: Int64 = ref.value;
            ASSERT x == 1_i64, "#{p[:sync]} wrap read";
        }
        RETURN;
    END
  CHT
end
