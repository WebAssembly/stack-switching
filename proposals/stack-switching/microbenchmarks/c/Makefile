.SUFFIXES:  # Suppress default make recipes for C

# A generic set of make rules.
CONFIG=make.config
include ${CONFIG}

ifeq ($(WASMFX_PRESERVE_SHADOW_STACK),1)
  SHADOW_STACK_FLAG=-DFIBER_WASMFX_PRESERVE_SHADOW_STACK
else
  SHADOW_STACK_FLAG=
endif

.PHONY: all
BENCHMARKS= hello itersum pi sieve skynet state treesum treesumlinear roundrobin c10m
SWITCH_BENCHMARKS= hello itersum treesum pi roundrobin

# This strange invocation tells make not to delete "intermediate products".
.SECONDARY:

# Initial table size. In the paper, we had this conditionally overridden for c10m,
# but that makes the Makefile not really deterministic, and setting it to a fixed
# value seems not to slow things down.
WASMFX_CONT_TABLE_INITIAL_CAPACITY=16384

all: $(BENCHMARKS) $(SWITCH_BENCHMARKS)

%: bin/%_asyncify.wasm bin/%_wasmfx.wasm bin/%_asyncify.cwasm bin/%_wasmfx.cwasm \
	bin/%_asyncify.stripped.wasm bin/%_wasmfx.stripped.wasm
			@echo Made $@ #from $^

$(SWITCH_BENCHMARKS): %: bin/%_switch_asyncify.wasm bin/%_switch_wasmfx.wasm \
	bin/%_switch_asyncify.cwasm bin/%_switch_wasmfx.cwasm \
	bin/%_switch_asyncify.stripped.wasm bin/%_switch_wasmfx.stripped.wasm

bin/%_asyncify.wasm: %.c inc/fiber.h src/asyncify/asyncify_impl.c | bin
	$(WASICC) -DSTACK_POOL_SIZE=$(STACK_POOL_SIZE) -DASYNCIFY_DEFAULT_STACK_SIZE=$(ASYNCIFY_DEFAULT_STACK_SIZE) src/asyncify/asyncify_impl.c $(WASI_FLAGS) $< -o $(@:.wasm=.pre.wasm)
	$(ASYNCIFY) $(ASYNCIFY_FLAGS) $(@:.wasm=.pre.wasm) -o $@
	chmod +x $@

bin/%_switch_asyncify.wasm: %_switch.c inc/fiber_switch.h src/asyncify/asyncify_impl.c | bin
	$(WASICC) -DSTACK_POOL_SIZE=$(STACK_POOL_SIZE) -DASYNCIFY_DEFAULT_STACK_SIZE=$(ASYNCIFY_DEFAULT_STACK_SIZE) src/asyncify/asyncify_switch_impl.c $(WASI_FLAGS) $< -o $(@:.wasm=.pre.wasm)
	$(ASYNCIFY) $(ASYNCIFY_FLAGS) $(@:.wasm=.pre.wasm) -o $@
	chmod +x $@

fiber_wasmfx_imports.wasm: src/wasmfx/imports.wat
	$(WASM_INTERP) -d -i $< -o $@

fiber_switch_wasmfx_imports.wasm: src/wasmfx/imports_switch.wat
	$(WASM_INTERP) -d -i src/wasmfx/imports_switch.wat -o fiber_switch_wasmfx_imports.wasm

bin/%_wasmfx.unopt.wasm: %.c inc/fiber.h src/wasmfx/imports.wat src/wasmfx/wasmfx_impl.c fiber_wasmfx_imports.wasm | bin
	$(WASICC) $(SHADOW_STACK_FLAG) -DWASMFX_CONT_SHADOW_STACK_SIZE=$(WASMFX_CONT_SHADOW_STACK_SIZE) -DWASMFX_CONT_TABLE_INITIAL_CAPACITY=$(WASMFX_CONT_TABLE_INITIAL_CAPACITY) -Wl,--export-table,--export-memory,--export=__stack_pointer src/wasmfx/wasmfx_impl.c $(WASI_FLAGS) $< -o $(@:.wasm=.pre.wasm)
	$(WASM_MERGE) $(WASM_MERGE_FLAGS) fiber_wasmfx_imports.wasm "fiber_wasmfx_imports" $(@:.wasm=.pre.wasm) "main" -o $@
	chmod +x $@

bin/%_wasmfx.wasm: bin/%_wasmfx.unopt.wasm
	$(WASM_OPT) $(WASM_OPT_FLAGS) $< -o $@
	chmod +x $@

