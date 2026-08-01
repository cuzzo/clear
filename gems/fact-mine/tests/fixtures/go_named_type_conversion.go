package conv

type ByteCode byte

func classify(b byte) ByteCode {
	return ByteCode(b)
}

func classifyAll(bs []byte) ByteCode {
	return classify(bs[0])
}
