// What a runtime value tells you about its type: its class, the container
// element/key/value classes it was carrying, the record layout it had, and
// whether the code that declared it is production code.
//
// This ran in Ruby and the collector called back into it once per distinct
// receiver class per callsite. That callback was the last thing forcing
// nil-kill's own Ruby to be loaded into a traced program.
//
// Two rules here are only correct because they are copied rather than
// improved. Container shapes are keyed by the classes a collection was
// carrying, so two collections with the same element class share one shape --
// which, for a collection of records, means the first layout seen wins. And a
// sample is the first ELEMENT_SAMPLE entries in iteration order, not a random
// draw. Both are the contract FactMine already joins against.

#include <ruby.h>
#include <ruby/encoding.h>
#include <ruby/st.h>
#include "value_domain.h"

#define VD_COLLECTION_DEPTH 3
#define VD_RECORD_DEPTH 2

// Memoised per class, because a class's name and declaration site cannot
// change once it has one.
static VALUE cls_name_memo;      // Class -> String
static VALUE value_source_memo;  // Class -> String path, or nil
static VALUE shape_lookup;       // shape key String -> payload Hash
static VALUE ctsk_memo;          // element-class signature -> shape key String
static VALUE abs_path_memo;      // String -> String
static VALUE nonproduction_paths;   // absolute path String -> true
static VALUE nonproduction_source;  // the NIL_KILL_SOURCE_ROLES value it was built from
static VALUE root_path;
static VALUE set_class;
static VALUE json_module;
static long element_sample;

static VALUE str_untyped, str_empty_sym, str_h_sym;
static VALUE key_kind, key_name, key_elements, key_keys, key_values, key_members;
static VALUE sym_kind, sym_name, sym_members;
static VALUE val_class, val_record, val_array, val_hash, val_set;
static ID id_types, id_singletons, id_elements, id_keys, id_values, id_shapes,
    id_nonproduction;
static ID id_generate, id_parse, id_const_source_location, id_file_p, id_read,
    id_instance_methods, id_instance_method, id_source_location, id_aref;

static VALUE vd_shape_key_for_collection(VALUE value, long depth);
static VALUE vd_record_shape_key(VALUE value, long depth);
static VALUE vd_production_shape(VALUE shape);
static int vd_nonproduction_type_name(VALUE name);

static VALUE vd_immortal(VALUE value) {
    rb_gc_register_mark_object(value);
    return value;
}

static VALUE vd_frozen_str(const char *text) {
    return vd_immortal(rb_obj_freeze(rb_str_new_cstr(text)));
}

static void vd_registered_hash(VALUE *slot) {
    *slot = rb_hash_new();
    rb_gc_register_address(slot);
}

// Ruby rescued StandardError around every reflective step, so a class that
// answers its own questions badly cannot abort the traced program. An
// Interrupt is not that, and must still reach the workload.
struct vd_guarded {
    VALUE (*fn)(VALUE);
    VALUE arg;
};

static VALUE vd_guarded_call(VALUE packed) {
    struct vd_guarded *call = (struct vd_guarded *)packed;
    return call->fn(call->arg);
}

static VALUE vd_guard(VALUE (*fn)(VALUE), VALUE arg, VALUE fallback) {
    struct vd_guarded call = {fn, arg};
    int state = 0;
    VALUE result = rb_protect(vd_guarded_call, (VALUE)&call, &state);
    if (!state) return result;

    VALUE error = rb_errinfo();
    rb_set_errinfo(Qnil);
    if (!NIL_P(error) && !rb_obj_is_kind_of(error, rb_eStandardError)) {
        rb_exc_raise(error);
    }
    return fallback;
}

static VALUE vd_json(void) {
    if (NIL_P(json_module)) {
        json_module = rb_const_get(rb_cObject, rb_intern("JSON"));
        rb_gc_register_address(&json_module);
    }
    return json_module;
}

static void vd_json_write(VALUE object, VALUE out);

// A shape's JSON text orders the shapes in a domain and identifies a record
// layout, so it has to be exactly what JSON.generate produced. Shapes are
// built here out of strings, arrays and hashes only, so writing them is a
// straight walk -- and one that dispatches no application method, which
// matters because this runs inside the observation hook.
static void vd_json_write_string(VALUE string, VALUE out) {
    const char *text = RSTRING_PTR(string);
    long length = RSTRING_LEN(string);
    rb_str_cat_cstr(out, "\"");
    for (long i = 0; i < length; i++) {
        unsigned char c = (unsigned char)text[i];
        switch (c) {
        case '"': rb_str_cat_cstr(out, "\\\""); break;
        case '\\': rb_str_cat_cstr(out, "\\\\"); break;
        case '\b': rb_str_cat_cstr(out, "\\b"); break;
        case '\f': rb_str_cat_cstr(out, "\\f"); break;
        case '\n': rb_str_cat_cstr(out, "\\n"); break;
        case '\r': rb_str_cat_cstr(out, "\\r"); break;
        case '\t': rb_str_cat_cstr(out, "\\t"); break;
        default:
            if (c < 0x20) {
                rb_str_catf(out, "\\u%04x", c);
            } else {
                rb_str_cat(out, (const char *)&c, 1);
            }
        }
    }
    rb_str_cat_cstr(out, "\"");
}

struct vd_json_object {
    VALUE out;
    int written;
};

