// The declaration hooks the collector installs.
#ifndef NIL_KILL_DECLARATIONS_H
#define NIL_KILL_DECLARATIONS_H

#include <ruby.h>

void nk_declarations_init(VALUE mod);
void nk_install_tlet_hook(void);

#endif
