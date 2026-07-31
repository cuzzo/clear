// Hot observation loop for the Ruby runtime-SCIP collector.
//
// Division of labour: C decides which events matter, builds every observation,
// and derives the value domain (see value_domain.c). Ruby keeps the trace plan
// and the record-wrapper registry, and is asked once per class rather than once
// per event.
//
// Nothing here may call a method the traced program could define. Dispatching
// from inside the hook re-enters the interpreter underneath the event being
// handled, and the collector then corrupts the program it is observing --
// `Array#sort` over a list of shape keys was enough to do it.
//
// Every identity C retains is an interned ID, which is immortal, so the hot path
// allocates no Ruby object and needs no GC marking. The one exception is a
// domain Hash built for a container receiver; those are held in a registered
// Array and referenced by index.

#include <ruby.h>
#include <ruby/debug.h>
#include <ruby/st.h>

#include "value_domain.h"

#define MAX_FRAMES 1024
#define MAX_ALTS 8

typedef struct {
    ID path;          // analyzed-source path, else 0
    int line;         // current source line within that path
    ID caller_class;
    ID caller_method;
    ID caller_kind;
    ID caller_path;
    int caller_line;
    int analyzed;
    struct call_record *record; // set when this frame is an observed callee
    // A demanded state write executes between this :line and the next event in
    // the frame, so the assigned value is read back then rather than now.
    struct state_demand *pending_state;
    ID pending_state_path;
    int pending_state_line;
    // Ruby reports a :return carrying nil for a method left by an exception.
    // That nil is the absence of a result, not a result, so it must not be
    // recorded as one.
    int raised;
    // The file this frame's own method lives in, and its last line there. A
    // block defined elsewhere can run on this frame -- `Hash.new { |h, k| ... }`
    // executes its caller's block during a lookup made here -- and execution
    // resumes mid-expression afterwards, so no :line event puts the coordinate
    // back. Without this every later call on that line is attributed to the
    // block's file and dropped.
    ID home_path;
    int home_line;
} frame_t;

// A c_return does not always report the same coordinate as its c_call, so the
// record a result belongs to is remembered from the call rather than looked up
// again. A rejected call still pushes a sentinel so pairing stays aligned.
typedef struct {
    struct call_record *record;
    ID method;
    ID owner;
    int raised;
} native_frame_t;

typedef struct {
    frame_t frames[MAX_FRAMES];
    int depth;
    native_frame_t natives[MAX_FRAMES];
    int native_depth;
    // `break` out of a block makes the method it was passed to return the break
    // value, but the VM reports that method's return as a synthetic nil. The
    // value is only visible on the block's own return, which is the event
    // immediately before it.
    VALUE last_block_value;
    int last_event_was_block_return;
} thread_state_t;

typedef struct call_record {
    ID caller_class, caller_method, caller_kind, caller_path;
    int caller_line;
    ID callsite_path;
    int callsite_line;
    ID callee_owner, callee_name, callee_kind;
    ID callee_path;
    int callee_line;
    int native;
    ID receiver_type;
    ID receiver_types[MAX_ALTS];
    int n_receiver_types;
    long domain_index[MAX_ALTS]; // Ruby-derived domains for container receivers
    int n_domains;
    ID result_types[MAX_ALTS];
    int n_result_types;
    long result_domain_index[MAX_ALTS];
    int n_result_domains;
    int saw_true, saw_false;
    unsigned long count;
} call_record_t;

static st_table *path_cache;     // path VALUE identity -> 1 analyzed / 2 not
static st_table *identities;      // defined_class identity -> selector -> packed identity
static st_table *demand;
static st_table *demand_in_file;  // path -> selector: demanded somewhere in the file         // path -> selector -> line: demanded coordinates
static st_table *records;        // record identity -> call_record_t*
static st_table *thread_states;  // thread VALUE -> thread_state_t*
static st_table *callsite_hits;  // path -> line -> selector -> count
static st_table *entries;        // path -> line -> owner -> name -> count
static st_table *state_demand;   // path -> line -> demanded state write
static st_table *states;         // path -> line -> owner -> name -> state_record_t*
static st_table *state_owners;   // class identity -> reportable owner name, 0 = skip
// caller path -> caller def line -> callee path -> callee def line -> count.
// Both endpoints are function entries, so their owner and name are read back
// from `entries` at export instead of being stored a second time.
static st_table *edges;
static VALUE roots_ary;          // analyzed-source path prefixes
static VALUE domains_ary;        // Ruby domain Hashes, referenced by index
static VALUE tracepoint;
static VALUE ruby_owner;         // NilKillRuntimeTrace, for delegation
static ID id_call, id_instance, id_return;
static ID id_local_variables, id_local_variable_get, id_callee_identity;

static ID class_name_id(VALUE klass);
static unsigned long counts[8];

static thread_state_t *current_state(void) {
    VALUE thread = rb_thread_current();
    st_data_t found;
    if (st_lookup(thread_states, (st_data_t)thread, &found)) return (thread_state_t *)found;
    thread_state_t *state = ALLOC(thread_state_t);
    state->depth = 0;
    state->native_depth = 0;
    state->last_block_value = Qnil;
    state->last_event_was_block_return = 0;
    st_insert(thread_states, (st_data_t)thread, (st_data_t)state);
    return state;
}

// CRuby hands back the same frozen String for a given iseq, so the analyzed
// decision memoises on identity instead of hashing the path on every event.
static int path_analyzed(VALUE path) {
    st_data_t cached;
    if (st_lookup(path_cache, (st_data_t)path, &cached)) return (int)cached == 1;
    int analyzed = 0;
    if (RB_TYPE_P(path, T_STRING)) {
        for (long i = 0; i < RARRAY_LEN(roots_ary); i++) {
            VALUE root = RARRAY_AREF(roots_ary, i);
            if (RSTRING_LEN(path) >= RSTRING_LEN(root) &&
                memcmp(RSTRING_PTR(path), RSTRING_PTR(root), (size_t)RSTRING_LEN(root)) == 0) {
                analyzed = 1;
                break;
            }
        }
    }
    st_insert(path_cache, (st_data_t)path, (st_data_t)(analyzed ? 1 : 2));
    return analyzed;
}

// Lookups on the event path must not build strings. Both the anchor table and
// the record table nest plain integer tables so a hit costs a few integer hashes
// and no allocation; an earlier snprintf+rb_intern composite key here cost more
// than the rest of the collector combined.
static st_table *nested(st_table *parent, st_data_t key) {
    st_data_t found;
    if (st_lookup(parent, key, &found)) return (st_table *)found;
    st_table *child = st_init_numtable();
    st_insert(parent, key, (st_data_t)child);
    return child;
}