static int vd_json_write_pair(VALUE key, VALUE value, VALUE packed) {
    struct vd_json_object *object = (struct vd_json_object *)packed;
    if (object->written++) rb_str_cat_cstr(object->out, ",");
    vd_json_write_string(RB_TYPE_P(key, T_SYMBOL) ? rb_sym2str(key) : key, object->out);
    rb_str_cat_cstr(object->out, ":");
    vd_json_write(value, object->out);
    return ST_CONTINUE;
}

static void vd_json_write(VALUE object, VALUE out) {
    if (NIL_P(object)) {
        rb_str_cat_cstr(out, "null");
    } else if (RB_TYPE_P(object, T_STRING)) {
        vd_json_write_string(object, out);
    } else if (RB_TYPE_P(object, T_SYMBOL)) {
        vd_json_write_string(rb_sym2str(object), out);
    } else if (RB_TYPE_P(object, T_ARRAY)) {
        rb_str_cat_cstr(out, "[");
        for (long i = 0; i < RARRAY_LEN(object); i++) {
            if (i > 0) rb_str_cat_cstr(out, ",");
            vd_json_write(RARRAY_AREF(object, i), out);
        }
        rb_str_cat_cstr(out, "]");
    } else if (RB_TYPE_P(object, T_HASH)) {
        struct vd_json_object nested = {out, 0};
        rb_str_cat_cstr(out, "{");
        rb_hash_foreach(object, vd_json_write_pair, (VALUE)&nested);
        rb_str_cat_cstr(out, "}");
    } else {
        rb_str_append(out, rb_funcall(vd_json(), id_generate, 1, object));
    }
}

static VALUE vd_json_generate(VALUE object) {
    VALUE out = rb_str_new(0, 0);
    vd_json_write(object, out);
    return out;
}

static int vd_is_set(VALUE value) {
    return !NIL_P(set_class) && RTEST(rb_obj_is_kind_of(value, set_class));
}

static int vd_is_struct(VALUE value) {
    return RTEST(rb_obj_is_kind_of(value, rb_cStruct));
}

static int vd_is_collection(VALUE value) {
    return RB_TYPE_P(value, T_ARRAY) || RB_TYPE_P(value, T_HASH) || vd_is_set(value);
}

static VALUE vd_abs_path(VALUE path);
static VALUE vd_class_name(VALUE value);

VALUE nk_abs_path(VALUE path) { return vd_abs_path(path); }
VALUE nk_root_path(void) { return root_path; }
VALUE nk_type_name(VALUE value) { return vd_class_name(value); }
VALUE nk_guard(VALUE (*fn)(VALUE), VALUE arg, VALUE fallback) { return vd_guard(fn, arg, fallback); }

static VALUE vd_abs_path(VALUE path) {
    VALUE cached = rb_hash_lookup2(abs_path_memo, path, Qundef);
    if (cached != Qundef) return cached;

    VALUE absolute = rb_file_expand_path(path, root_path);
    rb_hash_aset(abs_path_memo, rb_str_new_frozen(path), absolute);
    return absolute;
}

// ---------------------------------------------------------------- type names

static VALUE vd_class_name(VALUE value) {
    VALUE klass = rb_obj_class(value);
    VALUE cached = rb_hash_lookup2(cls_name_memo, klass, Qundef);
    if (cached != Qundef) return cached;

    // Module#name itself, never an override: a module may define `.name` as
    // part of its own DSL, and asking it mid-trace could raise.
    VALUE name = rb_mod_name(klass);
    if (NIL_P(name)) name = str_untyped;
    rb_hash_aset(cls_name_memo, klass, name);
    return name;
}

// A module used as a strategy dispatches through its constant identity, so
// that identity is kept next to the nominal `Module` type rather than instead
// of it.
static VALUE vd_singleton_name(VALUE value) {
    if (!RB_TYPE_P(value, T_CLASS) && !RB_TYPE_P(value, T_MODULE)) return Qnil;
    return rb_mod_name(value);
}

// --------------------------------------------------------------- source role

static VALUE vd_source_roles_env(VALUE unused) {
    VALUE env = rb_const_get(rb_cObject, rb_intern("ENV"));
    VALUE value = rb_funcall(env, id_aref, 1, rb_str_new_cstr("NIL_KILL_SOURCE_ROLES"));
    return NIL_P(value) ? rb_str_new_cstr("") : rb_obj_as_string(value);
}

static VALUE vd_load_nonproduction_paths(VALUE source) {
    VALUE paths = rb_hash_new();
    if (RSTRING_LEN(source) == 0) return paths;
    if (!RTEST(rb_funcall(rb_cFile, id_file_p, 1, source))) return paths;

    VALUE document = rb_funcall(vd_json(), id_parse, 1,
                                rb_funcall(rb_cFile, id_read, 1, source));
    VALUE listed = rb_hash_aref(document, rb_str_new_cstr("nonproduction"));
    if (!RB_TYPE_P(listed, T_ARRAY)) return paths;

    for (long i = 0; i < RARRAY_LEN(listed); i++) {
        VALUE path = RARRAY_AREF(listed, i);
        if (!RB_TYPE_P(path, T_STRING)) continue;
        rb_hash_aset(paths, rb_file_expand_path(path, root_path), Qtrue);
    }
    return paths;
}

