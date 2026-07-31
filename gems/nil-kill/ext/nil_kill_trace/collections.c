// What a collection was carrying, and who owned it.
//
// A collection reaches the evidence twice: once as a snapshot when something
// takes ownership of it -- a struct field, a parameter -- and again on every
// mutation afterwards. The first says what shape it had; the second says what
// shape it grew into, which is the thing a declared type has to cover.
//
// Ownership is tracked by object id and released by finalizer. Holding the
// collection itself would pin every transient one for the life of the process,
// and an ObjectSpace::WeakMap holds its values weakly, which loses the owners
// of collections that are still alive. A collection that has been collected can
// never be mutated again, so nothing is lost by forgetting it then.
//
// The mutation wrappers are prepended modules, and each is registered with the
// identity rules so the collector both attributes the call to Array/Hash/Set
// and skips the `super` leg that would otherwise be counted a second time.

#include <ruby.h>
#include "collections.h"
#include "identity.h"
#include "value_domain.h"

static VALUE owners_by_object;   // object id -> { owner key -> owner }
// Ruby can reuse an object id before a stale finalizer has run, so eviction is
// checked against the token the entry was made with rather than the id alone.
static VALUE object_tokens;      // object id -> token
static VALUE observations;       // [owner kind, name, path, line, kind] -> record
static VALUE installed;          // the prepended wrappers, held for identity
static ID id_traced, id_hook_guard, id_object_id, id_first, id_respond_to;
static ID id_owner_kind, id_name, id_path, id_line, id_calls;
static VALUE sym_array;

static void registered_hash(VALUE *slot) {
    *slot = rb_hash_new();
    rb_gc_register_address(slot);
}

// The recorder's own bookkeeping mutates Arrays and Hashes, which would
// re-enter the wrappers. One thread-local flag keeps it out of its own way.
static int guard_held(void) {
    return RTEST(rb_thread_local_aref(rb_thread_current(), id_hook_guard));
}

static void guard_set(int held) {
    rb_thread_local_aset(rb_thread_current(), id_hook_guard, held ? Qtrue : Qnil);
}

static VALUE collection_kind(VALUE value) {
    if (RB_TYPE_P(value, T_HASH)) return rb_str_new_cstr("hash");
    if (RB_TYPE_P(value, T_ARRAY)) return rb_str_new_cstr("array");
    return rb_str_new_cstr("set");
}

static VALUE owner_field(VALUE owner, ID field) {
    return rb_hash_aref(owner, ID2SYM(field));
}

static VALUE owner_identity(VALUE owner, VALUE kind) {
    VALUE path = owner_field(owner, id_path);
    VALUE key = rb_ary_new_from_args(
        4, rb_obj_as_string(owner_field(owner, id_owner_kind)),
        rb_obj_as_string(owner_field(owner, id_name)),
        RB_TYPE_P(path, T_STRING) ? nk_abs_path(path) : rb_str_new_cstr(""),
        owner_field(owner, id_line));
    if (!NIL_P(kind)) rb_ary_push(key, kind);
    return key;
}

static VALUE set_field(VALUE record, const char *name) {
    return rb_hash_aref(record, ID2SYM(rb_intern(name)));
}

static VALUE observation_for(VALUE key) {
    VALUE record = rb_hash_lookup2(observations, key, Qundef);
    if (record != Qundef) return record;

    record = rb_hash_new();
    rb_hash_aset(record, ID2SYM(id_calls), INT2NUM(0));
    const char *sets[] = {"classes",     "elem_classes", "key_classes",  "value_classes",
                          "elem_shapes", "key_shapes",   "value_shapes", "mutation_sites"};
    for (size_t i = 0; i < sizeof(sets) / sizeof(sets[0]); i++) {
        rb_hash_aset(record, ID2SYM(rb_intern(sets[i])), rb_hash_new());
    }
    rb_hash_aset(observations, key, record);
    return record;
}

static void merge_into(VALUE record, const char *field, VALUE values) {
    if (NIL_P(values)) return;

    VALUE set = set_field(record, field);
    for (long i = 0; i < RARRAY_LEN(values); i++) {
        rb_hash_aset(set, RARRAY_AREF(values, i), Qtrue);
    }
}

