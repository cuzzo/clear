// What a record's fields were holding.
//
// A Struct, a Data, a T::Struct and an OpenStruct all reduce to the same
// observation: at a declaration site, a named field held a value of some class,
// and if that value was a collection, of some shape. The declaration hooks
// differ in how they notice; what they notice is this.
//
// Two of the plan's answers matter here. A field the plan says is already
// resolved is not sampled at all -- that is `struct_fields`, matched on the
// longest suffix of the class name, because a runtime class is qualified and a
// declaration may not be. And a fixed-length array of mixed types is recorded
// separately as a tuple, because that is a different claim from "an array of
// these element types".

#include <ruby.h>
#include <ruby/encoding.h>
#include "records.h"
#include "collections.h"
#include "value_domain.h"

static VALUE sampled_fields;  // "Klass\0field" -> false when the plan resolved it
static VALUE structs;         // [class, field, path, line] -> record
static VALUE tuples;          // [kind, path, line, slot, size, types] -> record
static ID id_struct_path, id_struct_line, id_calls, id_complete, id_mixed;
static VALUE sym_array;
static long element_sample = 20;

static void registered(VALUE *slot) {
    *slot = rb_hash_new();
    rb_gc_register_address(slot);
}

// A declaration may name its class unqualified where the runtime names it
// fully, so the longest suffix that the plan knows about wins. Silence about a
// field is not proof it is resolved: a record can be built dynamically, and
// only an explicit false may elide observation.
static int plan_samples(VALUE class_name, VALUE field) {
    if (RHASH_SIZE(sampled_fields) == 0) return 1;

    VALUE parts = rb_str_split(class_name, "::");
    for (long take = RARRAY_LEN(parts); take >= 1; take--) {
        VALUE suffix = rb_ary_join(rb_ary_subseq(parts, RARRAY_LEN(parts) - take, take),
                                   rb_str_new_cstr("::"));
        VALUE key = rb_str_dup(suffix);
        rb_str_cat(key, "\0", 1);
        rb_str_append(key, field);
        VALUE answer = rb_hash_lookup2(sampled_fields, key, Qundef);
        if (answer != Qundef) return RTEST(answer);
    }
    return 1;
}

static VALUE record_for(VALUE table, VALUE key, VALUE prototype) {
    VALUE record = rb_hash_lookup2(table, key, Qundef);
    if (record != Qundef) return record;

    rb_hash_aset(table, key, prototype);
    return prototype;
}

static VALUE struct_prototype(void) {
    VALUE record = rb_hash_new();
    rb_hash_aset(record, ID2SYM(id_calls), INT2NUM(0));
    const char *fields[] = {"classes", "elem_classes", "key_classes", "value_classes"};
    for (size_t i = 0; i < sizeof(fields) / sizeof(fields[0]); i++) {
        rb_hash_aset(record, ID2SYM(rb_intern(fields[i])), rb_hash_new());
    }
    rb_hash_aset(record, ID2SYM(rb_intern("array_calls")), INT2NUM(0));
    rb_hash_aset(record, ID2SYM(rb_intern("hash_calls")), INT2NUM(0));
    return record;
}

static void bump(VALUE record, ID field) {
    rb_hash_aset(record, ID2SYM(field),
                 LONG2NUM(NUM2LONG(rb_hash_aref(record, ID2SYM(field))) + 1));
}

static void add_all(VALUE record, const char *field, VALUE values) {
    VALUE set = rb_hash_aref(record, ID2SYM(rb_intern(field)));
    for (long i = 0; i < RARRAY_LEN(values); i++) {
        rb_hash_aset(set, RARRAY_AREF(values, i), Qtrue);
    }
}

