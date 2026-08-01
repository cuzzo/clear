// Installing the collector, and writing down what it saw.
//
// This is the whole of what used to be runtime_trace.rb. It runs inside the
// program under observation, which is why it is here and not in Ruby: every
// line of Ruby that loads into the traced process is a line the traced program
// can see, redefine, and be perturbed by.
//
// Two rules shape it. Nothing here dispatches a Ruby method that nil-kill
// itself defines -- reaching our own C through the interpreter's method lookup
// during `require` is what crashed four earlier attempts, and the entry points
// in collector.h exist so that it does not have to. And nothing here decides
// anything: the plan arrives already reshaped into flat demands, and the exit
// dump writes the collector's tables plus the raw gem table verbatim, leaving
// every policy question to the process that reads them.

#include <ruby.h>
#include <ruby/debug.h>
#include "collector.h"
#include "collections.h"
#include "declarations.h"
#include "records.h"
#include "value_domain.h"

#define NK_FIELD_SEP '\x02'

static VALUE boot_root;
static VALUE boot_out_dir;
static VALUE boot_targets;
static int boot_coverage_owned;

static int env_is(const char *name, const char *value) {
    const char *actual = getenv(name);
    return actual && strcmp(actual, value) == 0;
}

static VALUE join(VALUE base, const char *name) {
    return rb_str_cat_cstr(rb_str_cat_cstr(rb_str_dup(base), "/"), name);
}

static VALUE expand(VALUE path, VALUE base) {
    return rb_file_expand_path(path, base);
}

// The traced program may be launched from anywhere; every path the collector
// reports is relative to the project it was pointed at.
static VALUE resolve_root(void) {
    const char *root = getenv("NIL_KILL_ROOT");
    if (root && *root) return expand(rb_utf8_str_new_cstr(root), Qnil);
    // ext/nil_kill_trace -> the gem -> gems/ -> the workspace.
    return expand(rb_utf8_str_new_cstr("../../../.."),
                  expand(rb_utf8_str_new_cstr(__FILE__), Qnil));
}

static VALUE resolve_tmp_dir(void) {
    const char *tmp = getenv("NIL_KILL_TMP_DIR");
    if (tmp && *tmp) return expand(rb_utf8_str_new_cstr(tmp), boot_root);
    return join(join(boot_root, "tmp"), "nil-kill");
}

static VALUE resolve_out_dir(VALUE tmp_dir) {
    const char *out = getenv("NIL_KILL_RUNTIME_DIR");
    if (out && *out) return expand(rb_utf8_str_new_cstr(out), boot_root);
    return join(tmp_dir, "runtime");
}

static VALUE resolve_targets(void) {
    const char *raw = getenv("NIL_KILL_TARGETS");
    VALUE spec = rb_utf8_str_new_cstr(raw && *raw ? raw : "src");
    VALUE parts = rb_str_split(spec, ":");
    VALUE targets = rb_ary_new_capa(RARRAY_LEN(parts));
    for (long i = 0; i < RARRAY_LEN(parts); i++) {
        rb_ary_push(targets, expand(RARRAY_AREF(parts, i), boot_root));
    }
    return targets;
}

// ---- the collector plan ----------------------------------------------------
//
// One record per line, fields separated by \x02 because demand keys contain
// \x01 of their own. `t` a target directory, `d` a demanded coordinate and the
// anchor it answers, `s` a state coordinate and the ivar to read back, `f` a
// record field and whether it is still worth sampling, `l` a T.let site.

typedef struct {
    VALUE targets;
    VALUE demands;
    VALUE states;
    VALUE fields;
    VALUE tlets;
} plan_t;

static void plan_line(plan_t *plan, const char *line, long length) {
    if (length < 2 || line[1] != NK_FIELD_SEP) return;

    const char *rest = line + 2;
    long rest_length = length - 2;
    const char *split = memchr(rest, NK_FIELD_SEP, (size_t)rest_length);
    VALUE key = rb_utf8_str_new(rest, split ? split - rest : rest_length);
    VALUE value = Qnil;
    if (split) {
        value = rb_utf8_str_new(split + 1, rest_length - (split + 1 - rest));
    }

    switch (line[0]) {
      case 't': rb_ary_push(plan->targets, key); break;
      case 'd': if (split) rb_hash_aset(plan->demands, key, value); break;
      case 's': if (split) rb_hash_aset(plan->states, key, value); break;
      case 'f': if (split) rb_hash_aset(plan->fields, key, rb_str_cmp(value, rb_utf8_str_new_cstr("1")) == 0 ? Qtrue : Qfalse); break;
      case 'l': rb_hash_aset(plan->tlets, key, Qtrue); break;
      default: break;
    }
}

