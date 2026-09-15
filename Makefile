.PHONY: build run

build:
	./bench build

run: build
	./bench run $(ARGS)