static st_table *nested_lookup(st_table *parent, st_data_t key) {
    st_data_t found;
    return st_lookup(parent, key, &found) ? (st_table *)found : NULL;
}

typedef struct {
    ID owner, kind, path;
    int line;
    int native;
} identity_t;

// A state write is demanded under the bare member name, but reading it back
// needs the ivar's own name, so both are interned once at configure time.
typedef struct state_demand {
    ID name;
    ID ivar;
} state_demand_t;

typedef struct {
    ID types[MAX_ALTS];
    int n_types;
    unsigned long count;
} state_record_t;

// Callee identity is a pure function of (defined class, selector) -- whether the
// method is C-implemented is a property of that pair too, not of the event -- so
// the Ruby round trip that resolves transparent wrappers and declaration sites is
// cached rather than repeated for every record that shares a target.
static identity_t *cached_identity(VALUE defined, ID selector, int native) {
    st_table *by_selector = nested(identities, (st_data_t)defined);
    st_data_t found;
    if (st_lookup(by_selector, (st_data_t)selector, &found)) return (identity_t *)found;

    if (NIL_P(ruby_owner)) {
        ruby_owner = rb_const_get(rb_cObject, rb_intern("NilKillRuntimeTrace"));
    }
    identity_t *identity = ALLOC(identity_t);
    memset(identity, 0, sizeof(*identity));
    identity->native = -1;
    VALUE row = rb_funcall(ruby_owner, id_callee_identity, 3, defined, ID2SYM(selector),
                           native ? Qtrue : Qfalse);
    if (RB_TYPE_P(row, T_ARRAY) && RARRAY_LEN(row) == 5) {
        VALUE o = RARRAY_AREF(row, 0), k = RARRAY_AREF(row, 1);
        VALUE nat = RARRAY_AREF(row, 2), pth = RARRAY_AREF(row, 3);
        VALUE lno = RARRAY_AREF(row, 4);
        if (RB_TYPE_P(o, T_STRING)) identity->owner = rb_intern_str(o);
        if (RB_TYPE_P(k, T_STRING)) identity->kind = rb_intern_str(k);
        if (!NIL_P(nat)) identity->native = RTEST(nat) ? 1 : 0;
        if (RB_TYPE_P(pth, T_STRING)) identity->path = rb_intern_str(pth);
        if (RB_INTEGER_TYPE_P(lno)) identity->line = NUM2INT(lno);
    }
    st_insert(by_selector, (st_data_t)selector, (st_data_t)identity);
    return identity;
}

// An anonymous class has no name the evidence can join on. Module#name itself,
// never an override, and asked once per class because the answer cannot change.
static ID cached_state_owner(VALUE klass) {
    st_data_t found;
    if (st_lookup(state_owners, (st_data_t)klass, &found)) return (ID)found;

    VALUE name = (RB_TYPE_P(klass, T_CLASS) || RB_TYPE_P(klass, T_MODULE))
                     ? rb_mod_name(klass)
                     : Qnil;
    ID owner = RB_TYPE_P(name, T_STRING) ? rb_intern_str(name) : 0;
    st_insert(state_owners, (st_data_t)klass, (st_data_t)owner);
    return owner;
}

// Ruby has no event for an assignment, so a demanded state write is read back
// from the object once the line that performs it has run -- at the frame's next
// :line, or at its :return when the write was the last thing it did. `self` is
// taken from that event, which is the same object the write targeted, so no
// receiver is retained across events.
static void flush_pending_state(frame_t *frame, VALUE self) {
    state_demand_t *want = frame->pending_state;
    if (!want) return;
    frame->pending_state = NULL;
    if (!rb_ivar_defined(self, want->ivar)) return;

    ID owner = cached_state_owner(rb_obj_class(self));
    if (!owner) return;

    st_table *by_line = nested(states, (st_data_t)frame->pending_state_path);
    st_table *by_owner = nested(by_line, (st_data_t)frame->pending_state_line);
    st_table *by_name = nested(by_owner, (st_data_t)owner);
    st_data_t found;
    state_record_t *record;
    if (st_lookup(by_name, (st_data_t)want->name, &found)) {
        record = (state_record_t *)found;
    } else {
        record = ALLOC(state_record_t);
        memset(record, 0, sizeof(*record));
        st_insert(by_name, (st_data_t)want->name, (st_data_t)record);
    }
    record->count++;
    ID type = class_name_id(rb_obj_class(rb_ivar_get(self, want->ivar)));
    if (type) {
        for (int i = 0; i < record->n_types; i++) {
            if (record->types[i] == type) return;
        }
        if (record->n_types < MAX_ALTS) record->types[record->n_types++] = type;
    }
}

static state_demand_t *demanded_state(ID path, int line) {
    st_table *by_line = nested_lookup(state_demand, (st_data_t)path);
    if (!by_line) return NULL;
    st_data_t found;
    return st_lookup(by_line, (st_data_t)line, &found) ? (state_demand_t *)found : NULL;
}

static void bump(st_table *table, st_data_t key) {
    st_data_t count = 0;
    st_lookup(table, key, &count);
    st_insert(table, key, count + 1);
}

// Ruby emits no :line event for the continuation lines of a multiline call, and
// a :call event reports the callee's definition line rather than the caller's.
// So when a selector the plan wants in this file is not demanded at the frame's
// last known line, ask the VM for the caller's real line. rb_profile_frames
// fills a plain int array and allocates nothing, and this only runs for
// selectors the plan actually requests in the file.
static int demanded_in_file(ID path, ID selector) {
    st_table *by_selector = nested_lookup(demand_in_file, (st_data_t)path);
    if (!by_selector) return 0;
    st_data_t found;
    return st_lookup(by_selector, (st_data_t)selector, &found);
}