static void record_core(VALUE type_name, VALUE kind, VALUE owner, VALUE elem_classes,
                        VALUE key_classes, VALUE value_classes, VALUE elem_shapes,
                        VALUE key_shapes, VALUE value_shapes, VALUE site) {
    if (NIL_P(owner_field(owner, id_path)) || NIL_P(owner_field(owner, id_line))) return;

    VALUE record = observation_for(owner_identity(owner, kind));
    rb_hash_aset(record, ID2SYM(id_calls),
                 LONG2NUM(NUM2LONG(rb_hash_aref(record, ID2SYM(id_calls))) + 1));
    rb_hash_aset(set_field(record, "classes"), type_name, Qtrue);
    merge_into(record, "elem_classes", elem_classes);
    merge_into(record, "key_classes", key_classes);
    merge_into(record, "value_classes", value_classes);
    merge_into(record, "elem_shapes", elem_shapes);
    merge_into(record, "key_shapes", key_shapes);
    merge_into(record, "value_shapes", value_shapes);
    if (!NIL_P(site)) {
        VALUE sites = set_field(record, "mutation_sites");
        rb_hash_aset(sites, site, LONG2NUM(NUM2LONG(rb_hash_lookup2(sites, site, INT2NUM(0))) + 1));
    }
}

static void record_snapshot(VALUE value, VALUE owner) {
    VALUE shape = nk_container_shape(value);
    if (NIL_P(shape)) return;

    VALUE kind = collection_kind(value);
    VALUE type_name = nk_type_name(value);
    if (RARRAY_AREF(shape, 0) == sym_array) {
        record_core(type_name, kind, owner, RARRAY_AREF(shape, 1), Qnil, Qnil,
                    RARRAY_AREF(shape, 2), Qnil, Qnil, Qnil);
    } else {
        VALUE classes = RARRAY_AREF(shape, 1);
        VALUE shapes = RARRAY_AREF(shape, 2);
        record_core(type_name, kind, owner, Qnil, RARRAY_AREF(classes, 0),
                    RARRAY_AREF(classes, 1), Qnil, RARRAY_AREF(shapes, 0),
                    RARRAY_AREF(shapes, 1), Qnil);
    }
}

// --------------------------------------------------------------- ownership

static VALUE forget_object(RB_BLOCK_CALL_FUNC_ARGLIST(args, packed)) {
    VALUE key = RARRAY_AREF(packed, 0);
    VALUE token = RARRAY_AREF(packed, 1);
    if (rb_hash_lookup2(object_tokens, key, Qundef) != token) return Qnil;

    rb_hash_delete(object_tokens, key);
    rb_hash_delete(owners_by_object, key);
    return Qnil;
}

void nk_register_collection_owner(VALUE value, VALUE owner, VALUE shape) {
    if (NIL_P(nk_container_shape(value))) return;
    if (!RB_TYPE_P(owner, T_HASH)) return;

    if (OBJ_FROZEN(value)) {
        record_snapshot(value, owner);
        return;
    }

    VALUE key = rb_funcall(value, id_object_id, 0);
    VALUE owners = rb_hash_lookup2(owners_by_object, key, Qundef);
    if (owners == Qundef) {
        owners = rb_hash_new();
        rb_hash_aset(owners_by_object, key, owners);
        VALUE token = rb_obj_alloc(rb_cObject);
        rb_hash_aset(object_tokens, key, token);
        rb_define_finalizer(value, rb_proc_new(forget_object, rb_ary_new_from_args(2, key, token)));
        // The wrappers ask this first, so an untracked collection costs one
        // instance-variable read per mutation and nothing else.
        rb_ivar_set(value, id_traced, Qtrue);
    }
    VALUE identity = owner_identity(owner, Qnil);
    if (rb_hash_lookup2(owners, identity, Qundef) == Qundef) {
        rb_hash_aset(owners, identity, owner);
    }
    record_snapshot(value, owner);
}

static VALUE nk_register_owner(int argc, VALUE *argv, VALUE self) {
    VALUE value, owner, shape;
    rb_scan_args(argc, argv, "21", &value, &owner, &shape);
    nk_register_collection_owner(value, owner, shape);
    return Qnil;
}