static void read_plan(plan_t *plan, VALUE path) {
    plan->targets = rb_ary_new();
    plan->demands = rb_hash_new();
    plan->states = rb_hash_new();
    plan->fields = rb_hash_new();
    plan->tlets = rb_hash_new();
    if (env_is("NIL_KILL_TRACE_PLAN", "0")) return;

    FILE *file = fopen(StringValueCStr(path), "rb");
    if (!file) return;

    char *line = NULL;
    size_t capacity = 0;
    ssize_t length;
    while ((length = getline(&line, &capacity, file)) > 0) {
        while (length > 0 && (line[length - 1] == '\n' || line[length - 1] == '\r')) length--;
        plan_line(plan, line, length);
    }
    free(line);
    fclose(file);
}

// A plan built for a different set of target directories describes a different
// program. Its demands are dropped rather than applied to this one.
static int plan_matches(plan_t *plan) {
    VALUE mine = rb_ary_sort(boot_targets);
    VALUE theirs = rb_ary_sort(plan->targets);
    if (RARRAY_LEN(mine) != RARRAY_LEN(theirs)) return 0;
    for (long i = 0; i < RARRAY_LEN(mine); i++) {
        if (rb_str_cmp(RARRAY_AREF(mine, i), RARRAY_AREF(theirs, i)) != 0) return 0;
    }
    return 1;
}

// ---- coverage --------------------------------------------------------------
//
// Ruby's own line coverage, in oneshot mode: the report needs to tell a tracer
// miss from a line the workload never ran, and reachability answers that
// without charging every hot line a counter update.

static VALUE coverage_module(void) {
    return rb_const_get(rb_cObject, rb_intern("Coverage"));
}

static VALUE start_coverage_body(VALUE unused) {
    (void)unused;
    if (env_is("NIL_KILL_COLLECT_COVERAGE", "0")) return Qfalse;

    rb_require("coverage");
    VALUE coverage = coverage_module();
    if (rb_respond_to(coverage, rb_intern("running?")) &&
        RTEST(rb_funcall(coverage, rb_intern("running?"), 0))) {
        return env_is("NIL_KILL_SHARED_COVERAGE", "1") ? Qtrue : Qfalse;
    }
    VALUE options = rb_hash_new();
    rb_hash_aset(options, ID2SYM(rb_intern("oneshot_lines")), Qtrue);
    rb_funcall(coverage, rb_intern("start"), 1, options);
    return Qtrue;
}

static void start_coverage(void) {
    int failed = 0;
    VALUE owned = rb_protect(start_coverage_body, Qnil, &failed);
    boot_coverage_owned = !failed && RTEST(owned);
    if (failed) rb_set_errinfo(Qnil);
}

// ---- the exit dump ---------------------------------------------------------

static int target_covers(VALUE path) {
    for (long i = 0; i < RARRAY_LEN(boot_targets); i++) {
        VALUE target = RARRAY_AREF(boot_targets, i);
        if (rb_str_cmp(path, target) == 0) return 1;
        long length = RSTRING_LEN(target);
        if (RSTRING_LEN(path) > length + 1 &&
            memcmp(RSTRING_PTR(path), RSTRING_PTR(target), (size_t)length) == 0 &&
            RSTRING_PTR(path)[length] == '/') {
            return 1;
        }
    }
    return 0;
}

// Which gem a file belongs to is a fact only this VM holds; which package that
// makes it is a policy decision, and stays out of the traced process.
static VALUE spec_rows(VALUE specs) {
    VALUE rows = rb_ary_new_capa(RARRAY_LEN(specs));
    for (long i = 0; i < RARRAY_LEN(specs); i++) {
        VALUE spec = RARRAY_AREF(specs, i);
        rb_ary_push(rows, rb_ary_new_from_args(3,
            rb_obj_as_string(rb_funcall(spec, rb_intern("name"), 0)),
            rb_obj_as_string(rb_funcall(spec, rb_intern("version"), 0)),
            expand(rb_obj_as_string(rb_funcall(spec, rb_intern("full_gem_path"), 0)), Qnil)));
    }
    return rows;
}

