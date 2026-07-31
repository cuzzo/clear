// Installing the collector, and writing down what it saw.
#ifndef NIL_KILL_BOOTSTRAP_H
#define NIL_KILL_BOOTSTRAP_H

#include <ruby.h>

void nk_bootstrap_init(VALUE mod);
void nk_bootstrap_autostart(void);

#endif