static VALUE vd_nonproduction_paths(void) {
    VALUE source = vd_guard(vd_source_roles_env, Qnil, rb_str_new_cstr(""));
    if (!NIL_P(nonproduction_source) && rb_str_equal(nonproduction_source, source)) {
        return nonproduction_paths;
    }
    nonproduction_paths = vd_guard(vd_load_nonproduction_paths, source, rb_hash_new());
    nonproduction_source = rb_str_new_frozen(source);
    return nonproduction_paths;
}

static int vd_nonproduction_path(VALUE path) {
    if (!RB_TYPE_P(path, T_STRING)) return 0;
    return RTEST(rb_hash_lookup2(vd_nonproduction_paths(), vd_abs_path(path), Qfalse));
}

// The file a class was declared in. An anonymous class has no constant to ask
// about, so its first defined instance method stands in for the declaration.
static VALUE vd_source_location_uncached(VALUE klass) {
    VALUE name = rb_mod_name(klass);
    VALUE location = Qnil;
    if (!NIL_P(name) && RSTRING_LEN(name) > 0) {
        location = rb_funcall(rb_cObject, id_const_source_location, 1, name);
    } else {
        VALUE methods = rb_funcall(klass, id_instance_methods, 1, Qfalse);
        for (long i = 0; i < RARRAY_LEN(methods); i++) {
            VALUE method = rb_funcall(klass, id_instance_method, 1, RARRAY_AREF(methods, i));
            VALUE found = rb_funcall(method, id_source_location, 0);
            if (RB_TYPE_P(found, T_ARRAY)) {
                location = found;
                break;
            }
        }
    }
    if (!RB_TYPE_P(location, T_ARRAY) || RARRAY_LEN(location) == 0) return Qnil;

    VALUE path = RARRAY_AREF(location, 0);
    if (!RB_TYPE_P(path, T_STRING)) return Qnil;
    // `<internal:kernel>` and friends are not files.
    if (RSTRING_LEN(path) > 0 && RSTRING_PTR(path)[0] == '<') return Qnil;

    VALUE absolute = vd_abs_path(path);
    return RTEST(rb_funcall(rb_cFile, id_file_p, 1, absolute)) ? absolute : Qnil;
}

static VALUE vd_value_source_location(VALUE value) {
    VALUE klass = (RB_TYPE_P(value, T_CLASS) || RB_TYPE_P(value, T_MODULE))
                      ? value
                      : rb_obj_class(value);
    if (!RB_TYPE_P(klass, T_CLASS) && !RB_TYPE_P(klass, T_MODULE)) return Qnil;

    VALUE cached = rb_hash_lookup2(value_source_memo, klass, Qundef);
    if (cached != Qundef) return cached;

    VALUE path = vd_guard(vd_source_location_uncached, klass, Qnil);
    rb_hash_aset(value_source_memo, klass, path);
    return path;
}

// Three answers, not two: a value whose class has no declaration site at all
// is not a value that was declared in production code, and the evidence
// records that absence rather than guessing.
static VALUE vd_nonproduction_verdict(VALUE value) {
    VALUE path = vd_value_source_location(value);
    if (NIL_P(path)) return Qnil;
    return vd_nonproduction_path(path) ? Qtrue : Qfalse;
}

static int vd_nonproduction_value(VALUE value) {
    return RTEST(vd_nonproduction_verdict(value));
}

// A type name reaches this as text, so the constant it names has to be found
// again -- without triggering an autoload, which would let observation change
// what the program loads.
static VALUE vd_resolve_constant(VALUE name) {
    VALUE scope = rb_cObject;
    const char *text = RSTRING_PTR(name);
    long length = RSTRING_LEN(name);
    long start = 0;
    while (start <= length) {
        long stop = start;
        while (stop < length && !(text[stop] == ':' && stop + 1 < length && text[stop + 1] == ':')) {
            stop++;
        }
        if (stop > start) {
            if (!RB_TYPE_P(scope, T_CLASS) && !RB_TYPE_P(scope, T_MODULE)) return Qnil;

            ID part = rb_intern3(text + start, stop - start, rb_utf8_encoding());
            if (!rb_const_defined_at(scope, part)) return Qnil;
            scope = rb_const_get_at(scope, part);
        }
        start = stop + 2;
    }
    return scope;
}

static int vd_nonproduction_type_name(VALUE name) {
    if (!RB_TYPE_P(name, T_STRING) || RSTRING_LEN(name) == 0) return 0;
    if (rb_str_equal(name, str_untyped)) return 0;
    if (RSTRING_LEN(name) >= 16 && memcmp(RSTRING_PTR(name), "AnonymousStruct(", 16) == 0) {
        return 0;
    }

    VALUE constant = vd_guard(vd_resolve_constant, name, Qnil);
    if (!RB_TYPE_P(constant, T_CLASS) && !RB_TYPE_P(constant, T_MODULE)) return 0;
    return vd_nonproduction_value(constant);
}

// ------------------------------------------------------------------- samples

struct vd_sample {
    VALUE out;
    long limit;
    int pairs;
};

static int vd_sample_entry(VALUE key, VALUE value, VALUE packed) {
    struct vd_sample *sample = (struct vd_sample *)packed;
    if (RARRAY_LEN(sample->out) >= sample->limit) return ST_STOP;
    rb_ary_push(sample->out, sample->pairs ? rb_assoc_new(key, value) : key);
    return RARRAY_LEN(sample->out) >= sample->limit ? ST_STOP : ST_CONTINUE;
}

