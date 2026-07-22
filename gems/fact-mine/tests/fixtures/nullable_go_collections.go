package nullable_go_collections

func writeMap(values map[string]int) {
	values = nil
	values["key"] = 1
}

func sendChannel(values chan int) {
	values = nil
	values <- 1
}

func closeChannel(values chan int) {
	values = nil
	close(values)
}
