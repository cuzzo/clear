CC      ?= cc
CFLAGS  ?= -O2 -Wall -Wextra

vm: vm.c jit.c jit.h vm_types.h
	$(CC) $(CFLAGS) -o vm vm.c jit.c

run-%: vm
	ruby compile.rb $*.puck $*.puckc
	./vm $*.puckc

vm-debug: vm.c jit.c jit.h vm_types.h
	$(CC) -O0 -g -Wall -Wextra -fsanitize=address,undefined -o vm-debug vm.c jit.c

clean:
	rm -f vm vm-debug *.puckc bench/*.puckc

.PHONY: clean run-%
