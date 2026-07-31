// Who a call actually reached.
//
// The class the VM reports is often not the owner the evidence needs. A
// generated record accessor, a Sorbet constructor, a T.let -- each is reached
// through a wrapper the declaration hooks installed, and the hook records what
// the wrapper stands for. An anonymous class has no name to report but its
// methods still have a declaration site, and a singleton class of a plain
// object -- ENV is the usual one -- is named by the constant holding it.
//
// This ran in Ruby and the collector asked it once per (class, selector) from
// inside the observation hook. It was the last question the hook had to leave
// the interpreter to answer.

#include <ruby.h>
#include <ruby/st.h>
#include "identity.h"
#include "value_domain.h"

typedef struct {
    ID owner;
    ID kind;
    int native; // -1 unset, 0 false, 1 true
    ID path;
    int line;
} wrapper_t;

static st_table *wrappers;       // defined_class identity -> selector -> wrapper_t*
static VALUE wrapper_classes;    // holds those classes alive
static VALUE declaration_memo;   // Class -> [path, line] or nil
static VALUE singleton_owners;   // object id -> [name, "class"]
static long singleton_owner_generation = -1;

static ID id_const_source_location, id_file_p, id_constants,
    id_autoload_p, id_source_location, id_instance_method, id_method, id_members;

// ------------------------------------------------------------------ registry

void nk_register_wrapper(VALUE defined_class, ID selector, ID owner, ID kind,
                         int native, ID path, int line) {
    st_data_t found;
    st_table *by_selector;
    if (st_lookup(wrappers, (st_data_t)defined_class, &found)) {
        by_selector = (st_table *)found;
    } else {
        by_selector = st_init_numtable();
        st_insert(wrappers, (st_data_t)defined_class, (st_data_t)by_selector);
        rb_ary_push(wrapper_classes, defined_class);
    }
    wrapper_t *wrapper = ALLOC(wrapper_t);
    wrapper->owner = owner;
    wrapper->kind = kind;
    wrapper->native = native;
    wrapper->path = path;
    wrapper->line = line;
    st_insert(by_selector, (st_data_t)selector, (st_data_t)wrapper);
}

static wrapper_t *wrapper_for(VALUE defined_class, ID selector) {
    st_data_t found;
    if (!st_lookup(wrappers, (st_data_t)defined_class, &found)) return NULL;
    st_data_t hit;
    if (!st_lookup((st_table *)found, (st_data_t)selector, &hit)) return NULL;
    return (wrapper_t *)hit;
}

// A hook records what the wrapper it just installed stands for. Registering is
// the hook's half of the contract; reading it is this file's.
static VALUE nk_register(int argc, VALUE *argv, VALUE self) {
    VALUE defined_class, selector, owner, kind, native, path, line;
    rb_scan_args(argc, argv, "7", &defined_class, &selector, &owner, &kind, &native,
                 &path, &line);
    nk_register_wrapper(
        defined_class, rb_to_id(selector),
        RB_TYPE_P(owner, T_STRING) ? rb_intern_str(owner) : 0,
        RB_TYPE_P(kind, T_STRING) ? rb_intern_str(kind) : 0,
        NIL_P(native) ? -1 : (RTEST(native) ? 1 : 0),
        RB_TYPE_P(path, T_STRING) ? rb_intern_str(path) : 0,
        NIL_P(line) ? 0 : NUM2INT(line));
    return Qnil;
}

// ------------------------------------------------------------ declaration site

static int is_module(VALUE value) {
    return RB_TYPE_P(value, T_CLASS) || RB_TYPE_P(value, T_MODULE);
}

static VALUE attached_object(VALUE singleton) {
    if (!RB_TYPE_P(singleton, T_CLASS) || !FL_TEST(singleton, FL_SINGLETON)) return Qnil;
    return rb_attr_get(singleton, rb_intern("__attached__"));
}

struct located {
    VALUE klass;
};

