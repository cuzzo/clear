package main

func run(fn func() error) error {
	return fn()
}
