CC      ?= cc
CFLAGS  ?= -O2 -Wall -Wextra

vm: vm.c
	$(CC) $(CFLAGS) -o vm vm.c

# `make run-foo` compiles foo.puck -> foo.puckc and runs through the VM.
run-%: vm
	ruby compile.rb $*.puck $*.puckc
	./vm $*.puckc

# Debug build with gdb / Valgrind / sanitizer friendly flags.
vm-debug: vm.c
	$(CC) -O0 -g -Wall -Wextra -fsanitize=address,undefined -o vm-debug vm.c

clean:
	rm -f vm vm-debug *.puckc

.PHONY: clean run-%