// Mirrors the Ruby collector's callsite recovery: the interesting frame is the
// nearest one whose path is the analyzed file, not simply the next frame up,
// because a collector-installed wrapper sits in between.
// `callee_path` is the file the entered method is defined in, or 0 for a call
// that pushed no frame of its own. The top VM frame is that method only when the
// two agree -- a method defined by `define_method` does not always appear there
// -- so the callee is skipped by matching it rather than by counting. Counting
// silently walked past the real caller into its caller. rb_profile_frames also
// ignores its own start argument on 3.2, so the offset is applied here.
static int caller_line_from_vm(ID want_path, ID callee_path) {
    VALUE frames[16];
    int lines[16];
    int count = rb_profile_frames(0, 16, frames, lines);
    int skip = 0;
    if (callee_path && count > 0) {
        VALUE top = rb_profile_frame_path(frames[0]);
        if (RB_TYPE_P(top, T_STRING) && rb_intern_str(top) == callee_path) skip = 1;
    }
    for (int i = skip; i < count; i++) {
        if (lines[i] <= 0) continue;
        VALUE path = rb_profile_frame_path(frames[i]);
        if (!RB_TYPE_P(path, T_STRING)) continue;
        if (rb_intern_str(path) == want_path) return lines[i];
    }
    return 0;
}

static int demanded(ID path, int line, ID selector) {
    st_table *by_selector = nested_lookup(demand, (st_data_t)path);
    if (!by_selector) return 0;
    st_table *by_line = nested_lookup(by_selector, (st_data_t)selector);
    if (!by_line) return 0;
    st_data_t found;
    return st_lookup(by_line, (st_data_t)line, &found);
}

static ID class_name_id(VALUE klass) {
    if (NIL_P(klass)) return 0;
    const char *name = rb_class2name(klass);
    return name ? rb_intern(name) : 0;
}

// `def self.foo` reports the singleton class, whose name is not the owner the
// evidence needs. Unwrap to the attached module and report kind "class", which
// is what the Ruby collector's method_owner does.
static ID owner_name_id(VALUE defined, int *class_method) {
    *class_method = 0;
    if (NIL_P(defined)) return 0;
    if (RB_TYPE_P(defined, T_CLASS) && FL_TEST(defined, FL_SINGLETON)) {
        *class_method = 1;
        VALUE attached = rb_iv_get(defined, "__attached__");
        if (!NIL_P(attached) &&
            (RB_TYPE_P(attached, T_CLASS) || RB_TYPE_P(attached, T_MODULE))) {
            return class_name_id(attached);
        }
    }
    return class_name_id(defined);
}

static void add_alt(ID *alts, int *count, ID value) {
    if (!value) return;
    for (int i = 0; i < *count; i++) {
        if (alts[i] == value) return;
    }
    if (*count < MAX_ALTS) alts[(*count)++] = value;
}

static long push_domain(VALUE value) {
    rb_ary_push(domains_ary, nk_value_domain(value));
    return RARRAY_LEN(domains_ary) - 1;
}

static call_record_t *record_for(frame_t *frame, ID selector,
                                 ID owner, ID name, ID kind, int native) {
    // A path+line lies in exactly one method, so callsite plus selector plus
    // dispatched owner is the whole record identity.
    st_table *by_line = nested(records, (st_data_t)frame->path);
    st_table *by_selector = nested(by_line, (st_data_t)frame->line);
    st_table *by_owner = nested(by_selector, (st_data_t)selector);
    st_data_t found;
    if (st_lookup(by_owner, (st_data_t)owner, &found)) return (call_record_t *)found;

    call_record_t *record = ALLOC(call_record_t);
    memset(record, 0, sizeof(*record));
    record->caller_class = frame->caller_class;
    record->caller_method = frame->caller_method;
    record->caller_kind = frame->caller_kind;
    record->caller_path = frame->caller_path;
    record->caller_line = frame->caller_line;
    record->callsite_path = frame->path;
    record->callsite_line = frame->line;
    record->callee_owner = owner;
    record->callee_name = name;
    record->callee_kind = kind;
    record->native = native;
    st_insert(by_owner, (st_data_t)owner, (st_data_t)record);
    return record;
}

// Resolve the record for a call leaving `frame`, or NULL when the plan does not
// demand that callsite. Shared by native calls and by calls into dependency Ruby
// code, which the plan describes identically.
static call_record_t *observed_record(frame_t *frame, rb_trace_arg_t *arg, int native,
                                     int counting) {
    if (!frame->analyzed || !frame->path) return NULL;
    VALUE method = rb_tracearg_method_id(arg);
    if (NIL_P(method)) return NULL;
    ID selector = SYM2ID(method);
    if (!demanded_in_file(frame->path, selector)) return NULL;
    // A :call reports the callee's definition line, so the callsite has to come
    // from the caller's own frame -- which :call has already pushed the callee
    // on top of. The frame's last :line is stale on the continuation lines of a
    // multi-line expression, and demand alone cannot detect that: a selector
    // that is also a parameter name is demanded on every line of the method, so
    // a stale line binds the call to a real but wrong coordinate.
    // A native call pushes no frame of its own, so the top VM frame is already
    // its caller.
    ID callee_path = 0;
    if (!native) {
        VALUE path = rb_tracearg_path(arg);
        if (RB_TYPE_P(path, T_STRING)) callee_path = rb_intern_str(path);
        int line = caller_line_from_vm(frame->path, callee_path);
        if (line) frame->line = line;
    }
    if (!demanded(frame->path, frame->line, selector)) {
        int line = caller_line_from_vm(frame->path, callee_path);
        if (!line || !demanded(frame->path, line, selector)) return NULL;
        frame->line = line;
    }

    VALUE defined = rb_tracearg_defined_class(arg);
    int class_method = 0;
    ID owner = owner_name_id(defined, &class_method);
    ID kind = class_method ? rb_intern("class") : id_instance;
    int resolved_native = native;
    ID resolved_path = 0;
    int resolved_line = 0;
    if (!NIL_P(defined)) {
        identity_t *identity = cached_identity(defined, selector, native);
        if (identity->owner) owner = identity->owner;
        if (identity->kind) kind = identity->kind;
        if (identity->native >= 0) resolved_native = identity->native;
        resolved_path = identity->path;
        resolved_line = identity->line;
    }
    if (counting) {
        bump(nested(nested(callsite_hits, (st_data_t)frame->path), (st_data_t)frame->line),
             (st_data_t)selector);
    }
    call_record_t *record = record_for(frame, selector, owner, selector, kind, resolved_native);
    if (resolved_path && !record->callee_path) {
        record->callee_path = resolved_path;
        record->callee_line = resolved_line;
    }
    // For a :call event the event's own coordinate is the callee's definition
    // site, which is what tells FactMine whether the target is project code it
    // can price or an opaque dependency.
    if (!native && !record->callee_path) {
        VALUE callee_path = rb_tracearg_path(arg);
        if (RB_TYPE_P(callee_path, T_STRING)) {
            record->callee_path = rb_intern_str(callee_path);
            record->callee_line = NUM2INT(rb_tracearg_lineno(arg));
        }
    }
    return record;
}