// A generated record carries the site it was declared at, stamped by the hook
// that saw it created. Anything else is asked where its constant is.
static VALUE declaration_uncached(VALUE packed) {
    VALUE klass = ((struct located *)packed)->klass;
    VALUE path = rb_attr_get(klass, rb_intern("@__nil_kill_struct_path"));
    VALUE line = rb_attr_get(klass, rb_intern("@__nil_kill_struct_line"));
    if (!RB_TYPE_P(path, T_STRING) || !RB_INTEGER_TYPE_P(line)) {
        VALUE name = rb_mod_name(klass);
        if (NIL_P(name) || RSTRING_LEN(name) == 0) return Qnil;

        VALUE location = rb_funcall(rb_cObject, id_const_source_location, 1, name);
        if (!RB_TYPE_P(location, T_ARRAY) || RARRAY_LEN(location) < 2) return Qnil;
        path = RARRAY_AREF(location, 0);
        line = RARRAY_AREF(location, 1);
    }
    if (!RB_TYPE_P(path, T_STRING) || !RB_INTEGER_TYPE_P(line)) return Qnil;
    if (RSTRING_LEN(path) > 0 && RSTRING_PTR(path)[0] == '<') return Qnil;

    VALUE absolute = nk_abs_path(path);
    if (!RTEST(rb_funcall(rb_cFile, id_file_p, 1, absolute))) return Qnil;

    return rb_ary_new_from_args(2, absolute, line);
}

// The class a method is defined on, which for a singleton is the module it is
// attached to. A constant defined in C reports its extension file with line 0;
// that is a load location, not a declaration, and claiming it turns an opaque
// CRuby method into apparent project source.
static VALUE declaration_site(VALUE defined_class) {
    if (!is_module(defined_class)) return Qnil;

    VALUE subject = defined_class;
    if (RB_TYPE_P(defined_class, T_CLASS) && FL_TEST(defined_class, FL_SINGLETON)) {
        subject = attached_object(defined_class);
        if (!is_module(subject)) return Qnil;
    }

    VALUE cached = rb_hash_lookup2(declaration_memo, subject, Qundef);
    if (cached == Qundef) {
        struct located request = {subject};
        cached = nk_guard(declaration_uncached, (VALUE)&request, Qnil);
        rb_hash_aset(declaration_memo, subject, cached);
    }
    if (!RB_TYPE_P(cached, T_ARRAY)) return Qnil;
    return NUM2INT(RARRAY_AREF(cached, 1)) > 0 ? cached : Qnil;
}

// ----------------------------------------------------------------- owner names

// Ruby exposes singleton methods on constant objects such as ENV through an
// anonymous singleton class, so the constant holding the object is its only
// source-level name. Autoloads are skipped: observation must not change what
// the program loads.
static VALUE build_singleton_owners(VALUE unused) {
    VALUE constants = rb_funcall(rb_cObject, id_constants, 1, Qfalse);
    VALUE owners = rb_hash_new();
    VALUE sorted = rb_ary_sort(constants);
    for (long i = 0; i < RARRAY_LEN(sorted); i++) {
        VALUE name = RARRAY_AREF(sorted, i);
        if (RTEST(rb_funcall(rb_cObject, id_autoload_p, 1, name))) continue;

        ID constant = rb_to_id(name);
        if (!rb_const_defined_at(rb_cObject, constant)) continue;

        VALUE value = rb_const_get_at(rb_cObject, constant);
        VALUE key = rb_obj_id(value);
        if (rb_hash_lookup2(owners, key, Qundef) == Qundef) {
            rb_hash_aset(owners, key,
                         rb_ary_new_from_args(2, rb_obj_as_string(name),
                                              rb_str_new_cstr("class")));
        }
    }
    return owners;
}

static VALUE named_singleton_owner(VALUE value) {
    // Rebuilt only when a new top-level constant appears, which is what the
    // Ruby this replaces used as its cache key too.
    long generation = RARRAY_LEN(rb_funcall(rb_cObject, id_constants, 1, Qfalse));
    if (generation != singleton_owner_generation) {
        singleton_owners = nk_guard(build_singleton_owners, Qnil, rb_hash_new());
        singleton_owner_generation = generation;
    }
    return rb_hash_lookup2(singleton_owners, rb_obj_id(value), Qnil);
}

struct owner_request {
    VALUE defined_class;
    ID selector;
};

