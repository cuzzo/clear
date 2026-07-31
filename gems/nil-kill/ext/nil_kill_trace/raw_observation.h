// What the VM saw, before anything decides what it means.
#ifndef NIL_KILL_RAW_OBSERVATION_H
#define NIL_KILL_RAW_OBSERVATION_H

#include <ruby.h>

void nk_raw_observation_init(VALUE mod);
VALUE nk_raw_observation(VALUE value);
VALUE raw_observe_guarded(VALUE value);

#endif