// Derive a value's domain through Ruby exactly once per (record, class). The
// shapes, singletons and record members Ruby computes are the contract FactMine
// joins against, so approximating them here would only reintroduce a second,
// divergent implementation. Deduplicating on the class keeps this off the
// per-execution path while still covering every observed alternative.
static void record_value(call_record_t *record, VALUE value, int is_result) {
    ID type = class_name_id(rb_obj_class(value));
    ID *seen = is_result ? record->result_types : record->receiver_types;
    int *n_seen = is_result ? &record->n_result_types : &record->n_receiver_types;
    int already = 0;
    for (int i = 0; i < *n_seen; i++) {
        if (seen[i] == type) already = 1;
    }
    add_alt(seen, n_seen, type);
    if (already) return;

    long *slots = is_result ? record->result_domain_index : record->domain_index;
    int *count = is_result ? &record->n_result_domains : &record->n_domains;
    if (*count < MAX_ALTS) slots[(*count)++] = push_domain(value);
}

static void record_receiver(call_record_t *record, VALUE receiver) {
    record->count++;
    if (!record->receiver_type) {
        record->receiver_type = class_name_id(rb_obj_class(receiver));
    }
    record_value(record, receiver, 0);
}

static void record_result(call_record_t *record, VALUE result) {
    if (result == Qtrue) record->saw_true = 1;
    if (result == Qfalse) record->saw_false = 1;
    record_value(record, result, 1);
}

// A FUNCTION_ENTRY anchor is demanded under each parameter's name across the
// method body. At entry the frame's locals are exactly the parameters, so this
// asks the plan per name rather than materialising evidence for every local.
// It runs only on calls into analyzed source, which is a small fraction of
// events, so the Binding it needs is affordable here.
static void observe_parameters(frame_t *frame, rb_trace_arg_t *arg) {
    VALUE binding = rb_tracearg_binding(arg);
    if (NIL_P(binding)) return;
    VALUE names = rb_funcall(binding, id_local_variables, 0);
    if (!RB_TYPE_P(names, T_ARRAY)) return;

    for (long i = 0; i < RARRAY_LEN(names); i++) {
        VALUE name = RARRAY_AREF(names, i);
        if (!SYMBOL_P(name)) continue;
        ID selector = SYM2ID(name);
        if (!demanded(frame->path, frame->line, selector)) continue;

        call_record_t *record =
            record_for(frame, selector, 0, selector, id_instance, 0);
        record_receiver(record, rb_funcall(binding, id_local_variable_get, 1, name));
        bump(nested(nested(callsite_hits, (st_data_t)frame->path), (st_data_t)frame->line),
             (st_data_t)selector);
    }
}

static void observe_native_call(rb_trace_arg_t *arg) {
    thread_state_t *state = current_state();
    VALUE method = rb_tracearg_method_id(arg);
    ID selector = NIL_P(method) ? 0 : SYM2ID(method);
    call_record_t *record = NULL;

    if (state->depth > 0) {
        frame_t *frame = &state->frames[state->depth - 1];
        if (frame->analyzed && frame->path) {
            // A native event carries its own caller coordinate. The frame's last
            // :line is stale whenever no line event fired between it and the
            // call -- inside a block, or partway through a multiline expression
            // -- which is exactly where element access and fetch live.
            frame_t at = *frame;
            VALUE path = rb_tracearg_path(arg);
            if (RB_TYPE_P(path, T_STRING) && path_analyzed(path)) {
                at.path = rb_intern_str(path);
                at.line = NUM2INT(rb_tracearg_lineno(arg));
            }
            record = observed_record(&at, arg, 1, 1);
            if (record) record_receiver(record, rb_tracearg_self(arg));
        }
    }
    if (state->native_depth < MAX_FRAMES) {
        native_frame_t *pending = &state->natives[state->native_depth++];
        pending->record = record;
        pending->method = selector;
        pending->owner = record ? record->callee_owner : 0;
        pending->raised = 0;
    }
}

static void observe_native_return(rb_trace_arg_t *arg) {
    thread_state_t *state = current_state();
    if (state->native_depth == 0) return;
    native_frame_t *pending = &state->natives[state->native_depth - 1];
    VALUE method = rb_tracearg_method_id(arg);
    ID selector = NIL_P(method) ? 0 : SYM2ID(method);
    // VM-generated returns with no matching call must not consume the pending
    // frame; traced native calls are strictly nested so only the top can match.
    if (pending->method != selector) return;
    state->native_depth--;
    // A C method left by an exception still reports a :c_return, carrying nil.
    if (pending->raised) return;
    if (!pending->record) return;
    VALUE result = rb_tracearg_return_value(arg);
    // Recover a `break` value: this call reported nothing, the event before it
    // was its own block returning, and that block produced something. A method
    // that genuinely returns nil is reached either from a nested call's return
    // (`find`) or with no block at all, so neither matches.
    if (NIL_P(result) && state->last_event_was_block_return &&
        !NIL_P(state->last_block_value)) {
        result = state->last_block_value;
    }
    record_result(pending->record, result);
}

// Copy the enclosing analyzed method's identity onto a frame that is executing
// that method's source without being its own frame. Nothing is invented: the
// identity is only ever taken from a frame whose own :call reported this exact
// file, so an unmatched search leaves the frame untouched.
static void inherit_caller(thread_state_t *state, frame_t *frame, ID path) {
    for (int i = state->depth - 2; i >= 0; i--) {
        frame_t *outer = &state->frames[i];
        if (outer->caller_path != path) continue;
        frame->caller_class = outer->caller_class;
        frame->caller_method = outer->caller_method;
        frame->caller_kind = outer->caller_kind;
        frame->caller_path = outer->caller_path;
        frame->caller_line = outer->caller_line;
        return;
    }
}

