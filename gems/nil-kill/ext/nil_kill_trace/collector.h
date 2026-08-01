// The collector's own entry points, callable without Ruby method dispatch.
#ifndef NIL_KILL_COLLECTOR_H
#define NIL_KILL_COLLECTOR_H

#include <ruby.h>

void nk_use_targets(VALUE roots);
void nk_use_demands(VALUE roots, VALUE anchor_map, VALUE state_map);
void nk_start_observing(void);
void nk_stop_observing(void);

// Everything the collector holds, in one document.
VALUE nk_core_tables(void);

#endif