// A fixed-length array whose elements are not all one class is a tuple, and a
// declared type has to spell out each position rather than a single element
// type. Only complete or mixed arrays qualify; a long uniform one is just an
// array.
static void record_tuple(VALUE kind, VALUE path, VALUE line, VALUE slot, VALUE value) {
    if (!RB_TYPE_P(value, T_ARRAY) || RARRAY_LEN(value) < 2) return;

    long length = RARRAY_LEN(value);
    long sampled = length < element_sample ? length : element_sample;
    VALUE types = rb_ary_new_capa(sampled);
    int mixed = 0;
    for (long i = 0; i < sampled; i++) {
        VALUE name = nk_type_name(RARRAY_AREF(value, i));
        if (i > 0 && !mixed && rb_str_cmp(name, RARRAY_AREF(types, 0)) != 0) mixed = 1;
        rb_ary_push(types, name);
    }
    int complete = sampled == length;
    if (!complete && !mixed) return;

    VALUE size = complete ? rb_obj_as_string(LONG2NUM(length))
                          : rb_sprintf(">=%ld", element_sample);
    VALUE key = rb_ary_new_from_args(6, kind, path, line, rb_obj_as_string(slot), size, types);
    VALUE prototype = rb_hash_new();
    rb_hash_aset(prototype, ID2SYM(id_calls), INT2NUM(0));
    rb_hash_aset(prototype, ID2SYM(id_complete), complete ? Qtrue : Qfalse);
    rb_hash_aset(prototype, ID2SYM(id_mixed), mixed ? Qtrue : Qfalse);
    VALUE record = record_for(tuples, key, prototype);
    bump(record, id_calls);
    if (!complete) rb_hash_aset(record, ID2SYM(id_complete), Qfalse);
    if (mixed) rb_hash_aset(record, ID2SYM(id_mixed), Qtrue);
}

static VALUE collection_owner(VALUE class_name, VALUE field, VALUE path, VALUE line) {
    VALUE owner = rb_hash_new();
    rb_hash_aset(owner, ID2SYM(rb_intern("owner_kind")), rb_str_new_cstr("struct_field"));
    rb_hash_aset(owner, ID2SYM(rb_intern("name")),
                 rb_sprintf("%" PRIsVALUE ".%" PRIsVALUE, class_name, field));
    rb_hash_aset(owner, ID2SYM(rb_intern("path")), path);
    rb_hash_aset(owner, ID2SYM(rb_intern("line")), line);
    return owner;
}

void nk_record_struct_field(VALUE klass, VALUE class_name, VALUE field, VALUE value) {
    VALUE path = rb_attr_get(klass, id_struct_path);
    VALUE line = rb_attr_get(klass, id_struct_line);
    if (!RB_TYPE_P(path, T_STRING) || !RB_INTEGER_TYPE_P(line)) return;

    class_name = rb_obj_as_string(class_name);
    field = rb_obj_as_string(field);
    if (!plan_samples(class_name, field)) return;

    path = nk_abs_path(path);
    VALUE record = record_for(structs,
                              rb_ary_new_from_args(4, class_name, field, path, line),
                              struct_prototype());
    bump(record, id_calls);
    rb_hash_aset(rb_hash_aref(record, ID2SYM(rb_intern("classes"))), nk_type_name(value), Qtrue);

    VALUE shape = nk_container_shape(value);
    if (NIL_P(shape)) return;

    VALUE owner = collection_owner(class_name, field, path, line);
    if (RARRAY_AREF(shape, 0) == sym_array) {
        bump(record, rb_intern("array_calls"));
        add_all(record, "elem_classes", RARRAY_AREF(shape, 1));
        record_tuple(rb_str_new_cstr("struct_field"), path, line,
                     rb_sprintf("%" PRIsVALUE ".%" PRIsVALUE, class_name, field), value);
        nk_register_collection_owner(value, owner, Qnil);
    } else {
        bump(record, rb_intern("hash_calls"));
        add_all(record, "key_classes", RARRAY_AREF(RARRAY_AREF(shape, 1), 0));
        add_all(record, "value_classes", RARRAY_AREF(RARRAY_AREF(shape, 1), 1));
        nk_register_collection_owner(value, owner, Qnil);
    }
}

static VALUE nk_record_field(VALUE self, VALUE klass, VALUE class_name, VALUE field,
                             VALUE value) {
    nk_record_struct_field(klass, class_name, field, value);
    return Qnil;
}

// The plan names its entries "<class>\0<field>".
static VALUE nk_configure_fields(VALUE self, VALUE fields) {
    rb_funcall(sampled_fields, rb_intern("clear"), 0);
    if (!RB_TYPE_P(fields, T_HASH)) return Qnil;

    VALUE keys = rb_funcall(fields, rb_intern("keys"), 0);
    for (long i = 0; i < RARRAY_LEN(keys); i++) {
        VALUE key = RARRAY_AREF(keys, i);
        if (!RB_TYPE_P(key, T_STRING)) continue;
        rb_hash_aset(sampled_fields, rb_str_new_frozen(key), rb_hash_aref(fields, key));
    }
    return Qnil;
}

