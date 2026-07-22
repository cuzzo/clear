package nullable_operations

func dereferenceNil() int {
	var value *int
	value = nil
	return *value
}
