// What a record's fields were holding.
#ifndef NIL_KILL_RECORDS_H
#define NIL_KILL_RECORDS_H

#include <ruby.h>

void nk_records_init(VALUE mod);
void nk_record_struct_field(VALUE klass, VALUE class_name, VALUE field, VALUE value);
void nk_use_struct_fields(VALUE fields);

void nk_record_tables(VALUE into);

#endif
