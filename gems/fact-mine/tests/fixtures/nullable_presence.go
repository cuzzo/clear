package nullable_presence

func lookup(values map[string]*int, key string) *int {
	value, ok := values[key]
	if !ok {
		return nil
	}
	return value
}
