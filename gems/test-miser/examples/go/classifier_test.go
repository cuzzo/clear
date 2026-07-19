package classifier

import "testing"

func TestPositivePrimary(t *testing.T) {
	if got := Classify(5); got != "positive" {
		t.Fatalf("got %q", got)
	}
}

func TestPositiveDuplicate(t *testing.T) {
	if got := Classify(5); got != "positive" {
		t.Fatalf("got %q", got)
	}
}

func TestHigh(t *testing.T) {
	if got := Classify(11); got != "high" {
		t.Fatalf("got %q", got)
	}
}

func TestNonpositive(t *testing.T) {
	if got := Classify(0); got != "nonpositive" {
		t.Fatalf("got %q", got)
	}
}

func TestSmoke(t *testing.T) {
	if true != true {
		t.Fatal("unreachable")
	}
}