// An anonymous record is identified by its members, not by where it was
// declared: two anonymous Structs sharing a file and line are the same record
// contract only if they expose the same fields.
static VALUE anonymous_record_owner(VALUE packed) {
    VALUE klass = ((struct owner_request *)packed)->defined_class;
    if (!RB_TYPE_P(klass, T_CLASS) || !RTEST(rb_class_inherited_p(klass, rb_cStruct))) {
        return Qnil;
    }
    VALUE fields = rb_funcall(klass, id_members, 0);
    if (!RB_TYPE_P(fields, T_ARRAY) || RARRAY_LEN(fields) == 0) return Qnil;

    VALUE names = rb_ary_new_capa(RARRAY_LEN(fields));
    for (long i = 0; i < RARRAY_LEN(fields); i++) {
        rb_ary_push(names, rb_obj_as_string(RARRAY_AREF(fields, i)));
    }
    return rb_ary_new_from_args(
        2, rb_sprintf("AnonymousStruct(%" PRIsVALUE ")", rb_ary_join(names, rb_str_new_cstr(","))),
        rb_str_new_cstr("instance"));
}

static VALUE relative_declaration_path(VALUE path) {
    VALUE absolute = nk_abs_path(path);
    VALUE root = nk_root_path();
    if (rb_str_equal(absolute, root)) return rb_str_new_cstr(".");

    VALUE prefix = rb_str_dup(root);
    rb_str_cat_cstr(prefix, "/");
    if (RSTRING_LEN(absolute) > RSTRING_LEN(prefix) &&
        memcmp(RSTRING_PTR(absolute), RSTRING_PTR(prefix), (size_t)RSTRING_LEN(prefix)) == 0) {
        return rb_str_new(RSTRING_PTR(absolute) + RSTRING_LEN(prefix),
                          RSTRING_LEN(absolute) - RSTRING_LEN(prefix));
    }
    return absolute;
}

// An anonymous class has no name to report, but its methods still have a
// declaration site, and that site is the identity FactMine joins on.
static VALUE anonymous_owner(VALUE packed) {
    struct owner_request *request = (struct owner_request *)packed;
    VALUE defined_class = request->defined_class;
    if (!is_module(defined_class)) return Qnil;

    int singleton = RB_TYPE_P(defined_class, T_CLASS) && FL_TEST(defined_class, FL_SINGLETON);
    VALUE subject = singleton ? attached_object(defined_class) : defined_class;
    if (!is_module(subject)) return Qnil;

    VALUE method = singleton
                       ? rb_funcall(subject, id_method, 1, ID2SYM(request->selector))
                       : rb_funcall(subject, id_instance_method, 1, ID2SYM(request->selector));
    VALUE location = rb_funcall(method, id_source_location, 0);
    if (!RB_TYPE_P(location, T_ARRAY) || RARRAY_LEN(location) < 2) return Qnil;
    VALUE path = RARRAY_AREF(location, 0);
    VALUE line = RARRAY_AREF(location, 1);
    if (!RB_TYPE_P(path, T_STRING) || !RB_INTEGER_TYPE_P(line)) return Qnil;

    return rb_ary_new_from_args(
        2,
        rb_sprintf("%s(%" PRIsVALUE ":%" PRIsVALUE ")",
                   singleton ? "AnonymousSingleton" : "AnonymousClass",
                   relative_declaration_path(path), line),
        rb_str_new_cstr(singleton ? "class" : "instance"));
}

// The plain name of the class a method is defined on, with a singleton
// resolved to what it is attached to.
static VALUE plain_owner(VALUE defined_class) {
    if (!is_module(defined_class)) return Qnil;

    if (RB_TYPE_P(defined_class, T_CLASS) && FL_TEST(defined_class, FL_SINGLETON)) {
        VALUE attached = attached_object(defined_class);
        VALUE name = is_module(attached) ? rb_mod_name(attached) : Qnil;
        return NIL_P(name) ? Qnil
                           : rb_ary_new_from_args(2, name, rb_str_new_cstr("class"));
    }
    VALUE name = rb_mod_name(defined_class);
    return NIL_P(name) ? Qnil
                       : rb_ary_new_from_args(2, name, rb_str_new_cstr("instance"));
}