bin/%_switch_wasmfx.wasm: %_switch.c inc/fiber_switch.h src/wasmfx/imports_switch.wat src/wasmfx/wasmfx_switch_impl.c fiber_switch_wasmfx_imports.wasm | bin
	$(WASICC) $(SHADOW_STACK_FLAG) -DWASMFX_CONT_SHADOW_STACK_SIZE=$(WASMFX_CONT_SHADOW_STACK_SIZE) -DWASMFX_CONT_TABLE_INITIAL_CAPACITY=$(WASMFX_CONT_TABLE_INITIAL_CAPACITY) -Wl,--export-table,--export-memory,--export=__stack_pointer src/wasmfx/wasmfx_switch_impl.c $(WASI_FLAGS) $< -o $(@:.wasm=.pre.wasm)
	$(WASM_MERGE) $(WASM_MERGE_FLAGS) fiber_switch_wasmfx_imports.wasm "fiber_switch_wasmfx_imports" $(@:.wasm=.pre.wasm) "main" -o $@
	chmod +x $@

bin/%_wasmfx.stripped.wasm: bin/%_wasmfx.wasm
	$(WASM_OPT) $(BINARYEN_FLAGS) --strip $< -o $@

bin/%_asyncify.stripped.wasm: bin/%_asyncify.wasm
	$(WASM_OPT) $(BINARYEN_FLAGS) --strip $< -o $@

bin/pi_asyncify.unopt.wasm: params.h
bin/pi_wasmfx.unopt.wasm: params.h
bin/roundrobin_asyncify.unopt.wasm: params.h
bin/roundrobin_wasmfx.unopt.wasm: params.h

bin/%.cwasm: bin/%.wasm
	$(WASMTIME) compile -W=exceptions,function-references,gc,stack-switching -O opt-level=2 $< -o $@

bin/%_switch.cwasm: bin/%.wasm
	$(WASMTIME) compile -W=exceptions,function-references,gc,stack-switching -O opt-level=2 $< -o $@

src/wasmfx/imports.wat: src/wasmfx/imports.wat.pp
	$(WASICC) -xc $(SHADOW_STACK_FLAG) -DWASMFX_CONT_TABLE_INITIAL_CAPACITY=$(WASMFX_CONT_TABLE_INITIAL_CAPACITY) -E src/wasmfx/imports.wat.pp | sed 's/^#.*//g' > src/wasmfx/imports.wat

src/wasmfx/imports_switch.wat: src/wasmfx/imports_switch.wat.pp
	$(WASICC) -xc $(SHADOW_STACK_FLAG) -DWASMFX_CONT_TABLE_INITIAL_CAPACITY=$(WASMFX_CONT_TABLE_INITIAL_CAPACITY) -E src/wasmfx/imports_switch.wat.pp | sed 's/^#.*//g' > src/wasmfx/imports_switch.wat

%.svg: %.dot
	dot -Tsvg $< > $@

%.callgraph.dot: %.wasm
	$(WASM_OPT) --print-call-graph $< -o $@

bin:
	mkdir -p bin

.PHONY: clean
clean:
	rm -f *.wasm
	rm -f src/wasmfx/imports.wat src/wasmfx/imports_switch.wat
	rm -f *.cwasm
	rm -rf run-scripts bin

treesum_heavy_args.h treesum_heavy_leftcalls.h treesum_heavy_rightcalls.h treesum_heavy_startcalls.h:
	python3 treesum_heavy_generator.py $(TREESUM_HEAVY_WIDTH)

bin/treesum_heavy_asyncify.wasm bin/treesum_heavy_asyncify.wasm: treesum_heavy_args.h treesum_heavy_leftcalls.h treesum_heavy_rightcalls.h treesum_heavy_startcalls.h

tiersum.wat: tiersum.wat.pp
	cpp tiersum.wat.pp | sed '/^#/d' > tiersum.wat

bin/tiersum.wasm: tiersum.wat
	$(ROOT)/stack-switching/interpreter/wasm -d -i tiersum.wat -o bin/tiersum.wasm

bin/treesum_heavy_asyncify.wasm bin/treesum_heavy_wasmfx.wasm: treesum_heavy_args.h treesum_heavy_leftcalls.h treesum_heavy_rightcalls.h treesum_heavy_startcalls.h

treesum_heavy: bin/treesum_heavy_asyncify.wasm bin/treesum_heavy_wasmfx.wasm