static VALUE loaded_specs(void) {
    VALUE gem = rb_const_get(rb_cObject, rb_intern("Gem"));
    return spec_rows(rb_funcall(rb_funcall(gem, rb_intern("loaded_specs"), 0), rb_intern("values"), 0));
}

static VALUE default_specs(void) {
    VALUE gem = rb_const_get(rb_cObject, rb_intern("Gem"));
    return spec_rows(rb_funcall(rb_const_get(gem, rb_intern("Specification")),
                                rb_intern("default_stubs"), 0));
}

static VALUE env_string(const char *name) {
    const char *value = getenv(name);
    return value ? rb_utf8_str_new_cstr(value) : Qnil;
}

static void write_gz(VALUE name, VALUE json) {
    rb_require("zlib");
    VALUE path = rb_str_cat_cstr(rb_str_dup(boot_out_dir), "/");
    rb_str_append(path, name);
    VALUE io = rb_funcall(rb_cFile, rb_intern("open"), 2, path, rb_utf8_str_new_cstr("wb"));
    VALUE writer = rb_const_get(rb_const_get(rb_cObject, rb_intern("Zlib")), rb_intern("GzipWriter"));
    VALUE gz = rb_funcall(writer, rb_intern("new"), 1, io);
    rb_funcall(gz, rb_intern("write"), 1, json);
    rb_funcall(gz, rb_intern("close"), 0);
}

static VALUE coverage_table(void) {
    if (!boot_coverage_owned) return Qnil;

    rb_require("coverage");
    VALUE options = rb_hash_new();
    rb_hash_aset(options, ID2SYM(rb_intern("stop")), Qfalse);
    rb_hash_aset(options, ID2SYM(rb_intern("clear")), Qfalse);
    VALUE result = rb_funcall(coverage_module(), rb_intern("result"), 1, options);
    VALUE paths = rb_funcall(result, rb_intern("keys"), 0);
    VALUE table = rb_hash_new();
    for (long i = 0; i < RARRAY_LEN(paths); i++) {
        VALUE raw = RARRAY_AREF(paths, i);
        VALUE absolute = nk_abs_path(raw);
        if (!target_covers(absolute)) continue;

        rb_hash_aset(table, absolute, rb_hash_aref(result, raw));
    }
    return table;
}

static VALUE dump_body(VALUE unused) {
    (void)unused;
    nk_stop_observing();
    rb_funcall(rb_const_get(rb_cObject, rb_intern("FileUtils")), rb_intern("mkdir_p"), 1, boot_out_dir);

    VALUE document = nk_core_tables();
    nk_record_tables(document);
    rb_hash_aset(document, ID2SYM(rb_intern("collections")), nk_collection_table());
    rb_hash_aset(document, ID2SYM(rb_intern("tlets")), nk_tlet_table());
    rb_hash_aset(document, ID2SYM(rb_intern("pid")), rb_funcall(rb_mProcess, rb_intern("pid"), 0));
    VALUE run_id = env_string("NIL_KILL_RUN_ID");
    rb_hash_aset(document, ID2SYM(rb_intern("run_id")), NIL_P(run_id) ? rb_utf8_str_new_cstr("") : run_id);
    rb_hash_aset(document, ID2SYM(rb_intern("root")), boot_root);
    rb_hash_aset(document, ID2SYM(rb_intern("targets")), boot_targets);
    // What the runtime was when it observed. The orchestrator has to repeat
    // these claims from outside the traced program, and a trace whose claims
    // disagree with them is rejected at merge -- so they come from the VM that
    // did the observing rather than from whatever happens to be orchestrating.
    const char *const runtime[] = {"ruby_version", "RUBY_VERSION",
                                   "ruby_engine", "RUBY_ENGINE",
                                   "ruby_engine_version", "RUBY_ENGINE_VERSION"};
    for (size_t i = 0; i < sizeof(runtime) / sizeof(runtime[0]); i += 2) {
        ID name = rb_intern(runtime[i + 1]);
        if (!rb_const_defined(rb_cObject, name)) continue;

        rb_hash_aset(document, ID2SYM(rb_intern(runtime[i])), rb_const_get(rb_cObject, name));
    }
    rb_hash_aset(document, ID2SYM(rb_intern("gem_specs")), loaded_specs());
    rb_hash_aset(document, ID2SYM(rb_intern("default_gem_specs")), default_specs());
    rb_hash_aset(document, ID2SYM(rb_intern("coverage")), coverage_table());

    rb_require("json");
    VALUE json = rb_funcall(rb_const_get(rb_cObject, rb_intern("JSON")), rb_intern("generate"), 1, document);
    VALUE pid = rb_obj_as_string(rb_funcall(rb_mProcess, rb_intern("pid"), 0));
    write_gz(rb_sprintf("collector-raw-%" PRIsVALUE ".json.gz", pid), json);
    return Qnil;
}

