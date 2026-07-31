// The declaration hooks: wrappers the collector installs so that a call
// reaching a generated or library-provided method can still be attributed to
// what the source actually declared.
//
// Each hook installs a wrapper and tells the identity registry what that
// wrapper stands for. The wrapper itself must stay as close to invisible as a
// method can be: it forwards every argument, keyword and block unchanged, and
// returns exactly what the original returned. A hook that changes what the
// traced program computes has already failed, whatever it records.

#include <ruby.h>
#include <ruby/encoding.h>
#include <ruby/st.h>
#include "declarations.h"
#include "identity.h"
#include "value_domain.h"

static ID id_orig_let, id_let, id_method, id_source_location, id_respond_to;
static ID id_caller_locations, id_absolute_path, id_path, id_lineno;

static VALUE hooked_tlet_owner = Qnil;

// The sites the plan asks about, and what was seen at each. Keyed by interned
// absolute path and line, so a hit costs two integer hashes and no allocation.
static st_table *tlet_sites;
static st_table *tlet_seen;

typedef struct {
    unsigned long calls;
    VALUE classes; // a Hash used as a set of type-name Strings
} tlet_record_t;

static st_table *nested_table(st_table *parent, st_data_t key) {
    st_data_t found;
    if (st_lookup(parent, key, &found)) return (st_table *)found;

    st_table *child = st_init_numtable();
    st_insert(parent, key, (st_data_t)child);
    return child;
}

static int tlet_planned(ID path, int line) {
    st_data_t found;
    if (!st_lookup(tlet_sites, (st_data_t)path, &found)) return 0;
    st_data_t hit;
    return st_lookup((st_table *)found, (st_data_t)(long)line, &hit);
}

static tlet_record_t *tlet_record_for(ID path, int line) {
    st_table *by_line = nested_table(tlet_seen, (st_data_t)path);
    st_data_t found;
    if (st_lookup(by_line, (st_data_t)(long)line, &found)) return (tlet_record_t *)found;

    tlet_record_t *record = ALLOC(tlet_record_t);
    record->calls = 0;
    record->classes = rb_hash_new();
    rb_gc_register_address(&record->classes);
    st_insert(by_line, (st_data_t)(long)line, (st_data_t)record);
    return record;
}

// `T.let(value, type)` is an assertion the program makes about its own data.
// The collector wants the call attributed to `T.let` rather than to the wrapper
// standing in front of it; the value itself is observed at the callsite like
// any other, so nothing is recorded here.
static VALUE nk_tlet(int argc, VALUE *argv, VALUE self) {
    if (argc > 0) {
        VALUE frames = rb_funcall(rb_mKernel, id_caller_locations, 2, INT2NUM(1), INT2NUM(1));
        if (RB_TYPE_P(frames, T_ARRAY) && RARRAY_LEN(frames) > 0) {
            VALUE frame = RARRAY_AREF(frames, 0);
            VALUE where = rb_funcall(frame, id_absolute_path, 0);
            if (!RB_TYPE_P(where, T_STRING)) where = rb_funcall(frame, id_path, 0);
            if (RB_TYPE_P(where, T_STRING)) {
                ID path = rb_intern_str(nk_abs_path(where));
                int line = NUM2INT(rb_funcall(frame, id_lineno, 0));
                if (tlet_planned(path, line)) {
                    tlet_record_t *record = tlet_record_for(path, line);
                    record->calls++;
                    rb_hash_aset(record->classes, nk_type_name(argv[0]), Qtrue);
                }
            }
        }
    }
    return rb_funcallv_kw(self, id_orig_let, argc, argv, RB_PASS_CALLED_KEYWORDS);
}

// The plan names its sites as "<absolute path>\0<line>", which is how the
// collector is handed them and how it keeps them.
static VALUE nk_configure_tlet_sites(VALUE self, VALUE sites) {
    st_clear(tlet_sites);
    if (!RB_TYPE_P(sites, T_HASH)) return Qnil;

    VALUE keys = rb_funcall(sites, rb_intern("keys"), 0);
    for (long i = 0; i < RARRAY_LEN(keys); i++) {
        VALUE key = RARRAY_AREF(keys, i);
        if (!RB_TYPE_P(key, T_STRING)) continue;
        if (!RTEST(rb_hash_aref(sites, key))) continue;

        const char *text = RSTRING_PTR(key);
        long length = RSTRING_LEN(key);
        long split = -1;
        for (long at = 0; at < length; at++) {
            if (text[at] == 0) { split = at; break; }
        }
        if (split < 0) continue;

        ID path = rb_intern3(text, split, rb_utf8_encoding());
        int line = atoi(text + split + 1);
        st_insert(nested_table(tlet_sites, (st_data_t)path), (st_data_t)(long)line, 1);
    }
    return Qnil;
}