// ------------------------------------------------------------------- identity

VALUE nk_callee_identity(VALUE defined_class, ID selector, int native) {
    VALUE declared = declaration_site(defined_class);
    VALUE site_path = RB_TYPE_P(declared, T_ARRAY) ? RARRAY_AREF(declared, 0) : Qnil;
    VALUE site_line = RB_TYPE_P(declared, T_ARRAY) ? RARRAY_AREF(declared, 1) : Qnil;

    wrapper_t *wrapper = wrapper_for(defined_class, selector);
    if (wrapper) {
        VALUE line = wrapper->line > 0 ? INT2NUM(wrapper->line) : site_line;
        return rb_ary_new_from_args(
            5, wrapper->owner ? rb_id2str(wrapper->owner) : Qnil,
            wrapper->kind ? rb_id2str(wrapper->kind) : Qnil,
            wrapper->native < 0 ? Qnil : (wrapper->native ? Qtrue : Qfalse),
            wrapper->path ? rb_id2str(wrapper->path) : Qnil, line);
    }

    // A C-backed method has no Ruby definition site of its own, but the module
    // it is defined on does. Core classes have none at all, so this stays nil
    // for String#to_s and its peers.
    if (!native) {
        site_path = Qnil;
        site_line = Qnil;
    }

    if (RB_TYPE_P(defined_class, T_CLASS) && FL_TEST(defined_class, FL_SINGLETON)) {
        VALUE attached = attached_object(defined_class);
        if (!NIL_P(attached)) {
            VALUE named = nk_guard(named_singleton_owner, attached, Qnil);
            if (RB_TYPE_P(named, T_ARRAY)) {
                return rb_ary_new_from_args(5, RARRAY_AREF(named, 0), RARRAY_AREF(named, 1),
                                            Qnil, site_path, site_line);
            }
        }
    }

    struct owner_request request = {defined_class, selector};
    VALUE owner = plain_owner(defined_class);
    if (!RB_TYPE_P(owner, T_ARRAY)) {
        owner = nk_guard(anonymous_record_owner, (VALUE)&request, Qnil);
    }
    if (!RB_TYPE_P(owner, T_ARRAY)) {
        owner = nk_guard(anonymous_owner, (VALUE)&request, Qnil);
    }
    if (!RB_TYPE_P(owner, T_ARRAY)) {
        return rb_ary_new_from_args(5, Qnil, rb_str_new_cstr("instance"), Qnil, site_path,
                                    site_line);
    }
    return rb_ary_new_from_args(5, RARRAY_AREF(owner, 0), RARRAY_AREF(owner, 1), Qnil,
                                site_path, site_line);
}

static VALUE nk_identity_for(VALUE self, VALUE defined_class, VALUE selector, VALUE native) {
    return nk_callee_identity(defined_class, rb_to_id(selector), RTEST(native));
}

static VALUE nk_reset_identity(VALUE self) {
    rb_funcall(declaration_memo, rb_intern("clear"), 0);
    singleton_owner_generation = -1;
    return Qnil;
}

void nk_identity_init(VALUE mod) {
    wrappers = st_init_numtable();
    wrapper_classes = rb_ary_new();
    rb_gc_register_address(&wrapper_classes);
    declaration_memo = rb_hash_new();
    rb_gc_register_address(&declaration_memo);
    singleton_owners = rb_hash_new();
    rb_gc_register_address(&singleton_owners);

    id_const_source_location = rb_intern("const_source_location");
    id_file_p = rb_intern("file?");
    id_constants = rb_intern("constants");
    id_autoload_p = rb_intern("autoload?");
    id_source_location = rb_intern("source_location");
    id_instance_method = rb_intern("instance_method");
    id_method = rb_intern("method");
    id_members = rb_intern("members");

    rb_define_singleton_method(mod, "register_wrapper", nk_register, -1);
    rb_define_singleton_method(mod, "callee_identity", nk_identity_for, 3);
    rb_define_singleton_method(mod, "reset_identity", nk_reset_identity, 0);
}
