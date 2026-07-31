// The declaration hooks the collector installs.
#ifndef NIL_KILL_DECLARATIONS_H
#define NIL_KILL_DECLARATIONS_H

#include <ruby.h>

void nk_declarations_init(VALUE mod);
void nk_install_tlet_hook(void);
void nk_install_record_hooks(void);
void nk_install_tstruct_hook(void);
void nk_install_open_struct_hook(void);
void nk_attach_record(VALUE klass);

#endif
