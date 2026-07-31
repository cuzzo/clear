// What the VM saw, before anything decides what it means.
//
// Deriving a value domain -- what counts as a shape, when a fixed-length mixed
// array is a tuple rather than an array, singleton versus type, which sampled
// classes make two collections "the same shape" -- is the same arithmetic in
// every language. Only the questions underneath it need an interpreter: name
// this object's class, sample its container, list a record's fields, find the
// file its class was declared in.
//
// This emits the answers to those questions and stops. A shim for another
// language owes exactly this tree; the rules that read it are written once,
// elsewhere.

#include <ruby.h>
#include "raw_observation.h"
#include "value_domain.h"

// One deeper than the deepest rule that reads this (collections recurse three
// levels below a nested shape, itself one below the observed value), so a
// consumer can apply its own cut-off rather than inherit one from here.
#define NK_RAW_DEPTH 5

static VALUE key_type, key_singleton, key_source, key_kind, key_elements, key_pairs, key_fields;
static VALUE kind_scalar, kind_array, kind_hash, kind_set, kind_record;
static VALUE set_class;
static long element_sample = 20;

static VALUE raw_observe(VALUE value, long depth);

static VALUE frozen(const char *text) {
    VALUE string = rb_obj_freeze(rb_utf8_str_new_cstr(text));
    rb_gc_register_mark_object(string);
    return string;
}

static int is_set(VALUE value) {
    return !NIL_P(set_class) && RTEST(rb_obj_is_kind_of(value, set_class));
}

struct raw_sample {
    VALUE out;
    long remaining;
    int pairs;
    long depth;
};

static int raw_sample_entry(VALUE key, VALUE value, VALUE packed) {
    struct raw_sample *sample = (struct raw_sample *)packed;
    if (sample->remaining <= 0) return ST_STOP;

    if (sample->pairs) {
        rb_ary_push(sample->out, rb_ary_new_from_args(2, raw_observe(key, sample->depth),
                                                      raw_observe(value, sample->depth)));
    } else {
        rb_ary_push(sample->out, raw_observe(key, sample->depth));
    }
    sample->remaining--;
    return ST_CONTINUE;
}

// A Set is a Hash underneath, and asking it for `each` would dispatch a method
// the traced program may have redefined.
static VALUE set_hash(VALUE value) {
    VALUE hash = rb_ivar_get(value, rb_intern("@hash"));
    return RB_TYPE_P(hash, T_HASH) ? hash : Qnil;
}

static VALUE raw_elements(VALUE value, long depth) {
    VALUE out = rb_ary_new();
    if (RB_TYPE_P(value, T_ARRAY)) {
        long length = RARRAY_LEN(value);
        long sampled = length < element_sample ? length : element_sample;
        for (long i = 0; i < sampled; i++) {
            rb_ary_push(out, raw_observe(RARRAY_AREF(value, i), depth));
        }
        return out;
    }
    VALUE hash = set_hash(value);
    if (NIL_P(hash)) return out;

    struct raw_sample sample = {out, element_sample, 0, depth};
    rb_hash_foreach(hash, raw_sample_entry, (VALUE)&sample);
    return out;
}

static VALUE raw_pairs(VALUE value, long depth) {
    VALUE out = rb_ary_new();
    struct raw_sample sample = {out, element_sample, 1, depth};
    rb_hash_foreach(value, raw_sample_entry, (VALUE)&sample);
    return out;
}

// Struct's own members and reader, never an application override: a record may
// define `#members` or `#[]` as part of its own DSL.
static VALUE raw_fields(VALUE value, long depth) {
    VALUE fields = rb_struct_members(value);
    VALUE out = rb_ary_new();
    if (!RB_TYPE_P(fields, T_ARRAY)) return out;

    for (long i = 0; i < RARRAY_LEN(fields); i++) {
        VALUE field = RARRAY_AREF(fields, i);
        VALUE name = RB_TYPE_P(field, T_SYMBOL) ? rb_sym2str(field) : rb_obj_as_string(field);
        rb_ary_push(out, rb_ary_new_from_args(2, name,
                                              raw_observe(rb_struct_aref(value, field), depth)));
    }
    return out;
}

static VALUE raw_observe(VALUE value, long depth) {
    VALUE observation = rb_hash_new();
    rb_hash_aset(observation, key_type, nk_type_name(value));

    // A module used as a strategy dispatches through its constant identity, so
    // that identity is reported next to the nominal type rather than instead.
    if (RB_TYPE_P(value, T_CLASS) || RB_TYPE_P(value, T_MODULE)) {
        VALUE name = nk_guard((VALUE (*)(VALUE))rb_mod_name, value, Qnil);
        if (!NIL_P(name)) rb_hash_aset(observation, key_singleton, name);
    }

    VALUE source = nk_value_source_path(value);
    if (!NIL_P(source)) rb_hash_aset(observation, key_source, source);

    int array = RB_TYPE_P(value, T_ARRAY);
    int hash = RB_TYPE_P(value, T_HASH);
    int set = !array && !hash && is_set(value);
    int record = !array && !hash && !set && RTEST(rb_obj_is_kind_of(value, rb_cStruct));

    if (!array && !hash && !set && !record) {
        rb_hash_aset(observation, key_kind, kind_scalar);
        return observation;
    }
    rb_hash_aset(observation, key_kind,
                 array ? kind_array : hash ? kind_hash : set ? kind_set : kind_record);

    // Below the emitted depth a consumer has the class name and nothing else,
    // which is exactly what every rule falls back to when it runs out of depth.
    if (depth <= 0) return observation;

    if (array || set) {
        rb_hash_aset(observation, key_elements, raw_elements(value, depth - 1));
    } else if (hash) {
        rb_hash_aset(observation, key_pairs, raw_pairs(value, depth - 1));
    } else {
        rb_hash_aset(observation, key_fields, raw_fields(value, depth - 1));
    }
    return observation;
}

VALUE nk_raw_observation(VALUE value) {
    return nk_guard(raw_observe_guarded, value, rb_hash_new());
}

VALUE raw_observe_guarded(VALUE value) {
    return raw_observe(value, NK_RAW_DEPTH);
}

static VALUE nk_raw(VALUE self, VALUE value) {
    (void)self;
    return nk_raw_observation(value);
}

void nk_raw_observation_init(VALUE mod) {
    key_type = frozen("type");
    key_singleton = frozen("singleton");
    key_source = frozen("source");
    key_kind = frozen("kind");
    key_elements = frozen("elements");
    key_pairs = frozen("pairs");
    key_fields = frozen("fields");
    kind_scalar = frozen("scalar");
    kind_array = frozen("array");
    kind_hash = frozen("hash");
    kind_set = frozen("set");
    kind_record = frozen("record");

    set_class = rb_const_defined(rb_cObject, rb_intern("Set"))
                    ? rb_const_get(rb_cObject, rb_intern("Set"))
                    : Qnil;
    if (!NIL_P(set_class)) rb_gc_register_mark_object(set_class);

    const char *sample = getenv("NIL_KILL_ELEMENT_SAMPLE");
    if (sample && *sample) {
        long parsed = atol(sample);
        if (parsed > 0) element_sample = parsed;
    }

    rb_define_singleton_method(mod, "raw_observation", nk_raw, 1);
}
