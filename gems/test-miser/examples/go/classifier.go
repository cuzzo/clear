package classifier

func Classify(value int) string {
	if value > 10 {
		return "high"
	}
	if value > 0 {
		return "positive"
	}
	return "nonpositive"
}
