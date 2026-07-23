package nullable_go_presence_pairs

func typeAssertion(value any) {
	result, ok := value.(*int)
	_, _ = result, ok
}

func channelReceive(values <-chan *int) {
	result, ok := <-values
	_, _ = result, ok
}

func closureWithTwoAssertions() func(any) {
	return func(value any) {
		first, ok := value.(string)
		_, _ = first, ok
		second, ok := value.(int)
		_, _ = second, ok
	}
}
