CC      ?= cc
CFLAGS  ?= -O2 -Wall -Wextra

vm: vm.c jit.c jit.h vm_types.h
	$(CC) $(CFLAGS) -o vm vm.c jit.c

run-%: vm
	ruby compile.rb $*.puck $*.puckc
	./vm $*.puckc

# Same shape, but with one level of subdirectory in the stem so that
# `make run-bench/fib` works even though GNU make's % pattern won't match
# a path with '/' in implicit-rule search.
run-bench/%: vm
	ruby compile.rb bench/$*.puck bench/$*.puckc
	./vm bench/$*.puckc

vm-debug: vm.c jit.c jit.h vm_types.h
	$(CC) -O0 -g -Wall -Wextra -fsanitize=address,undefined -o vm-debug vm.c jit.c

clean:
	rm -f vm vm-debug *.puckc bench/*.puckc

.PHONY: clean run-%