static void on_event(VALUE tpval, void *_unused) {
    rb_trace_arg_t *arg = rb_tracearg_from_tracepoint(tpval);
    rb_event_flag_t event = rb_tracearg_event_flag(arg);
    if (event != RUBY_EVENT_B_RETURN && event != RUBY_EVENT_C_RETURN) {
        current_state()->last_event_was_block_return = 0;
    }
    switch (event) {
      case RUBY_EVENT_LINE: {
        counts[0]++;
        VALUE path = rb_tracearg_path(arg);
        if (!path_analyzed(path)) return;
        thread_state_t *state = current_state();
        if (state->depth == 0) return;
        frame_t *frame = &state->frames[state->depth - 1];
        ID id = rb_intern_str(path);
        // A block runs in its defining method's source, but the frame on top may
        // belong to whatever yielded to it: Kernel#tap, Enumerable#* and their
        // peers are Ruby methods defined in <internal:...>, so they push a frame
        // of their own carrying no analyzed identity. Attribute the executing
        // line to the innermost frame that really is this file's method -- the
        // same search the Ruby collector runs over caller_locations -- so calls
        // inside the block keep their caller.
        if (frame->caller_path != id) inherit_caller(state, frame, id);
        frame->path = id;
        frame->line = NUM2INT(rb_tracearg_lineno(arg));
        frame->analyzed = 1;
        if (id == frame->home_path) frame->home_line = frame->line;
        // Execution resumed in this frame, so whatever was raised was handled
        // here and the frame will return a real value after all.
        frame->raised = 0;
        if (frame->pending_state) flush_pending_state(frame, rb_tracearg_self(arg));
        state_demand_t *want = demanded_state(id, frame->line);
        if (want) {
            frame->pending_state = want;
            frame->pending_state_path = id;
            frame->pending_state_line = frame->line;
        }
        return;
      }
      case RUBY_EVENT_CALL: {
        counts[1]++;
        thread_state_t *state = current_state();
        VALUE path = rb_tracearg_path(arg);
        int analyzed = path_analyzed(path);
        if (!analyzed && state->depth == 0) return;
        if (state->depth >= MAX_FRAMES) return;
        // A dependency method implemented in Ruby -- Float#positive? and every
        // other <internal:> definition -- reaches the plan through :call, not
        // :c_call, so it is observed here against the calling frame.
        // The callsite lives in the caller, so a project-internal callee is
        // observed exactly like a dependency one.
        call_record_t *observed = NULL;
        frame_t *caller = state->depth > 0 ? &state->frames[state->depth - 1] : NULL;
        if (caller) {
            observed = observed_record(caller, arg, 0, 1);
            if (observed) record_receiver(observed, rb_tracearg_self(arg));
        }
        frame_t *frame = &state->frames[state->depth++];
        memset(frame, 0, sizeof(*frame));
        frame->analyzed = analyzed;
        frame->record = observed;
        if (analyzed) {
            VALUE defined = rb_tracearg_defined_class(arg);
            VALUE method = rb_tracearg_method_id(arg);
            int class_method = 0;
            frame->caller_class = owner_name_id(defined, &class_method);
            frame->caller_method = NIL_P(method) ? 0 : SYM2ID(method);
            frame->caller_kind = class_method ? rb_intern("class") : id_instance;
            frame->caller_path = rb_intern_str(path);
            frame->caller_line = NUM2INT(rb_tracearg_lineno(arg));
            frame->path = frame->caller_path;
            frame->line = frame->caller_line;
            frame->home_path = frame->caller_path;
            frame->home_line = frame->caller_line;
            observe_parameters(frame, arg);
            if (frame->caller_class && frame->caller_method) {
                st_table *by_line = nested(entries, (st_data_t)frame->caller_path);
                st_table *by_owner = nested(by_line, (st_data_t)frame->caller_line);
                st_table *by_name = nested(by_owner, (st_data_t)frame->caller_class);
                bump(by_name, (st_data_t)frame->caller_method);
                // A call between two analyzed methods is a call-graph fact, not
                // evidence about a requested value, so it is recorded whatever
                // the plan asked for.
                if (caller && caller->caller_path && caller->caller_class) {
                    st_table *e1 = nested(edges, (st_data_t)caller->caller_path);
                    st_table *e2 = nested(e1, (st_data_t)caller->caller_line);
                    st_table *e3 = nested(e2, (st_data_t)frame->caller_path);
                    bump(e3, (st_data_t)frame->caller_line);
                }
            }
        }
        return;
      }
      case RUBY_EVENT_RETURN:
        counts[2]++;
        {
            thread_state_t *state = current_state();
            if (state->depth == 0) return;
            frame_t *frame = &state->frames[--state->depth];
            if (frame->pending_state) flush_pending_state(frame, rb_tracearg_self(arg));
            if (frame->raised) {
                // The exception is still travelling, so the caller is leaving
                // the same way unless it goes on to execute a handler.
                if (state->depth > 0) state->frames[state->depth - 1].raised = 1;
                return;
            }
            if (frame->record) record_result(frame->record, rb_tracearg_return_value(arg));
            // A FUNCTION_RETURN anchor is demanded under the selector "return"
            // across the whole method body, so the returning line matches it.
            if (frame->analyzed && frame->path) {
                int line = frame->caller_line;
                if (demanded(frame->path, line, id_return)) {
                    frame_t at = *frame;
                    at.line = line;
                    call_record_t *record =
                        record_for(&at, id_return, 0, id_return, id_instance, 0);
                    record->count++;
                    record_result(record, rb_tracearg_return_value(arg));
                }
            }
        }
        return;
      case RUBY_EVENT_B_RETURN: {
        thread_state_t *state = current_state();
        state->last_block_value = rb_tracearg_return_value(arg);
        state->last_event_was_block_return = 1;
        if (state->depth > 0) {
            frame_t *frame = &state->frames[state->depth - 1];
            if (frame->home_path && frame->path != frame->home_path) {
                frame->path = frame->home_path;
                frame->line = frame->home_line;
            }
        }
        return;
      }
      case RUBY_EVENT_RAISE: {
        thread_state_t *state = current_state();
        if (state->depth > 0) state->frames[state->depth - 1].raised = 1;
        // The raise is attributed to the method that raised, so a native call
        // still in flight under that name is the one being left.
        if (state->native_depth > 0) {
            VALUE method = rb_tracearg_method_id(arg);
            native_frame_t *pending = &state->natives[state->native_depth - 1];
            if (!NIL_P(method) && pending->method == SYM2ID(method)) pending->raised = 1;
        }
        return;
      }
      case RUBY_EVENT_C_CALL:
        counts[3]++;
        observe_native_call(arg);
        return;
      case RUBY_EVENT_C_RETURN:
        counts[4]++;
        observe_native_return(arg);
        return;
      default:
        return;
    }
}