static void on_exit_dump(VALUE unused) {
    (void)unused;
    int failed = 0;
    rb_protect(dump_body, Qnil, &failed);
    if (failed) {
        VALUE error = rb_errinfo();
        rb_set_errinfo(Qnil);
        rb_warn("nil-kill: the collector could not write its observations: %" PRIsVALUE,
                rb_funcall(error, rb_intern("message"), 0));
    }
}

// ---- installation ----------------------------------------------------------

static void on_body_end(VALUE tracepoint, void *unused) {
    (void)tracepoint;
    (void)unused;
    nk_install_tlet_hook();
}

static VALUE require_quietly(VALUE feature) {
    rb_require(StringValueCStr(feature));
    return Qnil;
}

static void try_require(const char *feature) {
    int failed = 0;
    rb_protect(require_quietly, rb_utf8_str_new_cstr(feature), &failed);
    if (failed) rb_set_errinfo(Qnil);
}

static VALUE nk_bootstrap(VALUE self) {
    (void)self;
    if (!RB_NIL_P(boot_root)) return Qfalse;

    boot_root = resolve_root();
    rb_gc_register_address(&boot_root);
    VALUE tmp_dir = resolve_tmp_dir();
    boot_out_dir = resolve_out_dir(tmp_dir);
    rb_gc_register_address(&boot_out_dir);
    boot_targets = resolve_targets();
    rb_gc_register_address(&boot_targets);

    plan_t plan;
    read_plan(&plan, join(tmp_dir, "collector-plan.tsv"));
    if (!plan_matches(&plan)) {
        plan.demands = rb_hash_new();
        plan.states = rb_hash_new();
        plan.fields = rb_hash_new();
        plan.tlets = rb_hash_new();
    }

    start_coverage();
    nk_use_targets(boot_targets);
    if (env_is("NIL_KILL_RUNTIME_SCIP", "1")) {
        nk_use_root(boot_root);
        nk_use_demands(boot_targets, plan.demands, plan.states);
        nk_start_observing();
    }

    try_require("sorbet-runtime");
    nk_use_struct_fields(plan.fields);
    nk_use_tlet_sites(plan.tlets);
    nk_install_tlet_hook();
    nk_install_record_hooks();

    try_require("ostruct");
    nk_install_open_struct_hook();
    nk_install_tstruct_hook();
    if (!env_is("NIL_KILL_TRACE_COLLECTIONS", "0")) nk_install_collection_hook();

    // Sorbet may be loaded after the collector starts, so `T` is looked for
    // again whenever a class or module body finishes.
    VALUE ends = rb_tracepoint_new(Qnil, RUBY_EVENT_END, on_body_end, NULL);
    rb_gc_register_mark_object(ends);
    rb_tracepoint_enable(ends);

    rb_require("fileutils");
    rb_set_end_proc(on_exit_dump, Qnil);
    return Qtrue;
}

// `ruby -r.../nil_kill_trace.so` is the whole of the collector's installation.
// There is no Ruby file to preload, so there is no nil-kill Ruby in the traced
// program at all.
void nk_bootstrap_init(VALUE mod) {
    boot_root = Qnil;
    rb_define_singleton_method(mod, "bootstrap", nk_bootstrap, 0);
}

// Last, because installing reads tables the rest of Init is still building.
void nk_bootstrap_autostart(void) {
    if (env_is("NIL_KILL_TRACE", "1")) nk_bootstrap(Qnil);
}