// A Set is a Hash of its members; reading that Hash is what Set#each does, and
// avoids running application code mid-observation.
static VALUE vd_set_hash(VALUE value) {
    VALUE hash = rb_ivar_get(value, rb_intern("@hash"));
    return RB_TYPE_P(hash, T_HASH) ? hash : Qnil;
}

// The first `element_sample` members of an Array or Set.
static VALUE vd_sample_members(VALUE value) {
    if (RB_TYPE_P(value, T_ARRAY)) {
        long length = RARRAY_LEN(value);
        return rb_ary_subseq(value, 0, length < element_sample ? length : element_sample);
    }
    VALUE hash = vd_set_hash(value);
    VALUE out = rb_ary_new();
    if (NIL_P(hash)) return out;

    struct vd_sample sample = {out, element_sample, 0};
    rb_hash_foreach(hash, vd_sample_entry, (VALUE)&sample);
    return out;
}

// The first `element_sample` [key, value] pairs of a Hash.
static VALUE vd_sample_pairs(VALUE value) {
    VALUE out = rb_ary_new();
    struct vd_sample sample = {out, element_sample, 1};
    rb_hash_foreach(value, vd_sample_entry, (VALUE)&sample);
    return out;
}

static int vd_nested_class(VALUE item) {
    VALUE klass = rb_obj_class(item);
    return klass == rb_cArray || klass == rb_cHash || (!NIL_P(set_class) && klass == set_class);
}

// The one class every sampled member shares, `:empty` for none, or Qundef when
// the members disagree or any of them is itself a collection. This is the key
// the shape memo is built on, so it decides when two collections are treated
// as the same shape.
static VALUE vd_homogeneous_class(VALUE value) {
    VALUE members = vd_sample_members(value);
    long length = RARRAY_LEN(members);
    if (length == 0) return str_empty_sym;

    VALUE first = rb_obj_class(RARRAY_AREF(members, 0));
    if (vd_nested_class(RARRAY_AREF(members, 0))) return Qundef;
    for (long i = 1; i < length; i++) {
        VALUE item = RARRAY_AREF(members, i);
        if (vd_nested_class(item)) return Qundef;
        if (rb_obj_class(item) != first) return Qundef;
    }
    return first;
}

// The same question for a Hash: one key class and one value class across the
// sample. `out_values` stays Qnil when the Hash is empty, matching the Ruby
// this replaces, whose value class was simply never assigned.
static int vd_homogeneous_pair(VALUE value, VALUE *out_keys, VALUE *out_values) {
    VALUE pairs = vd_sample_pairs(value);
    VALUE keys = Qnil;
    VALUE values = Qnil;
    for (long i = 0; i < RARRAY_LEN(pairs); i++) {
        VALUE pair = RARRAY_AREF(pairs, i);
        VALUE key = RARRAY_AREF(pair, 0);
        VALUE val = RARRAY_AREF(pair, 1);
        if (vd_nested_class(key) || vd_nested_class(val)) return 0;

        if (i == 0) {
            keys = rb_obj_class(key);
            values = rb_obj_class(val);
        } else if (rb_obj_class(key) != keys || rb_obj_class(val) != values) {
            return 0;
        }
    }
    *out_keys = NIL_P(keys) ? str_empty_sym : keys;
    *out_values = values;
    return 1;
}

// -------------------------------------------------------------------- shapes

static VALUE vd_shape_payload(VALUE key) {
    VALUE payload = rb_hash_lookup2(shape_lookup, key, Qundef);
    if (payload != Qundef) return payload;

    VALUE fallback = rb_hash_new();
    rb_hash_aset(fallback, key_kind, val_class);
    rb_hash_aset(fallback, key_name, str_untyped);
    return fallback;
}

static VALUE vd_remember_shape(VALUE key, VALUE payload) {
    if (rb_hash_lookup2(shape_lookup, key, Qundef) == Qundef) {
        rb_hash_aset(shape_lookup, key, payload);
    }
    return key;
}

static VALUE vd_class_shape_key(VALUE value) {
    VALUE name = vd_class_name(value);
    VALUE key = rb_sprintf("class:%" PRIsVALUE, name);
    VALUE payload = rb_hash_new();
    rb_hash_aset(payload, key_kind, val_class);
    rb_hash_aset(payload, key_name, name);
    return vd_remember_shape(key, payload);
}

// Shape keys are always Strings, so both the dedup and the ordering are string
// comparisons. Asking Ruby for `==` and `<=>` here would dispatch application
// code from inside the observation hook for no gain.
// Class names, ordered without asking String for `<=>`.
// Membership by string comparison, for the same reason: `Array#include?` asks
// each element whether it is `==` to the candidate.
static int vd_includes_name(VALUE names, VALUE name) {
    for (long i = 0; i < RARRAY_LEN(names); i++) {
        if (rb_str_cmp(RARRAY_AREF(names, i), name) == 0) return 1;
    }
    return 0;
}

static VALUE vd_sorted_names(VALUE array) {
    for (long i = 1; i < RARRAY_LEN(array); i++) {
        VALUE name = RARRAY_AREF(array, i);
        long at = i - 1;
        while (at >= 0 && rb_str_cmp(RARRAY_AREF(array, at), name) > 0) {
            rb_ary_store(array, at + 1, RARRAY_AREF(array, at));
            at--;
        }
        rb_ary_store(array, at + 1, name);
    }
    return array;
}