static VALUE nk_configure(VALUE self, VALUE roots, VALUE anchor_map, VALUE state_map) {
    rb_ary_clear(roots_ary);
    for (long i = 0; i < RARRAY_LEN(roots); i++) {
        rb_ary_push(roots_ary, rb_obj_freeze(rb_String(RARRAY_AREF(roots, i))));
    }
    st_clear(demand);
    st_clear(demand_in_file);
    VALUE keys = rb_funcall(anchor_map, rb_intern("keys"), 0);
    for (long i = 0; i < RARRAY_LEN(keys); i++) {
        VALUE parts = rb_str_split(RARRAY_AREF(keys, i), "\1");
        if (RARRAY_LEN(parts) != 3) continue;
        ID path = rb_intern_str(RARRAY_AREF(parts, 0));
        int line = NUM2INT(rb_funcall(RARRAY_AREF(parts, 1), rb_intern("to_i"), 0));
        ID selector = rb_intern_str(RARRAY_AREF(parts, 2));
        st_insert(nested(nested(demand, (st_data_t)path), (st_data_t)selector),
                  (st_data_t)line, 1);
        st_insert(nested(demand_in_file, (st_data_t)path), (st_data_t)selector, 1);
    }
    st_clear(state_demand);
    VALUE state_keys = rb_funcall(state_map, rb_intern("keys"), 0);
    for (long i = 0; i < RARRAY_LEN(state_keys); i++) {
        VALUE key = RARRAY_AREF(state_keys, i);
        VALUE parts = rb_str_split(key, "\1");
        if (RARRAY_LEN(parts) != 3) continue;
        ID path = rb_intern_str(RARRAY_AREF(parts, 0));
        int line = NUM2INT(rb_funcall(RARRAY_AREF(parts, 1), rb_intern("to_i"), 0));
        state_demand_t *want = ALLOC(state_demand_t);
        want->name = rb_intern_str(RARRAY_AREF(parts, 2));
        want->ivar = rb_intern_str(rb_hash_aref(state_map, key));
        st_insert(nested(state_demand, (st_data_t)path), (st_data_t)line, (st_data_t)want);
    }
    return Qtrue;
}

static VALUE nk_start(VALUE self) {
    if (NIL_P(tracepoint)) {
        tracepoint = rb_tracepoint_new(Qnil,
                                       RUBY_EVENT_LINE | RUBY_EVENT_CALL | RUBY_EVENT_RETURN |
                                           RUBY_EVENT_C_CALL | RUBY_EVENT_C_RETURN |
                                           RUBY_EVENT_RAISE | RUBY_EVENT_B_RETURN,
                                       on_event, NULL);
    }
    rb_tracepoint_enable(tracepoint);
    return Qtrue;
}

static VALUE nk_stop(VALUE self) {
    if (!NIL_P(tracepoint)) rb_tracepoint_disable(tracepoint);
    return Qtrue;
}

static VALUE id_or_nil(ID value) {
    return value ? rb_utf8_str_new_cstr(rb_id2name(value)) : Qnil;
}

static int emit_record(st_data_t _key, st_data_t value, st_data_t out) {
    call_record_t *record = (call_record_t *)value;
    VALUE row = rb_hash_new();

    VALUE caller = rb_hash_new();
    rb_hash_aset(caller, ID2SYM(rb_intern("class")), id_or_nil(record->caller_class));
    rb_hash_aset(caller, ID2SYM(rb_intern("method")), id_or_nil(record->caller_method));
    rb_hash_aset(caller, ID2SYM(rb_intern("kind")), id_or_nil(record->caller_kind));
    rb_hash_aset(caller, ID2SYM(rb_intern("path")), id_or_nil(record->caller_path));
    rb_hash_aset(caller, ID2SYM(rb_intern("line")), INT2NUM(record->caller_line));
    rb_hash_aset(row, ID2SYM(rb_intern("caller")), caller);

    VALUE callsite = rb_hash_new();
    rb_hash_aset(callsite, ID2SYM(rb_intern("path")), id_or_nil(record->callsite_path));
    rb_hash_aset(callsite, ID2SYM(rb_intern("line")), INT2NUM(record->callsite_line));
    rb_hash_aset(callsite, ID2SYM(rb_intern("selector")), id_or_nil(record->callee_name));
    rb_hash_aset(row, ID2SYM(rb_intern("callsite")), callsite);

    VALUE callee = rb_hash_new();
    rb_hash_aset(callee, ID2SYM(rb_intern("owner")), id_or_nil(record->callee_owner));
    rb_hash_aset(callee, ID2SYM(rb_intern("name")), id_or_nil(record->callee_name));
    rb_hash_aset(callee, ID2SYM(rb_intern("kind")), id_or_nil(record->callee_kind));
    rb_hash_aset(callee, ID2SYM(rb_intern("native")), record->native ? Qtrue : Qfalse);
    rb_hash_aset(callee, ID2SYM(rb_intern("path")), id_or_nil(record->callee_path));
    rb_hash_aset(callee, ID2SYM(rb_intern("line")),
                 record->callee_path ? INT2NUM(record->callee_line) : Qnil);
    rb_hash_aset(callee, ID2SYM(rb_intern("receiver_type")), id_or_nil(record->receiver_type));
    rb_hash_aset(row, ID2SYM(rb_intern("callee")), callee);

    VALUE types = rb_ary_new();
    for (int i = 0; i < record->n_receiver_types; i++) {
        rb_ary_push(types, id_or_nil(record->receiver_types[i]));
    }
    rb_hash_aset(row, ID2SYM(rb_intern("receiver_types")), types);

    VALUE indices = rb_ary_new();
    for (int i = 0; i < record->n_domains; i++) {
        rb_ary_push(indices, LONG2NUM(record->domain_index[i]));
    }
    rb_hash_aset(row, ID2SYM(rb_intern("receiver_domain_indices")), indices);

    VALUE result_types = rb_ary_new();
    for (int i = 0; i < record->n_result_types; i++) {
        rb_ary_push(result_types, id_or_nil(record->result_types[i]));
    }
    rb_hash_aset(row, ID2SYM(rb_intern("result_types")), result_types);

    VALUE result_indices = rb_ary_new();
    for (int i = 0; i < record->n_result_domains; i++) {
        rb_ary_push(result_indices, LONG2NUM(record->result_domain_index[i]));
    }
    rb_hash_aset(row, ID2SYM(rb_intern("result_domain_indices")), result_indices);

    VALUE truths = rb_ary_new();
    if (record->saw_true) rb_ary_push(truths, Qtrue);
    if (record->saw_false) rb_ary_push(truths, Qfalse);
    rb_hash_aset(row, ID2SYM(rb_intern("result_truths")), truths);
    rb_hash_aset(row, ID2SYM(rb_intern("count")), ULONG2NUM(record->count));

    rb_ary_push((VALUE)out, row);
    return ST_CONTINUE;
}

