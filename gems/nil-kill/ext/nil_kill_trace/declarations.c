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
#include "collections.h"
#include "identity.h"
#include "records.h"
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
void nk_use_tlet_sites(VALUE sites) {
    st_clear(tlet_sites);
    if (!RB_TYPE_P(sites, T_HASH)) return;

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
    return;
}

static VALUE nk_configure_tlet_sites(VALUE self, VALUE sites) {
    nk_use_tlet_sites(sites);
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

// ----------------------------------------------------------------- records
//
// A generated record's accessors are defined by Ruby itself. Registering what
// they stand for is not enough on its own: the VM dispatches a generated reader
// without an event, so a wrapper has to stand in front of it before the call is
// observable at all. The wrapper adds nothing but its own existence.

static ID id_members, id_props, id_attached, id_fields, id_family;
static ID id_struct_path, id_struct_line, id_initialize, id_source_location;
static ID id_instance_method, id_respond_to, id_keys;
static ID id_accessor_module, id_constructor_module;
static VALUE record_wrappers;

static void register_on(VALUE module, VALUE klass, VALUE fields, VALUE name, int writes);
static VALUE field_names(VALUE klass, ID reader);
static void reregister(VALUE klass);
static int claim_record(VALUE klass);

static VALUE class_display_name(VALUE klass, const char *fallback) {
    VALUE name = rb_mod_name(klass);
    return NIL_P(name) ? rb_str_new_cstr(fallback) : name;
}

static void observe_instance(VALUE instance, const char *fallback) {
    VALUE klass = rb_obj_class(instance);
    VALUE fields = rb_attr_get(klass, id_fields);
    if (!RB_TYPE_P(fields, T_ARRAY)) return;

    VALUE name = class_display_name(klass, fallback);
    for (long i = 0; i < RARRAY_LEN(fields); i++) {
        VALUE field = RARRAY_AREF(fields, i);
        nk_record_struct_field(klass, name, field,
                               rb_funcall(instance, rb_intern_str(field), 0));
    }
}

static VALUE observe_struct_new(int argc, VALUE *argv, VALUE self) {
    VALUE instance = rb_call_super_kw(argc, argv, RB_PASS_CALLED_KEYWORDS);
    observe_instance(instance, "AnonymousStruct");
    return instance;
}

static VALUE observe_data_new(int argc, VALUE *argv, VALUE self) {
    VALUE instance = rb_call_super_kw(argc, argv, RB_PASS_CALLED_KEYWORDS);
    observe_instance(instance, "AnonymousData");
    return instance;
}

// A T::Struct declares its props inside the class body, which has not run when
// `inherited` fires, so the field list is read at construction instead of being
// stamped when the subclass appears.
static VALUE observe_tstruct_new(int argc, VALUE *argv, VALUE self) {
    VALUE instance = rb_call_super_kw(argc, argv, RB_PASS_CALLED_KEYWORDS);
    VALUE klass = rb_obj_class(instance);
    // Asked once per class: the props of a T::Struct cannot change after its
    // body has run, and asking again on every construction is pure cost.
    VALUE fields = rb_attr_get(klass, id_fields);
    if (!RB_TYPE_P(fields, T_ARRAY)) {
        fields = field_names(klass, id_props);
        if (NIL_P(fields)) return instance;

        rb_ivar_set(klass, id_fields, fields);
        reregister(klass);
    }
    VALUE name = class_display_name(klass, "AnonymousTStruct");
    for (long i = 0; i < RARRAY_LEN(fields); i++) {
        VALUE field = RARRAY_AREF(fields, i);
        nk_record_struct_field(klass, name, field,
                               rb_funcall(instance, rb_intern_str(field), 0));
    }
    return instance;
}

static VALUE observe_field_get(int argc, VALUE *argv, VALUE self) {
    return rb_call_super_kw(argc, argv, RB_PASS_CALLED_KEYWORDS);
}

static VALUE observe_index_set(int argc, VALUE *argv, VALUE self) {
    if (argc >= 2) {
        VALUE klass = rb_obj_class(self);
        nk_record_struct_field(klass, class_display_name(klass, "AnonymousStruct"),
                               rb_obj_as_string(argv[0]), argv[1]);
    }
    return rb_call_super_kw(argc, argv, RB_PASS_CALLED_KEYWORDS);
}

static VALUE observe_field_set(int argc, VALUE *argv, VALUE self) {
    if (argc >= 1) {
        VALUE klass = rb_obj_class(self);
        VALUE selector = rb_id2str(rb_frame_this_func());
        nk_record_struct_field(klass, class_display_name(klass, "AnonymousStruct"),
                               rb_str_new(RSTRING_PTR(selector), RSTRING_LEN(selector) - 1),
                               argv[0]);
    }
    return rb_call_super_kw(argc, argv, RB_PASS_CALLED_KEYWORDS);
}

static VALUE declared_site(VALUE klass) {
    return rb_funcall(rb_funcall(klass, id_instance_method, 1, ID2SYM(id_initialize)),
                      id_source_location, 0);
}

static void stamp_site(VALUE klass, VALUE path, VALUE line) {
    if (RB_TYPE_P(rb_attr_get(klass, id_struct_path), T_STRING)) return;

    if (!RB_TYPE_P(path, T_STRING)) {
        VALUE location = nk_guard(declared_site, klass, Qnil);
        if (!RB_TYPE_P(location, T_ARRAY) || RARRAY_LEN(location) < 2) return;
        path = RARRAY_AREF(location, 0);
        line = RARRAY_AREF(location, 1);
        if (!RB_TYPE_P(path, T_STRING)) return;
        path = nk_abs_path(path);
    }
    rb_ivar_set(klass, id_struct_path, path);
    rb_ivar_set(klass, id_struct_line, line);
}

static VALUE field_names(VALUE klass, ID reader) {
    if (!RTEST(rb_funcall(klass, id_respond_to, 1, ID2SYM(reader)))) return Qnil;

    VALUE fields = rb_funcall(klass, reader, 0);
    if (RB_TYPE_P(fields, T_HASH)) fields = rb_funcall(fields, id_keys, 0);
    if (!RB_TYPE_P(fields, T_ARRAY) || RARRAY_LEN(fields) == 0) return Qnil;

    VALUE names = rb_ary_new_capa(RARRAY_LEN(fields));
    for (long i = 0; i < RARRAY_LEN(fields); i++) {
        rb_ary_push(names, rb_obj_as_string(RARRAY_AREF(fields, i)));
    }
    return rb_obj_freeze(names);
}

// A record declared outside the analyzed corpus cannot be joined to a parsed
// declaration, so its family and field list stand in for the name it does not
// have here. One declared inside keeps its nominal identity, and so does one
// declared in test code, so FactMine can exclude exactly that.
static int obviously_nonproduction(VALUE path) {
    VALUE parts = rb_str_split(path, "/");
    const char *dirs[] = {"test", "tests", "spec", "specs"};
    for (long i = 0; i < RARRAY_LEN(parts); i++) {
        for (size_t d = 0; d < sizeof(dirs) / sizeof(dirs[0]); d++) {
            if (rb_str_cmp(RARRAY_AREF(parts, i), rb_str_new_cstr(dirs[d])) == 0) return 1;
        }
    }
    VALUE base = RARRAY_LEN(parts) ? RARRAY_AREF(parts, RARRAY_LEN(parts) - 1) : path;
    const char *suffixes[] = {"_test.rb", "_spec.rb"};
    for (size_t i = 0; i < sizeof(suffixes) / sizeof(suffixes[0]); i++) {
        long want = (long)strlen(suffixes[i]);
        if (RSTRING_LEN(base) >= want &&
            memcmp(RSTRING_PTR(base) + RSTRING_LEN(base) - want, suffixes[i], (size_t)want) == 0) {
            return 1;
        }
    }
    return 0;
}

static VALUE reported_owner(VALUE klass, VALUE fields) {
    VALUE nominal = rb_mod_name(klass);
    VALUE family = rb_attr_get(klass, id_family);
    if (!RB_TYPE_P(family, T_STRING)) family = rb_str_new_cstr("Struct");
    if (NIL_P(nominal)) {
        return rb_sprintf("Anonymous%" PRIsVALUE "(%" PRIsVALUE ")", family,
                          rb_ary_join(fields, rb_str_new_cstr(",")));
    }
    VALUE path = rb_attr_get(klass, id_struct_path);
    if (!RB_TYPE_P(path, T_STRING) || nk_analyzed_path(path) || nk_nonproduction_path(path) ||
        obviously_nonproduction(path)) {
        return nominal;
    }
    return rb_sprintf("Generated%" PRIsVALUE "(%" PRIsVALUE ";%" PRIsVALUE ")", family,
                      rb_ary_join(rb_str_split(nominal, "::"), rb_str_new_cstr("/")),
                      rb_ary_join(fields, rb_str_new_cstr(",")));
}

// A record is usually created anonymously and assigned to a constant a moment
// later, so the name it should be reported under is not known when its wrappers
// are installed. Registering again once the constant exists fixes the name.
static void reregister(VALUE klass) {
    VALUE fields = rb_attr_get(klass, id_fields);
    if (!RB_TYPE_P(fields, T_ARRAY)) return;

    VALUE name = reported_owner(klass, fields);
    VALUE accessors = rb_attr_get(klass, id_accessor_module);
    VALUE constructor = rb_attr_get(klass, id_constructor_module);
    VALUE path = rb_attr_get(klass, id_struct_path);
    ID at = RB_TYPE_P(path, T_STRING) ? rb_intern_str(path) : 0;
    if (!NIL_P(accessors)) register_on(accessors, klass, fields, name, 1);
    if (!NIL_P(constructor)) {
        nk_register_wrapper(constructor, rb_intern("new"), rb_intern_str(name),
                            rb_intern("class"), 1, at, 0);
    }
}

// Registering the wrappers themselves, which is where the VM says the call was
// defined. The declaration site travels with the identity: a generated accessor
// has no Ruby definition of its own, and without its record's file it exports
// as opaque CRuby and is priced by the wrong cost model.
static void register_on(VALUE module, VALUE klass, VALUE fields, VALUE name, int writes) {
    ID owner = rb_intern_str(name);
    ID kind = rb_intern("instance");
    VALUE path = rb_attr_get(klass, id_struct_path);
    ID at = RB_TYPE_P(path, T_STRING) ? rb_intern_str(path) : 0;
    for (long i = 0; i < RARRAY_LEN(fields); i++) {
        VALUE field = RARRAY_AREF(fields, i);
        nk_register_wrapper(module, rb_intern_str(field), owner, kind, 1, at, 0);
        if (!writes) continue;

        nk_register_wrapper(module, rb_intern_str(rb_str_plus(field, rb_str_new_cstr("="))),
                            owner, kind, 1, at, 0);
    }
    if (writes) nk_register_wrapper(module, rb_intern("[]="), owner, kind, 1, at, 0);
}

static int claim_record(VALUE klass) {
    if (RTEST(rb_attr_get(klass, id_attached))) return 0;
    rb_ivar_set(klass, id_attached, Qtrue);
    return 1;
}

// Observing construction rather than #initialize: a generated record is often
// assigned to a constant and reopened with a Sorbet-signed initializer, and
// Sorbet cannot replace a method hidden behind a prepended module.
static void attach_record(VALUE klass, ID field_reader, const char *family,
                          VALUE (*constructor)(int, VALUE *, VALUE), int observe_writes) {
    if (!RB_TYPE_P(klass, T_CLASS)) return;

    VALUE fields = field_names(klass, field_reader);
    if (NIL_P(fields)) return;
    if (!claim_record(klass)) {
        reregister(klass);
        return;
    }

    rb_ivar_set(klass, id_fields, fields);
    rb_ivar_set(klass, id_family, rb_str_new_cstr(family));

    VALUE singleton_wrapper = rb_module_new();
    rb_ary_push(record_wrappers, singleton_wrapper);
    rb_ivar_set(klass, id_constructor_module, singleton_wrapper);
    rb_define_method(singleton_wrapper, "new", constructor, -1);
    rb_prepend_module(rb_singleton_class(klass), singleton_wrapper);

    VALUE accessors = rb_module_new();
    rb_ary_push(record_wrappers, accessors);
    rb_ivar_set(klass, id_accessor_module, accessors);
    for (long i = 0; i < RARRAY_LEN(fields); i++) {
        rb_define_method(accessors, RSTRING_PTR(RARRAY_AREF(fields, i)), observe_field_get, -1);
    }
    if (observe_writes) {
        if (rb_method_boundp(klass, rb_intern("[]="), 0)) {
            rb_define_method(accessors, "[]=", observe_index_set, -1);
        }
        for (long i = 0; i < RARRAY_LEN(fields); i++) {
            VALUE setter = rb_str_plus(RARRAY_AREF(fields, i), rb_str_new_cstr("="));
            rb_define_method(accessors, RSTRING_PTR(setter), observe_field_set, -1);
        }
    }
    rb_prepend_module(klass, accessors);
    reregister(klass);
}

static int inherits(VALUE klass, const char *name) {
    if (!RB_TYPE_P(klass, T_CLASS)) return 0;
    if (!rb_const_defined(rb_cObject, rb_intern(name))) return 0;

    VALUE parent = rb_const_get(rb_cObject, rb_intern(name));
    return RB_TYPE_P(parent, T_CLASS) && RTEST(rb_class_inherited_p(klass, parent));
}

void nk_attach_record(VALUE klass) {
    if (inherits(klass, "Struct")) {
        attach_record(klass, id_members, "Struct", observe_struct_new, 1);
    } else if (inherits(klass, "Data")) {
        attach_record(klass, id_members, "Data", observe_data_new, 0);
    }
}

struct const_lookup {
    VALUE scope;
    ID name;
};

static VALUE const_value(VALUE packed) {
    struct const_lookup *lookup = (struct const_lookup *)packed;
    return rb_const_get_at(lookup->scope, lookup->name);
}

// A record declared at a constant is noticed when the constant appears, which
// is the only way to see one created before the collector started. `autoload`
// fires this too, and resolving it here would force arbitrary files during
// require-time.
static VALUE nk_const_added(VALUE self, VALUE name) {
    VALUE result = rb_call_super_kw(1, &name, RB_NO_KEYWORDS);
    if (RTEST(rb_funcall(self, rb_intern("autoload?"), 2, name, Qfalse))) return result;

    ID constant = rb_to_id(name);
    if (!rb_const_defined_at(self, constant)) return result;

    struct const_lookup lookup = {self, constant};
    VALUE value = nk_guard(const_value, (VALUE)&lookup, Qnil);
    if (!NIL_P(value)) nk_attach_record(value);
    return result;
}

// The site a record was declared at is the caller of Struct.new / Data.define,
// and a wrapper implemented in C pushes no frame of its own, so the first level
// is already that caller.
static VALUE caller_site(void) {
    VALUE frames = rb_funcall(rb_mKernel, id_caller_locations, 2, INT2NUM(1), INT2NUM(1));
    if (!RB_TYPE_P(frames, T_ARRAY) || RARRAY_LEN(frames) == 0) return Qnil;

    VALUE frame = RARRAY_AREF(frames, 0);
    VALUE where = rb_funcall(frame, id_absolute_path, 0);
    if (!RB_TYPE_P(where, T_STRING)) where = rb_funcall(frame, id_path, 0);
    if (!RB_TYPE_P(where, T_STRING)) return Qnil;

    return rb_ary_new_from_args(2, nk_abs_path(where), rb_funcall(frame, id_lineno, 0));
}

static VALUE observe_definition(int argc, VALUE *argv, VALUE self) {
    VALUE site = caller_site();
    VALUE klass = rb_call_super_kw(argc, argv, RB_PASS_CALLED_KEYWORDS);
    if (RB_TYPE_P(site, T_ARRAY) && RB_TYPE_P(klass, T_CLASS)) {
        stamp_site(klass, RARRAY_AREF(site, 0), RARRAY_AREF(site, 1));
        nk_attach_record(klass);
    }
    return klass;
}

static void wrap_definer(VALUE owner, const char *selector, const char *display) {
    VALUE module = rb_module_new();
    rb_ary_push(record_wrappers, module);
    rb_define_method(module, selector, observe_definition, -1);
    rb_prepend_module(rb_singleton_class(owner), module);
    nk_register_wrapper(module, rb_intern(selector), rb_intern(display), rb_intern("class"), 1,
                        0, 0);
}

void nk_install_record_hooks(void) {
    static int installed = 0;
    if (installed) return;
    installed = 1;

    wrap_definer(rb_cStruct, "new", "Struct");
    if (rb_const_defined(rb_cObject, rb_intern("Data"))) {
        VALUE data = rb_const_get(rb_cObject, rb_intern("Data"));
        if (RB_TYPE_P(data, T_CLASS)) wrap_definer(data, "define", "Data");
    }

    VALUE watcher = rb_module_new();
    rb_ary_push(record_wrappers, watcher);
    rb_define_method(watcher, "const_added", nk_const_added, 1);
    rb_prepend_module(rb_cModule, watcher);
}

// A T::Struct subclass announces itself by being inherited, and the site is the
// class body that declared it.
static VALUE observe_tstruct_inherited(int argc, VALUE *argv, VALUE self) {
    VALUE result = rb_call_super_kw(argc, argv, RB_NO_KEYWORDS);
    if (argc < 1 || !RB_TYPE_P(argv[0], T_CLASS)) return result;

    VALUE site = caller_site();
    if (!RB_TYPE_P(site, T_ARRAY)) return result;
    if (!nk_analyzed_path(RARRAY_AREF(site, 0))) return result;

    VALUE child = argv[0];
    stamp_site(child, RARRAY_AREF(site, 0), RARRAY_AREF(site, 1));
    if (!claim_record(child)) return result;

    rb_ivar_set(child, id_family, rb_str_new_cstr("TStruct"));
    VALUE wrapper = rb_module_new();
    rb_ary_push(record_wrappers, wrapper);
    rb_ivar_set(child, id_constructor_module, wrapper);
    rb_define_method(wrapper, "new", observe_tstruct_new, -1);
    rb_prepend_module(rb_singleton_class(child), wrapper);
    nk_register_wrapper(wrapper, rb_intern("new"),
                        rb_intern_str(class_display_name(child, "AnonymousTStruct")),
                        rb_intern("class"), 1, rb_intern_str(RARRAY_AREF(site, 0)), 0);
    return result;
}

void nk_install_tstruct_hook(void) {
    static int installed = 0;
    if (installed) return;
    if (!rb_const_defined(rb_cObject, rb_intern("T"))) return;

    VALUE namespace = rb_const_get(rb_cObject, rb_intern("T"));
    if (!rb_const_defined_at(namespace, rb_intern("Struct"))) return;

    VALUE base = rb_const_get_at(namespace, rb_intern("Struct"));
    if (!RB_TYPE_P(base, T_CLASS)) return;

    installed = 1;
    VALUE module = rb_module_new();
    rb_ary_push(record_wrappers, module);
    rb_define_method(module, "inherited", observe_tstruct_inherited, -1);
    rb_prepend_module(rb_singleton_class(base), module);
}

static VALUE nk_install_tstruct(VALUE self) {
    nk_install_tstruct_hook();
    return Qnil;
}

// A record created before the collector started, or built by a test, is
// attached on request.
static VALUE nk_attach(VALUE self, VALUE klass) {
    nk_attach_record(klass);
    return Qnil;
}

// A class that carries props but did not reach the collector through
// `inherited` -- one built by a test, or defined before the hook installed.
static VALUE nk_attach_tstruct(VALUE self, VALUE klass) {
    if (!RB_TYPE_P(klass, T_CLASS) || !claim_record(klass)) return Qnil;

    rb_ivar_set(klass, id_family, rb_str_new_cstr("TStruct"));
    VALUE wrapper = rb_module_new();
    rb_ary_push(record_wrappers, wrapper);
    rb_ivar_set(klass, id_constructor_module, wrapper);
    rb_define_method(wrapper, "new", observe_tstruct_new, -1);
    rb_prepend_module(rb_singleton_class(klass), wrapper);
    nk_register_wrapper(wrapper, rb_intern("new"),
                        rb_intern_str(class_display_name(klass, "AnonymousTStruct")),
                        rb_intern("class"), 1, 0, 0);
    return Qnil;
}

// An OpenStruct has no declared fields at all: every assignment invents one,
// and the site that matters is the code doing the assigning rather than where
// OpenStruct itself is defined. The record is therefore keyed to the caller,
// through a stand-in carrying that site.
static VALUE ostruct_subject(VALUE instance) {
    VALUE site = caller_site();
    if (!RB_TYPE_P(site, T_ARRAY) || !nk_analyzed_path(RARRAY_AREF(site, 0))) return Qnil;

    VALUE subject = rb_obj_alloc(rb_cObject);
    rb_ivar_set(subject, id_struct_path, RARRAY_AREF(site, 0));
    rb_ivar_set(subject, id_struct_line, RARRAY_AREF(site, 1));
    return subject;
}

static VALUE ostruct_owner(VALUE instance) {
    VALUE name = rb_mod_name(rb_obj_class(instance));
    return NIL_P(name) ? rb_str_new_cstr("OpenStruct") : name;
}

static void observe_ostruct_field(VALUE instance, VALUE field, VALUE value) {
    VALUE subject = ostruct_subject(instance);
    if (NIL_P(subject)) return;

    nk_record_struct_field(subject, ostruct_owner(instance), rb_obj_as_string(field), value);
}

static int observe_ostruct_entry(VALUE key, VALUE value, VALUE instance) {
    observe_ostruct_field(instance, key, value);
    return ST_CONTINUE;
}

static VALUE observe_ostruct_init(int argc, VALUE *argv, VALUE self) {
    VALUE result = rb_call_super_kw(argc, argv, RB_PASS_CALLED_KEYWORDS);
    VALUE table = rb_attr_get(self, rb_intern("@table"));
    if (RB_TYPE_P(table, T_HASH)) rb_hash_foreach(table, observe_ostruct_entry, self);
    return result;
}

static VALUE observe_ostruct_set(int argc, VALUE *argv, VALUE self) {
    VALUE result = rb_call_super_kw(argc, argv, RB_PASS_CALLED_KEYWORDS);
    if (argc >= 2) observe_ostruct_field(self, argv[0], argv[1]);
    return result;
}

void nk_install_open_struct_hook(void) {
    static int installed = 0;
    if (installed) return;
    if (!rb_const_defined(rb_cObject, rb_intern("OpenStruct"))) return;

    VALUE klass = rb_const_get(rb_cObject, rb_intern("OpenStruct"));
    if (!RB_TYPE_P(klass, T_CLASS)) return;

    installed = 1;
    VALUE module = rb_module_new();
    rb_ary_push(record_wrappers, module);
    rb_define_method(module, "initialize", observe_ostruct_init, -1);
    rb_define_method(module, "[]=", observe_ostruct_set, -1);
    rb_prepend_module(klass, module);

    ID owner = rb_intern("OpenStruct");
    ID kind = rb_intern("instance");
    nk_register_wrapper(module, rb_intern("initialize"), owner, kind, 0, 0, 0);
    nk_register_wrapper(module, rb_intern("[]="), owner, kind, 0, 0, 0);
}

static VALUE nk_install_open_struct(VALUE self) {
    nk_install_open_struct_hook();
    return Qnil;
}

static VALUE nk_install_records(VALUE self) {
    nk_install_record_hooks();
    return Qnil;
}

// A T::Struct declares its fields as props and generates a keyword
// initializer; it is a record like any other once its fields are known.


static VALUE nk_install_tlet(VALUE self) {
    nk_install_tlet_hook();
    return Qnil;
}

VALUE nk_tlet_table(void) { return nk_tlet_observations(Qnil); }

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

    id_members = rb_intern("members");
    id_props = rb_intern("props");
    id_attached = rb_intern("@__nil_kill_attached");
    id_fields = rb_intern("@__nil_kill_struct_fields");
    id_family = rb_intern("@__nil_kill_record_family");
    id_struct_path = rb_intern("@__nil_kill_struct_path");
    id_struct_line = rb_intern("@__nil_kill_struct_line");
    id_initialize = rb_intern("initialize");
    id_source_location = rb_intern("source_location");
    id_instance_method = rb_intern("instance_method");
    id_respond_to = rb_intern("respond_to?");
    id_keys = rb_intern("keys");
    id_accessor_module = rb_intern("@__nil_kill_accessor_module");
    id_constructor_module = rb_intern("@__nil_kill_constructor_module");
    record_wrappers = rb_ary_new();
    rb_gc_register_address(&record_wrappers);

    rb_define_singleton_method(mod, "install_tlet_hook", nk_install_tlet, 0);
    rb_define_singleton_method(mod, "install_record_hooks", nk_install_records, 0);
    rb_define_singleton_method(mod, "attach_record", nk_attach, 1);
    rb_define_singleton_method(mod, "attach_tstruct", nk_attach_tstruct, 1);
    rb_define_singleton_method(mod, "install_open_struct_hook", nk_install_open_struct, 0);
    rb_define_singleton_method(mod, "install_tstruct_hook", nk_install_tstruct, 0);
    rb_define_singleton_method(mod, "configure_tlet_sites", nk_configure_tlet_sites, 1);
    rb_define_singleton_method(mod, "tlet_observations", nk_tlet_observations, 0);
}