// ---------------------------------------------------------------- mutation

// The nearest analyzed frame. A mutation made deep inside a library says
// nothing about the source being analyzed.
static VALUE mutation_site(void) {
    VALUE frames =
        rb_funcall(rb_mKernel, rb_intern("caller_locations"), 2, INT2NUM(1), INT2NUM(20));
    if (!RB_TYPE_P(frames, T_ARRAY)) return Qnil;

    for (long i = 0; i < RARRAY_LEN(frames); i++) {
        VALUE frame = RARRAY_AREF(frames, i);
        VALUE where = rb_funcall(frame, rb_intern("absolute_path"), 0);
        if (!RB_TYPE_P(where, T_STRING)) where = rb_funcall(frame, rb_intern("path"), 0);
        if (!RB_TYPE_P(where, T_STRING) || !nk_analyzed_path(where)) continue;

        return rb_sprintf("%" PRIsVALUE ":%" PRIsVALUE, nk_abs_path(where),
                          rb_funcall(frame, rb_intern("lineno"), 0));
    }
    return Qnil;
}

static void record_mutation(VALUE value, VALUE elem, VALUE key, VALUE val, int has_elem,
                            int has_pair) {
    VALUE owners =
        rb_hash_lookup2(owners_by_object, rb_funcall(value, id_object_id, 0), Qundef);
    if (owners == Qundef || RHASH_SIZE(owners) == 0) return;

    VALUE elem_classes = rb_ary_new(), key_classes = rb_ary_new(), value_classes = rb_ary_new();
    VALUE elem_shapes = rb_ary_new(), key_shapes = rb_ary_new(), value_shapes = rb_ary_new();
    if (has_elem) {
        rb_ary_push(elem_classes, nk_type_name(elem));
        VALUE shape = nk_nested_shape(elem);
        if (!NIL_P(shape)) rb_ary_push(elem_shapes, shape);
    }
    if (has_pair) {
        rb_ary_push(key_classes, nk_type_name(key));
        rb_ary_push(value_classes, nk_type_name(val));
        VALUE key_shape = nk_nested_shape(key);
        VALUE value_shape = nk_nested_shape(val);
        if (!NIL_P(key_shape)) rb_ary_push(key_shapes, key_shape);
        if (!NIL_P(value_shape)) rb_ary_push(value_shapes, value_shape);
    }

    VALUE site = mutation_site();
    VALUE kind = collection_kind(value);
    VALUE type_name = nk_type_name(value);
    VALUE list = rb_funcall(owners, rb_intern("values"), 0);
    for (long i = 0; i < RARRAY_LEN(list); i++) {
        record_core(type_name, kind, RARRAY_AREF(list, i), elem_classes, key_classes,
                    value_classes, elem_shapes, key_shapes, value_shapes, site);
    }
}

static void observe_element(VALUE self, VALUE element) {
    if (guard_held()) return;

    guard_set(1);
    record_mutation(self, element, Qnil, Qnil, 1, 0);
    guard_set(0);
}

static void observe_pair(VALUE self, VALUE key, VALUE value) {
    if (guard_held()) return;

    guard_set(1);
    record_mutation(self, Qnil, key, value, 0, 1);
    guard_set(0);
}

static int traced(VALUE self) {
    return RTEST(rb_attr_get(self, id_traced));
}

// ----------------------------------------------------------------- wrappers

static VALUE wrap_one(int argc, VALUE *argv, VALUE self) {
    VALUE result = rb_call_super(argc, argv);
    if (traced(self) && argc > 0) observe_element(self, argv[0]);
    return result;
}

static VALUE wrap_many(int argc, VALUE *argv, VALUE self) {
    VALUE result = rb_call_super(argc, argv);
    if (traced(self)) {
        for (int i = 0; i < argc; i++) observe_element(self, argv[i]);
    }
    return result;
}

static VALUE wrap_index_set(int argc, VALUE *argv, VALUE self) {
    VALUE result = rb_call_super(argc, argv);
    if (traced(self) && argc > 0) observe_element(self, argv[argc - 1]);
    return result;
}