// The leaf table's values are records; every level above holds st_tables. Depth
// is fixed at four, so walking is a plain nested foreach.
static int emit_owner_level(st_data_t _key, st_data_t value, st_data_t out) {
    st_foreach((st_table *)value, emit_record, out);
    return ST_CONTINUE;
}

static int emit_selector_level(st_data_t _key, st_data_t value, st_data_t out) {
    st_foreach((st_table *)value, emit_owner_level, out);
    return ST_CONTINUE;
}

static int emit_line_level(st_data_t _key, st_data_t value, st_data_t out) {
    st_foreach((st_table *)value, emit_selector_level, out);
    return ST_CONTINUE;
}

static VALUE nk_records(VALUE self) {
    VALUE rows = rb_ary_new();
    st_foreach(records, emit_line_level, (st_data_t)rows);
    return rows;
}

static VALUE nk_domains(VALUE self) { return domains_ary; }

// The tally tables are keyed by interned ids at fixed depth, so each exporter is
// a nested walk that rebuilds the key path as it descends.
static VALUE tally_out;
static ID tally_k1, tally_k2, tally_k3;

static int emit_callsite_leaf(st_data_t selector, st_data_t count, st_data_t _x) {
    VALUE row = rb_ary_new_capa(4);
    rb_ary_push(row, id_or_nil(tally_k1));
    rb_ary_push(row, INT2NUM((int)tally_k2));
    rb_ary_push(row, id_or_nil((ID)selector));
    rb_ary_push(row, ULONG2NUM((unsigned long)count));
    rb_ary_push(tally_out, row);
    return ST_CONTINUE;
}

static int emit_callsite_line(st_data_t line, st_data_t table, st_data_t _x) {
    tally_k2 = (ID)line;
    st_foreach((st_table *)table, emit_callsite_leaf, 0);
    return ST_CONTINUE;
}

static int emit_callsite_path(st_data_t path, st_data_t table, st_data_t _x) {
    tally_k1 = (ID)path;
    st_foreach((st_table *)table, emit_callsite_line, 0);
    return ST_CONTINUE;
}

static VALUE nk_executed_callsites(VALUE self) {
    tally_out = rb_ary_new();
    st_foreach(callsite_hits, emit_callsite_path, 0);
    VALUE rows = tally_out;
    tally_out = Qnil;
    return rows;
}

static int emit_entry_leaf(st_data_t name, st_data_t count, st_data_t _x) {
    VALUE row = rb_ary_new_capa(5);
    rb_ary_push(row, id_or_nil(tally_k1));
    rb_ary_push(row, id_or_nil(tally_k3));
    rb_ary_push(row, id_or_nil((ID)name));
    rb_ary_push(row, INT2NUM((int)tally_k2));
    rb_ary_push(row, ULONG2NUM((unsigned long)count));
    rb_ary_push(tally_out, row);
    return ST_CONTINUE;
}

static int emit_entry_owner(st_data_t owner, st_data_t table, st_data_t _x) {
    tally_k3 = (ID)owner;
    st_foreach((st_table *)table, emit_entry_leaf, 0);
    return ST_CONTINUE;
}

static int emit_entry_line(st_data_t line, st_data_t table, st_data_t _x) {
    tally_k2 = (ID)line;
    st_foreach((st_table *)table, emit_entry_owner, 0);
    return ST_CONTINUE;
}

static int emit_entry_path(st_data_t path, st_data_t table, st_data_t _x) {
    tally_k1 = (ID)path;
    st_foreach((st_table *)table, emit_entry_line, 0);
    return ST_CONTINUE;
}

static VALUE nk_function_entries(VALUE self) {
    tally_out = rb_ary_new();
    st_foreach(entries, emit_entry_path, 0);
    VALUE rows = tally_out;
    tally_out = Qnil;
    return rows;
}

static int emit_state_leaf(st_data_t name, st_data_t value, st_data_t _x) {
    state_record_t *record = (state_record_t *)value;
    VALUE types = rb_ary_new();
    for (int i = 0; i < record->n_types; i++) rb_ary_push(types, id_or_nil(record->types[i]));
    VALUE row = rb_ary_new_capa(5);
    rb_ary_push(row, id_or_nil(tally_k1));
    rb_ary_push(row, INT2NUM((int)tally_k2));
    rb_ary_push(row, id_or_nil(tally_k3));
    rb_ary_push(row, id_or_nil((ID)name));
    rb_ary_push(row, types);
    rb_ary_push(row, ULONG2NUM(record->count));
    rb_ary_push(tally_out, row);
    return ST_CONTINUE;
}

static int emit_state_owner(st_data_t owner, st_data_t table, st_data_t _x) {
    tally_k3 = (ID)owner;
    st_foreach((st_table *)table, emit_state_leaf, 0);
    return ST_CONTINUE;
}

static int emit_state_line(st_data_t line, st_data_t table, st_data_t _x) {
    tally_k2 = (ID)line;
    st_foreach((st_table *)table, emit_state_owner, 0);
    return ST_CONTINUE;
}

static int emit_state_path(st_data_t path, st_data_t table, st_data_t _x) {
    tally_k1 = (ID)path;
    st_foreach((st_table *)table, emit_state_line, 0);
    return ST_CONTINUE;
}

static ID edge_k1, edge_k3;
static int edge_k2;

static int emit_edge_leaf(st_data_t line, st_data_t count, st_data_t _x) {
    VALUE row = rb_ary_new_capa(5);
    rb_ary_push(row, id_or_nil(edge_k1));
    rb_ary_push(row, INT2NUM(edge_k2));
    rb_ary_push(row, id_or_nil(edge_k3));
    rb_ary_push(row, INT2NUM((int)line));
    rb_ary_push(row, ULONG2NUM((unsigned long)count));
    rb_ary_push(tally_out, row);
    return ST_CONTINUE;
}

static int emit_edge_callee_path(st_data_t path, st_data_t table, st_data_t _x) {
    edge_k3 = (ID)path;
    st_foreach((st_table *)table, emit_edge_leaf, 0);
    return ST_CONTINUE;
}

