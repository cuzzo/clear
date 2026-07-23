package nullable_go_operations

type record struct {
	field int
}

func selectNil(value *record) int {
	value = nil
	return value.field
}

func callNil(callback func()) {
	callback = nil
	callback()
}