static VALUE vd_uniq_sorted(VALUE array) {
    VALUE unique = rb_ary_new();
    for (long i = 0; i < RARRAY_LEN(array); i++) {
        VALUE item = RARRAY_AREF(array, i);
        long at = 0;
        int duplicate = 0;
        long length = RARRAY_LEN(unique);
        while (at < length) {
            int order = rb_str_cmp(RARRAY_AREF(unique, at), item);
            if (order == 0) { duplicate = 1; break; }
            if (order > 0) break;
            at++;
        }
        if (duplicate) continue;

        rb_ary_push(unique, item);
        for (long shift = length; shift > at; shift--) {
            rb_ary_store(unique, shift, RARRAY_AREF(unique, shift - 1));
        }
        rb_ary_store(unique, at, item);
    }
    return unique;
}

static VALUE vd_shape_payloads(VALUE keys) {
    VALUE payloads = rb_ary_new_capa(RARRAY_LEN(keys));
    for (long i = 0; i < RARRAY_LEN(keys); i++) {
        rb_ary_push(payloads, vd_shape_payload(RARRAY_AREF(keys, i)));
    }
    return payloads;
}

// Ruby's Array#join would dispatch `to_s` per element; the elements are always
// Strings, so the join is a concatenation.
static VALUE vd_join(VALUE keys, const char *separator) {
    VALUE joined = rb_str_new(0, 0);
    for (long i = 0; i < RARRAY_LEN(keys); i++) {
        if (i > 0) rb_str_cat_cstr(joined, separator);
        rb_str_append(joined, RARRAY_AREF(keys, i));
    }
    return joined;
}

static VALUE vd_record_member_shape(VALUE value, long depth) {
    if (depth <= 0) return vd_shape_payload(vd_class_shape_key(value));

    VALUE record = vd_record_shape_key(value, depth - 1);
    if (!NIL_P(record)) return vd_shape_payload(record);
    if (vd_is_collection(value)) {
        return vd_shape_payload(vd_shape_key_for_collection(value, depth - 1));
    }
    return vd_shape_payload(vd_class_shape_key(value));
}

// An anonymous record has no constant name, but its field list is a stable
// identity: without it every anonymous layout would collapse into one and
// FactMine would intersect unrelated member sets.
static VALUE vd_record_type_name(VALUE value, VALUE fields) {
    VALUE name = vd_class_name(value);
    if (!rb_str_equal(name, str_untyped)) return name;

    VALUE parts = rb_ary_new_capa(RARRAY_LEN(fields));
    for (long i = 0; i < RARRAY_LEN(fields); i++) {
        VALUE field = RARRAY_AREF(fields, i);
        rb_ary_push(parts, RB_TYPE_P(field, T_SYMBOL) ? rb_sym2str(field) : rb_obj_as_string(field));
    }
    return rb_sprintf("AnonymousStruct(%" PRIsVALUE ")", vd_join(parts, ","));
}

struct vd_record_request {
    VALUE value;
    long depth;
};

static VALUE vd_record_shape_key_uncached(VALUE packed) {
    struct vd_record_request *request = (struct vd_record_request *)packed;
    VALUE value = request->value;
    VALUE fields = rb_struct_members(value);
    if (!RB_TYPE_P(fields, T_ARRAY)) return Qnil;

    VALUE members = rb_hash_new();
    VALUE signature = rb_ary_new();
    for (long i = 0; i < RARRAY_LEN(fields); i++) {
        VALUE field = RARRAY_AREF(fields, i);
        VALUE name = RB_TYPE_P(field, T_SYMBOL) ? rb_sym2str(field) : rb_obj_as_string(field);
        if (RSTRING_LEN(name) == 0) continue;

        // Ruby emits no call event for a generated reader, so the member value
        // is observed directly. Struct#[] itself, never an override.
        VALUE shape = vd_record_member_shape(rb_struct_aref(value, field), request->depth);
        rb_hash_aset(members, name, shape);
        rb_ary_push(signature,
                    rb_sprintf("%" PRIsVALUE "=%" PRIsVALUE, name, vd_json_generate(shape)));
    }
    if (RHASH_SIZE(members) == 0) return Qnil;

    VALUE name = vd_record_type_name(value, fields);
    VALUE key = rb_sprintf("record:%" PRIsVALUE ":%" PRIsVALUE, name, vd_join(signature, "\\0"));
    VALUE payload = rb_hash_new();
    rb_hash_aset(payload, sym_kind, val_record);
    rb_hash_aset(payload, sym_name, name);
    rb_hash_aset(payload, sym_members, members);
    return vd_remember_shape(key, payload);
}

static VALUE vd_record_shape_key(VALUE value, long depth) {
    if (!vd_is_struct(value)) return Qnil;

    struct vd_record_request request = {value, depth};
    return vd_guard(vd_record_shape_key_uncached, (VALUE)&request, Qnil);
}