static VALUE sorted_keys(VALUE set) {
    return rb_ary_sort(rb_funcall(set, rb_intern("keys"), 0));
}

static int export_struct(VALUE key, VALUE record, VALUE rows) {
    VALUE row = rb_hash_new();
    rb_hash_aset(row, ID2SYM(rb_intern("class")), RARRAY_AREF(key, 0));
    rb_hash_aset(row, ID2SYM(rb_intern("field")), RARRAY_AREF(key, 1));
    rb_hash_aset(row, ID2SYM(rb_intern("path")), RARRAY_AREF(key, 2));
    rb_hash_aset(row, ID2SYM(rb_intern("line")), RARRAY_AREF(key, 3));
    rb_hash_aset(row, ID2SYM(id_calls), rb_hash_aref(record, ID2SYM(id_calls)));
    const char *sets[] = {"classes", "elem_classes", "key_classes", "value_classes"};
    for (size_t i = 0; i < sizeof(sets) / sizeof(sets[0]); i++) {
        rb_hash_aset(row, ID2SYM(rb_intern(sets[i])),
                     sorted_keys(rb_hash_aref(record, ID2SYM(rb_intern(sets[i])))));
    }
    rb_hash_aset(row, ID2SYM(rb_intern("array_calls")),
                 rb_hash_aref(record, ID2SYM(rb_intern("array_calls"))));
    rb_hash_aset(row, ID2SYM(rb_intern("hash_calls")),
                 rb_hash_aref(record, ID2SYM(rb_intern("hash_calls"))));
    rb_ary_push(rows, row);
    return ST_CONTINUE;
}

static int export_tuple(VALUE key, VALUE record, VALUE rows) {
    VALUE row = rb_hash_new();
    rb_hash_aset(row, ID2SYM(rb_intern("kind")), RARRAY_AREF(key, 0));
    rb_hash_aset(row, ID2SYM(rb_intern("path")), RARRAY_AREF(key, 1));
    rb_hash_aset(row, ID2SYM(rb_intern("line")), RARRAY_AREF(key, 2));
    rb_hash_aset(row, ID2SYM(rb_intern("slot")), RARRAY_AREF(key, 3));
    rb_hash_aset(row, ID2SYM(rb_intern("size")), RARRAY_AREF(key, 4));
    rb_hash_aset(row, ID2SYM(rb_intern("types")), RARRAY_AREF(key, 5));
    rb_hash_aset(row, ID2SYM(id_calls), rb_hash_aref(record, ID2SYM(id_calls)));
    rb_hash_aset(row, ID2SYM(id_complete), rb_hash_aref(record, ID2SYM(id_complete)));
    rb_hash_aset(row, ID2SYM(id_mixed), rb_hash_aref(record, ID2SYM(id_mixed)));
    rb_ary_push(rows, row);
    return ST_CONTINUE;
}

static VALUE nk_struct_observations(VALUE self) {
    VALUE rows = rb_ary_new();
    rb_hash_foreach(structs, export_struct, rows);
    return rows;
}

static VALUE nk_tuple_observations(VALUE self) {
    VALUE rows = rb_ary_new();
    rb_hash_foreach(tuples, export_tuple, rows);
    return rows;
}

void nk_records_init(VALUE mod) {
    registered(&sampled_fields);
    registered(&structs);
    registered(&tuples);

    id_struct_path = rb_intern("@__nil_kill_struct_path");
    id_struct_line = rb_intern("@__nil_kill_struct_line");
    id_calls = rb_intern("calls");
    id_complete = rb_intern("complete");
    id_mixed = rb_intern("mixed");
    sym_array = ID2SYM(rb_intern("array"));

    const char *sample = getenv("NIL_KILL_ELEMENT_SAMPLE");
    if (sample) {
        long parsed = atol(sample);
        if (parsed > 0) element_sample = parsed;
    }

    rb_define_singleton_method(mod, "record_struct_field", nk_record_field, 4);
    rb_define_singleton_method(mod, "configure_struct_fields", nk_configure_fields, 1);
    rb_define_singleton_method(mod, "struct_observations", nk_struct_observations, 0);
    rb_define_singleton_method(mod, "tuple_observations", nk_tuple_observations, 0);
}