struct tlet_export {
    VALUE rows;
    ID path;
};

static int export_tlet_line(st_data_t line, st_data_t value, st_data_t packed) {
    struct tlet_export *export = (struct tlet_export *)packed;
    tlet_record_t *record = (tlet_record_t *)value;
    VALUE row = rb_hash_new();
    rb_hash_aset(row, ID2SYM(rb_intern("path")), rb_id2str(export->path));
    rb_hash_aset(row, ID2SYM(rb_intern("line")), INT2NUM((int)(long)line));
    rb_hash_aset(row, ID2SYM(rb_intern("calls")), ULONG2NUM(record->calls));
    rb_hash_aset(row, ID2SYM(rb_intern("classes")),
                 rb_ary_sort(rb_funcall(record->classes, rb_intern("keys"), 0)));
    rb_ary_push(export->rows, row);
    return ST_CONTINUE;
}

static int export_tlet_path(st_data_t path, st_data_t by_line, st_data_t packed) {
    struct tlet_export export = {(VALUE)packed, (ID)path};
    st_foreach((st_table *)by_line, export_tlet_line, (st_data_t)&export);
    return ST_CONTINUE;
}

static VALUE nk_tlet_observations(VALUE self) {
    VALUE rows = rb_ary_new();
    st_foreach(tlet_seen, export_tlet_path, (st_data_t)rows);
    return rows;
}

static VALUE tlet_source_location(VALUE owner) {
    VALUE method = rb_funcall(owner, id_method, 1, ID2SYM(id_let));
    return rb_funcall(method, id_source_location, 0);
}

// Sorbet may not be loaded, and when it is, `T` is an ordinary module whose
// `let` is an ordinary method. Both are asked for rather than assumed.
void nk_install_tlet_hook(void) {
    if (!NIL_P(hooked_tlet_owner)) return;
    if (!rb_const_defined(rb_cObject, rb_intern("T"))) return;

    VALUE owner = rb_const_get(rb_cObject, rb_intern("T"));
    if (!RB_TYPE_P(owner, T_MODULE) && !RB_TYPE_P(owner, T_CLASS)) return;

    VALUE singleton = rb_singleton_class(owner);
    if (rb_method_boundp(singleton, id_orig_let, 0)) return;
    if (!RTEST(rb_funcall(owner, id_respond_to, 1, ID2SYM(id_let)))) return;

    VALUE location = nk_guard(tlet_source_location, owner, Qnil);
    rb_define_alias(singleton, "__nil_kill_orig_let", "let");
    rb_define_singleton_method(owner, "let", nk_tlet, -1);

    ID path = 0;
    int line = 0;
    if (RB_TYPE_P(location, T_ARRAY) && RARRAY_LEN(location) >= 2) {
        VALUE where = RARRAY_AREF(location, 0);
        VALUE at = RARRAY_AREF(location, 1);
        if (RB_TYPE_P(where, T_STRING)) path = rb_intern_str(where);
        if (RB_INTEGER_TYPE_P(at)) line = NUM2INT(at);
    }
    nk_register_wrapper(singleton, id_let, rb_intern("T"), rb_intern("class"), 0, path, line);

    hooked_tlet_owner = owner;
    rb_gc_register_address(&hooked_tlet_owner);
}

static VALUE nk_install_tlet(VALUE self) {
    nk_install_tlet_hook();
    return Qnil;
}

void nk_declarations_init(VALUE mod) {
    id_orig_let = rb_intern("__nil_kill_orig_let");
    id_let = rb_intern("let");
    id_method = rb_intern("method");
    id_source_location = rb_intern("source_location");
    id_respond_to = rb_intern("respond_to?");
    id_caller_locations = rb_intern("caller_locations");
    id_absolute_path = rb_intern("absolute_path");
    id_path = rb_intern("path");
    id_lineno = rb_intern("lineno");
    tlet_sites = st_init_numtable();
    tlet_seen = st_init_numtable();

    rb_define_singleton_method(mod, "install_tlet_hook", nk_install_tlet, 0);
    rb_define_singleton_method(mod, "configure_tlet_sites", nk_configure_tlet_sites, 1);
    rb_define_singleton_method(mod, "tlet_observations", nk_tlet_observations, 0);
}