static VALUE vd_shape_key_full(VALUE value, long depth) {
    // A sampled member may itself be a record; that layout belongs under the
    // collection so a block binding still sees it.
    VALUE record = vd_record_shape_key(value, VD_RECORD_DEPTH);
    if (!NIL_P(record)) return record;
    if (depth <= 0) return vd_class_shape_key(value);

    int is_array = RB_TYPE_P(value, T_ARRAY);
    int is_set = !is_array && vd_is_set(value);
    if (is_array || is_set) {
        VALUE members = vd_sample_members(value);
        VALUE keys = rb_ary_new_capa(RARRAY_LEN(members));
        for (long i = 0; i < RARRAY_LEN(members); i++) {
            rb_ary_push(keys, vd_shape_key_for_collection(RARRAY_AREF(members, i), depth - 1));
        }
        keys = vd_uniq_sorted(keys);
        VALUE payload = rb_hash_new();
        rb_hash_aset(payload, key_kind, is_array ? val_array : val_set);
        rb_hash_aset(payload, key_elements, vd_shape_payloads(keys));
        return vd_remember_shape(
            rb_sprintf("%s:[%" PRIsVALUE "]", is_array ? "array" : "set", vd_join(keys, ";")),
            payload);
    }
    if (RB_TYPE_P(value, T_HASH)) {
        VALUE pairs = vd_sample_pairs(value);
        VALUE key_shapes = rb_ary_new();
        VALUE value_shapes = rb_ary_new();
        for (long i = 0; i < RARRAY_LEN(pairs); i++) {
            VALUE pair = RARRAY_AREF(pairs, i);
            rb_ary_push(key_shapes,
                        vd_shape_key_for_collection(RARRAY_AREF(pair, 0), depth - 1));
            rb_ary_push(value_shapes,
                        vd_shape_key_for_collection(RARRAY_AREF(pair, 1), depth - 1));
        }
        key_shapes = vd_uniq_sorted(key_shapes);
        value_shapes = vd_uniq_sorted(value_shapes);
        VALUE payload = rb_hash_new();
        rb_hash_aset(payload, key_kind, val_hash);
        rb_hash_aset(payload, key_keys, vd_shape_payloads(key_shapes));
        rb_hash_aset(payload, key_values, vd_shape_payloads(value_shapes));
        return vd_remember_shape(rb_sprintf("hash:{%" PRIsVALUE "}:{%" PRIsVALUE "}",
                                            vd_join(key_shapes, ";"), vd_join(value_shapes, ";")),
                                 payload);
    }
    return vd_class_shape_key(value);
}

static VALUE vd_ctsk_bucket(VALUE outer, VALUE key) {
    VALUE bucket = rb_hash_lookup2(outer, key, Qundef);
    if (bucket == Qundef) {
        bucket = rb_hash_new();
        rb_hash_aset(outer, key, bucket);
    }
    return bucket;
}

// The memo is the behaviour, not an optimisation: a collection's shape is
// remembered against the classes it was carrying, so a second collection of
// the same element class reuses the first one's shape.
static VALUE vd_shape_key_for_collection(VALUE value, long depth) {
    if (depth > 0) {
        if (RB_TYPE_P(value, T_ARRAY) || vd_is_set(value)) {
            VALUE signature = vd_homogeneous_class(value);
            if (signature != Qundef) {
                VALUE bucket = vd_ctsk_bucket(ctsk_memo, rb_obj_class(value));
                VALUE cached = rb_hash_lookup2(bucket, signature, Qundef);
                if (cached != Qundef) return cached;

                VALUE key = vd_shape_key_full(value, depth);
                rb_hash_aset(bucket, signature, key);
                return key;
            }
        } else if (RB_TYPE_P(value, T_HASH)) {
            VALUE keys = Qnil;
            VALUE values = Qnil;
            if (vd_homogeneous_pair(value, &keys, &values)) {
                VALUE bucket = vd_ctsk_bucket(vd_ctsk_bucket(ctsk_memo, str_h_sym), keys);
                VALUE cached = rb_hash_lookup2(bucket, values, Qundef);
                if (cached != Qundef) return cached;

                VALUE key = vd_shape_key_full(value, depth);
                rb_hash_aset(bucket, values, key);
                return key;
            }
        }
    }
    return vd_shape_key_full(value, depth);
}

// The classes a collection was carrying. Only the class names are needed here;
// the nested shapes are carried separately by the shape key.
static int vd_container_classes(VALUE value, VALUE *out_elements, VALUE *out_keys,
                                VALUE *out_values) {
    if (RB_TYPE_P(value, T_ARRAY) || vd_is_set(value)) {
        VALUE members = vd_sample_members(value);
        VALUE elements = rb_ary_new();
        for (long i = 0; i < RARRAY_LEN(members); i++) {
            VALUE name = vd_class_name(RARRAY_AREF(members, i));
            if (!vd_includes_name(elements, name)) rb_ary_push(elements, name);
        }
        *out_elements = elements;
        return 1;
    }
    if (RB_TYPE_P(value, T_HASH)) {
        VALUE pairs = vd_sample_pairs(value);
        VALUE keys = rb_ary_new();
        VALUE values = rb_ary_new();
        for (long i = 0; i < RARRAY_LEN(pairs); i++) {
            VALUE pair = RARRAY_AREF(pairs, i);
            VALUE key_name = vd_class_name(RARRAY_AREF(pair, 0));
            VALUE value_name = vd_class_name(RARRAY_AREF(pair, 1));
            if (!vd_includes_name(keys, key_name)) rb_ary_push(keys, key_name);
            if (!vd_includes_name(values, value_name)) rb_ary_push(values, value_name);
        }
        *out_keys = keys;
        *out_values = values;
        return 2;
    }
    return 0;
}

// A shape naming a test-only class must not be exported, and neither must a
// member of one. The rest of the shape survives.
static int vd_production_member(VALUE name, VALUE shape, VALUE packed) {
    VALUE kept = vd_production_shape(shape);
    if (!NIL_P(kept)) rb_hash_aset(packed, name, kept);
    return ST_CONTINUE;
}

