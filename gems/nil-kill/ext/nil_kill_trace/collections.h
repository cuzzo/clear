// What a collection was carrying, and who owned it.
#ifndef NIL_KILL_COLLECTIONS_H
#define NIL_KILL_COLLECTIONS_H

#include <ruby.h>

void nk_collections_init(VALUE mod);
void nk_install_collection_hook(void);
void nk_register_collection_owner(VALUE value, VALUE owner, VALUE shape);

// The collector's own answer to whether a path is analyzed source.
int nk_analyzed_path(VALUE path);

#endif
