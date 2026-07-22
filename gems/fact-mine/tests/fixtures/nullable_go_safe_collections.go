package nullable_go_safe_collections

func safeCollections() {
	var values map[string]*int
	_ = values["key"]
	for _, value := range values {
		_ = value
	}

	var items []int
	items = append(items, 1)
	for _, item := range items {
		_ = item
	}
}
