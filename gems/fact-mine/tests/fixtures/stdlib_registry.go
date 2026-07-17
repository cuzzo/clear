package registry

import (
  "maps"
  "slices"
  "strings"
)

func inspect(text string, values []int, labels map[string]int) bool {
  _, _ = slices.BinarySearch(values, 1)
  _ = maps.Clone(labels)
  return strings.HasPrefix(text, "x")
}