static VALUE wrap_concat(int argc, VALUE *argv, VALUE self) {
    VALUE result = rb_call_super(argc, argv);
    if (!traced(self)) return result;

    for (int i = 0; i < argc; i++) {
        if (!RB_TYPE_P(argv[i], T_ARRAY)) continue;
        for (long at = 0; at < RARRAY_LEN(argv[i]); at++) {
            observe_element(self, RARRAY_AREF(argv[i], at));
        }
    }
    return result;
}

static VALUE wrap_hash_set(int argc, VALUE *argv, VALUE self) {
    VALUE result = rb_call_super(argc, argv);
    if (traced(self) && argc >= 2) observe_pair(self, argv[0], argv[1]);
    return result;
}

static int observe_entry(VALUE key, VALUE value, VALUE self) {
    observe_pair(self, key, value);
    return ST_CONTINUE;
}

static VALUE wrap_hash_merge(int argc, VALUE *argv, VALUE self) {
    VALUE result = rb_call_super(argc, argv);
    if (!traced(self)) return result;

    for (int i = 0; i < argc; i++) {
        if (RB_TYPE_P(argv[i], T_HASH)) rb_hash_foreach(argv[i], observe_entry, self);
    }
    return result;
}

static VALUE wrap_set_merge(int argc, VALUE *argv, VALUE self) {
    VALUE result = rb_call_super(argc, argv);
    if (!traced(self) || argc == 0) return result;
    if (!RTEST(rb_funcall(argv[0], id_respond_to, 1, ID2SYM(id_first)))) return result;

    VALUE sampled = rb_funcall(argv[0], id_first, 1, INT2NUM(20));
    if (!RB_TYPE_P(sampled, T_ARRAY)) return result;
    for (long i = 0; i < RARRAY_LEN(sampled); i++) observe_element(self, RARRAY_AREF(sampled, i));
    return result;
}

typedef VALUE (*wrapper_fn)(int, VALUE *, VALUE);

struct wrapped {
    const char *selector;
    wrapper_fn body;
};

// Prepending twice would stack two wrappers and observe every mutation twice.
static int claim(VALUE klass) {
    if (RTEST(rb_attr_get(klass, rb_intern("@__nil_kill_attached")))) return 0;
    rb_ivar_set(klass, rb_intern("@__nil_kill_attached"), Qtrue);
    return 1;
}

static void install(VALUE klass, const struct wrapped *methods, int count) {
    if (!claim(klass)) return;

    VALUE name = rb_mod_name(klass);
    if (NIL_P(name)) return;

    VALUE module = rb_module_new();
    rb_ary_push(installed, module);
    ID owner = rb_intern_str(name);
    for (int i = 0; i < count; i++) {
        rb_define_method(module, methods[i].selector, methods[i].body, -1);
        // Registering does two jobs: it attributes the call to the class the
        // wrapper stands in front of, and it tells the collector this frame is
        // a wrapper so the `super` beneath it is not counted again.
        nk_register_wrapper(module, rb_intern(methods[i].selector), owner,
                            rb_intern("instance"), 1, 0, 0);
    }
    rb_prepend_module(klass, module);
}

void nk_install_collection_hook(void) {
    static const struct wrapped array_methods[] = {
        {"<<", wrap_one},        {"push", wrap_many},   {"append", wrap_many},
        {"unshift", wrap_many},  {"[]=", wrap_index_set}, {"concat", wrap_concat},
    };
    static const struct wrapped hash_methods[] = {
        {"[]=", wrap_hash_set},    {"store", wrap_hash_set},
        {"merge!", wrap_hash_merge}, {"update", wrap_hash_merge},
    };
    static const struct wrapped set_methods[] = {
        {"add", wrap_one}, {"<<", wrap_one}, {"merge", wrap_set_merge},
    };

    install(rb_cArray, array_methods, 6);
    install(rb_cHash, hash_methods, 4);
    if (rb_const_defined(rb_cObject, rb_intern("Set"))) {
        install(rb_const_get(rb_cObject, rb_intern("Set")), set_methods, 3);
    }
}

static VALUE nk_install_collections(VALUE self) {
    nk_install_collection_hook();
    return Qnil;
}

