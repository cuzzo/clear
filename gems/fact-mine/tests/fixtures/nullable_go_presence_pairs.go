package nullable_go_presence_pairs

func typeAssertion(value any) {
	result, ok := value.(*int)
	_, _ = result, ok
}

func channelReceive(values <-chan *int) {
	result, ok := <-values
	_, _ = result, ok
}
