using System.Collections.Generic;
using System.Linq;

class TypedCollections {
  string[] CopyIfPresent(List<string> values, string needle) {
    if (values.Contains(needle)) {
      return values.ToArray();
    }
    return new string[0];
  }
}