// ------------------------------------------------------------------ export

static VALUE sorted_keys(VALUE set) {
    return rb_ary_sort(rb_funcall(set, rb_intern("keys"), 0));
}

static int export_observation(VALUE key, VALUE record, VALUE rows) {
    VALUE row = rb_hash_new();
    rb_hash_aset(row, ID2SYM(id_owner_kind), RARRAY_AREF(key, 0));
    rb_hash_aset(row, ID2SYM(id_name), RARRAY_AREF(key, 1));
    rb_hash_aset(row, ID2SYM(id_path), RARRAY_AREF(key, 2));
    rb_hash_aset(row, ID2SYM(id_line), RARRAY_AREF(key, 3));
    rb_hash_aset(row, ID2SYM(rb_intern("kind")), RARRAY_AREF(key, 4));
    rb_hash_aset(row, ID2SYM(id_calls), rb_hash_aref(record, ID2SYM(id_calls)));
    const char *classes[] = {"classes", "elem_classes", "key_classes", "value_classes"};
    for (size_t i = 0; i < sizeof(classes) / sizeof(classes[0]); i++) {
        rb_hash_aset(row, ID2SYM(rb_intern(classes[i])), sorted_keys(set_field(record, classes[i])));
    }
    const char *shapes[] = {"elem_shapes", "key_shapes", "value_shapes"};
    for (size_t i = 0; i < sizeof(shapes) / sizeof(shapes[0]); i++) {
        VALUE keys = sorted_keys(set_field(record, shapes[i]));
        VALUE payloads = rb_ary_new_capa(RARRAY_LEN(keys));
        for (long at = 0; at < RARRAY_LEN(keys); at++) {
            rb_ary_push(payloads, nk_shape_payload(RARRAY_AREF(keys, at)));
        }
        rb_hash_aset(row, ID2SYM(rb_intern(shapes[i])), payloads);
    }
    rb_hash_aset(row, ID2SYM(rb_intern("mutation_sites")), set_field(record, "mutation_sites"));
    rb_ary_push(rows, row);
    return ST_CONTINUE;
}

// How many collections are currently attributed to an owner. The graph is
// keyed by object id and pruned by finalizer, so this is what says the pruning
// happens: it must not grow without bound as transient collections are made.
static VALUE nk_tracked_collections(VALUE self) {
    return LONG2NUM(RHASH_SIZE(owners_by_object));
}

// Only so a spec can prove the reuse guard; the collector never asks.
static VALUE nk_tracks_collection(VALUE self, VALUE value) {
    return rb_hash_lookup2(owners_by_object, rb_funcall(value, id_object_id, 0), Qundef) ==
                   Qundef
               ? Qfalse
               : Qtrue;
}

static VALUE nk_collection_observations(VALUE self) {
    VALUE rows = rb_ary_new();
    rb_hash_foreach(observations, export_observation, rows);
    return rows;
}

void nk_collections_init(VALUE mod) {
    registered_hash(&owners_by_object);
    registered_hash(&observations);
    registered_hash(&object_tokens);
    installed = rb_ary_new();
    rb_gc_register_address(&installed);

    id_traced = rb_intern("@__nil_kill_traced");
    id_hook_guard = rb_intern("__nil_kill_collection_hook");
    id_object_id = rb_intern("object_id");
    id_first = rb_intern("first");
    id_respond_to = rb_intern("respond_to?");
    id_owner_kind = rb_intern("owner_kind");
    id_name = rb_intern("name");
    id_path = rb_intern("path");
    id_line = rb_intern("line");
    id_calls = rb_intern("calls");
    sym_array = ID2SYM(rb_intern("array"));

    rb_define_singleton_method(mod, "install_collection_hook", nk_install_collections, 0);
    rb_define_singleton_method(mod, "register_collection_owner", nk_register_owner, -1);
    rb_define_singleton_method(mod, "collection_observations", nk_collection_observations, 0);
    rb_define_singleton_method(mod, "tracked_collections", nk_tracked_collections, 0);
    rb_define_singleton_method(mod, "tracks_collection?", nk_tracks_collection, 1);
}