static int vd_production_field(VALUE key, VALUE value, VALUE packed) {
    VALUE label = RB_TYPE_P(key, T_SYMBOL) ? rb_sym2str(key) : key;
    if (!RB_TYPE_P(label, T_STRING)) {
        rb_hash_aset(packed, key, value);
        return ST_CONTINUE;
    }
    if (rb_str_equal(label, key_elements) || rb_str_equal(label, key_keys) ||
        rb_str_equal(label, key_values)) {
        VALUE kept = rb_ary_new();
        if (RB_TYPE_P(value, T_ARRAY)) {
            for (long i = 0; i < RARRAY_LEN(value); i++) {
                VALUE member = vd_production_shape(RARRAY_AREF(value, i));
                if (!NIL_P(member)) rb_ary_push(kept, member);
            }
        }
        rb_hash_aset(packed, key, kept);
    } else if (rb_str_equal(label, key_members)) {
        VALUE kept = rb_hash_new();
        if (RB_TYPE_P(value, T_HASH)) rb_hash_foreach(value, vd_production_member, kept);
        rb_hash_aset(packed, key, kept);
    } else {
        rb_hash_aset(packed, key, value);
    }
    return ST_CONTINUE;
}

static VALUE vd_production_shape(VALUE shape) {
    if (!RB_TYPE_P(shape, T_HASH)) return shape;

    VALUE kind = rb_hash_lookup2(shape, sym_kind, Qnil);
    if (NIL_P(kind)) kind = rb_hash_lookup2(shape, key_kind, Qnil);
    VALUE name = rb_hash_lookup2(shape, sym_name, Qnil);
    if (NIL_P(name)) name = rb_hash_lookup2(shape, key_name, Qnil);
    if (RB_TYPE_P(kind, T_STRING) &&
        (rb_str_equal(kind, val_class) || rb_str_equal(kind, val_record)) &&
        vd_nonproduction_type_name(name)) {
        return Qnil;
    }

    VALUE filtered = rb_hash_new();
    rb_hash_foreach(shape, vd_production_field, filtered);
    return filtered;
}

// -------------------------------------------------------------------- domain

static void vd_concat_production(VALUE target, VALUE names) {
    for (long i = 0; i < RARRAY_LEN(names); i++) {
        VALUE name = RARRAY_AREF(names, i);
        if (!vd_nonproduction_type_name(name)) rb_ary_push(target, name);
    }
}

static void vd_sort_shapes(VALUE shapes) {
    long length = RARRAY_LEN(shapes);
    if (length < 2) return;

    VALUE keys = rb_ary_new_capa(length);
    for (long i = 0; i < length; i++) {
        rb_ary_push(keys, vd_json_generate(RARRAY_AREF(shapes, i)));
    }
    for (long i = 1; i < length; i++) {
        VALUE shape = RARRAY_AREF(shapes, i);
        VALUE key = RARRAY_AREF(keys, i);
        long j = i - 1;
        while (j >= 0 && rb_str_cmp(RARRAY_AREF(keys, j), key) > 0) {
            rb_ary_store(shapes, j + 1, RARRAY_AREF(shapes, j));
            rb_ary_store(keys, j + 1, RARRAY_AREF(keys, j));
            j--;
        }
        rb_ary_store(shapes, j + 1, shape);
        rb_ary_store(keys, j + 1, key);
    }
}

static VALUE vd_observed_domain(VALUE value) {
    VALUE types = rb_ary_new();
    VALUE singletons = rb_ary_new();
    VALUE elements = rb_ary_new();
    VALUE keys = rb_ary_new();
    VALUE values = rb_ary_new();
    VALUE shapes = rb_ary_new();

    rb_ary_push(types, vd_class_name(value));
    VALUE singleton = vd_singleton_name(value);
    if (!NIL_P(singleton)) rb_ary_push(singletons, singleton);

    VALUE record = vd_record_shape_key(value, VD_RECORD_DEPTH);
    if (!NIL_P(record)) {
        VALUE payload = vd_shape_payload(record);
        rb_ary_push(shapes, payload);
        VALUE name = rb_hash_lookup2(payload, sym_name, Qnil);
        if (NIL_P(name)) name = rb_hash_lookup2(payload, key_name, Qnil);
        // A record whose class is anonymous is better described by its layout
        // than by the absence of a name.
        if (!NIL_P(name) && RARRAY_LEN(types) == 1 &&
            rb_str_equal(RARRAY_AREF(types, 0), str_untyped)) {
            types = rb_ary_new_from_args(1, name);
        }
    }

    VALUE container_elements = Qnil;
    VALUE container_keys = Qnil;
    VALUE container_values = Qnil;
    int container =
        vd_container_classes(value, &container_elements, &container_keys, &container_values);
    if (container == 1) {
        vd_concat_production(elements, container_elements);
    } else if (container == 2) {
        vd_concat_production(keys, container_keys);
        vd_concat_production(values, container_values);
    }
    if (container) {
        VALUE shape = vd_production_shape(
            vd_shape_payload(vd_shape_key_for_collection(value, VD_COLLECTION_DEPTH)));
        if (!NIL_P(shape)) rb_ary_push(shapes, shape);
    }

    VALUE domain = rb_hash_new();
    rb_hash_aset(domain, ID2SYM(id_types), vd_sorted_names(types));
    rb_hash_aset(domain, ID2SYM(id_singletons), vd_sorted_names(singletons));
    rb_hash_aset(domain, ID2SYM(id_elements), vd_sorted_names(elements));
    rb_hash_aset(domain, ID2SYM(id_keys), vd_sorted_names(keys));
    rb_hash_aset(domain, ID2SYM(id_values), vd_sorted_names(values));
    vd_sort_shapes(shapes);
    rb_hash_aset(domain, ID2SYM(id_shapes), shapes);
    return domain;
}