static int emit_edge_caller_line(st_data_t line, st_data_t table, st_data_t _x) {
    edge_k2 = (int)line;
    st_foreach((st_table *)table, emit_edge_callee_path, 0);
    return ST_CONTINUE;
}

static int emit_edge_caller_path(st_data_t path, st_data_t table, st_data_t _x) {
    edge_k1 = (ID)path;
    st_foreach((st_table *)table, emit_edge_caller_line, 0);
    return ST_CONTINUE;
}

static VALUE nk_method_edges(VALUE self) {
    tally_out = rb_ary_new();
    st_foreach(edges, emit_edge_caller_path, 0);
    VALUE rows = tally_out;
    tally_out = Qnil;
    return rows;
}

static VALUE nk_state_values(VALUE self) {
    tally_out = rb_ary_new();
    st_foreach(states, emit_state_path, 0);
    VALUE rows = tally_out;
    tally_out = Qnil;
    return rows;
}

static VALUE nk_stats(VALUE self) {
    VALUE stats = rb_hash_new();
    const char *names[] = {"line", "call", "return", "c_call", "c_return"};
    for (int i = 0; i < 5; i++) {
        rb_hash_aset(stats, ID2SYM(rb_intern(names[i])), ULONG2NUM(counts[i]));
    }
    VALUE rows = nk_records(self);
    rb_hash_aset(stats, ID2SYM(rb_intern("records")), INT2NUM((int)RARRAY_LEN(rows)));
    return stats;
}

static int free_record(st_data_t _key, st_data_t value, st_data_t _arg) {
    xfree((call_record_t *)value);
    return ST_CONTINUE;
}

static int free_owner_level(st_data_t _key, st_data_t value, st_data_t _arg) {
    st_table *table = (st_table *)value;
    st_foreach(table, free_record, 0);
    st_free_table(table);
    return ST_CONTINUE;
}

static int free_selector_level(st_data_t _key, st_data_t value, st_data_t _arg) {
    st_table *table = (st_table *)value;
    st_foreach(table, free_owner_level, 0);
    st_free_table(table);
    return ST_CONTINUE;
}

static int free_line_level(st_data_t _key, st_data_t value, st_data_t _arg) {
    st_table *table = (st_table *)value;
    st_foreach(table, free_selector_level, 0);
    st_free_table(table);
    return ST_CONTINUE;
}

static VALUE nk_set_owner(VALUE self, VALUE owner) {
    ruby_owner = owner;
    return owner;
}

static int free_state(st_data_t _key, st_data_t value, st_data_t _arg) {
    xfree((state_record_t *)value);
    return ST_CONTINUE;
}

static int free_state_owner_level(st_data_t _key, st_data_t value, st_data_t _arg) {
    st_table *table = (st_table *)value;
    st_foreach(table, free_state, 0);
    st_free_table(table);
    return ST_CONTINUE;
}

static int free_state_line_level(st_data_t _key, st_data_t value, st_data_t _arg) {
    st_table *table = (st_table *)value;
    st_foreach(table, free_state_owner_level, 0);
    st_free_table(table);
    return ST_CONTINUE;
}

static int free_state_path_level(st_data_t _key, st_data_t value, st_data_t _arg) {
    st_table *table = (st_table *)value;
    st_foreach(table, free_state_line_level, 0);
    st_free_table(table);
    return ST_CONTINUE;
}

static int free_identity(st_data_t _key, st_data_t value, st_data_t _arg) {
    xfree((identity_t *)value);
    return ST_CONTINUE;
}

static int free_identity_level(st_data_t _key, st_data_t value, st_data_t _arg) {
    st_table *table = (st_table *)value;
    st_foreach(table, free_identity, 0);
    st_free_table(table);
    return ST_CONTINUE;
}

static VALUE nk_reset(VALUE self) {
    st_foreach(records, free_line_level, 0);
    st_clear(records);
    st_clear(path_cache);
    // Identities are keyed by class object, which a later run may not even have
    // loaded, and they encode answers from whichever delegate was installed.
    // Reset means no observation survives, this one included.
    st_foreach(identities, free_identity_level, 0);
    st_clear(identities);
    st_foreach(states, free_state_path_level, 0);
    st_clear(states);
    st_clear(state_owners);
    st_clear(callsite_hits);
    st_clear(entries);
    rb_ary_clear(domains_ary);
    memset(counts, 0, sizeof(counts));
    return Qtrue;
}

void Init_nil_kill_trace(void) {
    VALUE mod = rb_define_module("NilKillTraceNative");
    rb_define_singleton_method(mod, "configure", nk_configure, 3);
    rb_define_singleton_method(mod, "start", nk_start, 0);
    rb_define_singleton_method(mod, "stop", nk_stop, 0);
    rb_define_singleton_method(mod, "records", nk_records, 0);
    rb_define_singleton_method(mod, "domains", nk_domains, 0);
    rb_define_singleton_method(mod, "executed_callsites", nk_executed_callsites, 0);
    rb_define_singleton_method(mod, "function_entries", nk_function_entries, 0);
    rb_define_singleton_method(mod, "state_values", nk_state_values, 0);
    rb_define_singleton_method(mod, "method_edges", nk_method_edges, 0);
    rb_define_singleton_method(mod, "stats", nk_stats, 0);
    rb_define_singleton_method(mod, "reset", nk_reset, 0);
    rb_define_singleton_method(mod, "value_domain_owner=", nk_set_owner, 1);
    nk_value_domain_init(mod);

    path_cache = st_init_numtable();
    demand = st_init_numtable();
    identities = st_init_numtable();
    demand_in_file = st_init_numtable();
    records = st_init_numtable();
    thread_states = st_init_numtable();
    callsite_hits = st_init_numtable();
    entries = st_init_numtable();
    state_demand = st_init_numtable();
    edges = st_init_numtable();
    states = st_init_numtable();
    state_owners = st_init_numtable();
    tally_out = Qnil;
    rb_global_variable(&tally_out);
    tracepoint = Qnil;
    roots_ary = rb_ary_new();
    domains_ary = rb_ary_new();
    rb_global_variable(&tracepoint);
    rb_global_variable(&roots_ary);
    rb_global_variable(&domains_ary);

    id_call = rb_intern("call");
    id_instance = rb_intern("instance");
    id_return = rb_intern("return");
    id_local_variables = rb_intern("local_variables");
    id_local_variable_get = rb_intern("local_variable_get");
    id_callee_identity = rb_intern("native_callee_identity");
    ruby_owner = Qnil;
    rb_global_variable(&ruby_owner);
}