VALUE nk_value_domain(VALUE value) {
    VALUE domain = vd_observed_domain(value);
    rb_hash_aset(domain, ID2SYM(id_nonproduction), vd_nonproduction_verdict(value));
    return domain;
}

// The observation with no source-role policy applied, and the policy on its
// own: two consumers apply them differently, so they are asked separately.
static VALUE nk_observed_domain(VALUE self, VALUE value) {
    return vd_observed_domain(value);
}

static VALUE nk_native_domain(VALUE self, VALUE value) {
    return nk_value_domain(value);
}

static VALUE nk_nonproduction_value(VALUE self, VALUE value) {
    return vd_nonproduction_verdict(value);
}

// The memos describe classes and files, both of which a workload can redefine
// between one traced program and the next. A test that changes either has to
// be able to say so.
static VALUE nk_reset_value_domain(VALUE self) {
    rb_funcall(cls_name_memo, rb_intern("clear"), 0);
    rb_funcall(value_source_memo, rb_intern("clear"), 0);
    rb_funcall(shape_lookup, rb_intern("clear"), 0);
    rb_funcall(ctsk_memo, rb_intern("clear"), 0);
    rb_funcall(abs_path_memo, rb_intern("clear"), 0);
    nonproduction_source = Qnil;
    return Qnil;
}

// Every path the collector reports is relative to this root, and every
// source-role decision is a lookup keyed by one. The traced program is started
// with it in its environment.
static VALUE nk_set_root(VALUE self, VALUE path) {
    root_path = vd_immortal(rb_file_expand_path(rb_obj_as_string(path), Qnil));
    rb_funcall(abs_path_memo, rb_intern("clear"), 0);
    rb_funcall(value_source_memo, rb_intern("clear"), 0);
    nonproduction_source = Qnil;
    return root_path;
}

void nk_value_domain_init(VALUE mod) {
    vd_registered_hash(&cls_name_memo);
    vd_registered_hash(&value_source_memo);
    vd_registered_hash(&shape_lookup);
    vd_registered_hash(&ctsk_memo);
    vd_registered_hash(&abs_path_memo);
    vd_registered_hash(&nonproduction_paths);
    nonproduction_source = Qnil;
    rb_gc_register_address(&nonproduction_source);
    json_module = Qnil;

    const char *root = getenv("NIL_KILL_ROOT");
    root_path = vd_immortal(rb_file_expand_path(
        rb_str_new_cstr(root ? root : "."), Qnil));

    const char *sample = getenv("NIL_KILL_ELEMENT_SAMPLE");
    element_sample = sample ? atol(sample) : 20;
    if (element_sample <= 0) element_sample = 20;

    set_class = rb_const_defined(rb_cObject, rb_intern("Set"))
                    ? vd_immortal(rb_const_get(rb_cObject, rb_intern("Set")))
                    : Qnil;

    str_untyped = vd_frozen_str("T.untyped");
    str_empty_sym = ID2SYM(rb_intern("empty"));
    str_h_sym = ID2SYM(rb_intern("h"));
    key_kind = vd_frozen_str("kind");
    key_name = vd_frozen_str("name");
    key_elements = vd_frozen_str("elements");
    key_keys = vd_frozen_str("keys");
    key_values = vd_frozen_str("values");
    key_members = vd_frozen_str("members");
    sym_kind = ID2SYM(rb_intern("kind"));
    sym_name = ID2SYM(rb_intern("name"));
    sym_members = ID2SYM(rb_intern("members"));
    val_class = vd_frozen_str("class");
    val_record = vd_frozen_str("record");
    val_array = vd_frozen_str("array");
    val_hash = vd_frozen_str("hash");
    val_set = vd_frozen_str("set");

    id_types = rb_intern("types");
    id_singletons = rb_intern("singletons");
    id_elements = rb_intern("elements");
    id_keys = rb_intern("keys");
    id_values = rb_intern("values");
    id_shapes = rb_intern("shapes");
    id_nonproduction = rb_intern("nonproduction");
    id_generate = rb_intern("generate");
    id_parse = rb_intern("parse");
    id_const_source_location = rb_intern("const_source_location");
    id_file_p = rb_intern("file?");
    id_read = rb_intern("read");
    id_instance_methods = rb_intern("instance_methods");
    id_instance_method = rb_intern("instance_method");
    id_source_location = rb_intern("source_location");
    id_aref = rb_intern("[]");

    rb_define_singleton_method(mod, "value_domain", nk_native_domain, 1);
    rb_define_singleton_method(mod, "observed_value_domain", nk_observed_domain, 1);
    rb_define_singleton_method(mod, "nonproduction_value?", nk_nonproduction_value, 1);
    rb_define_singleton_method(mod, "reset_value_domain", nk_reset_value_domain, 0);
    rb_define_singleton_method(mod, "value_domain_root=", nk_set_root, 1);
}
