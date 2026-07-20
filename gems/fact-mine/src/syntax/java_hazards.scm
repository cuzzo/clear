(method_invocation
  name: (identifier) @name
  (#match? @name "^(forName|loadClass|getMethod|getDeclaredMethod|getField|getDeclaredField|getConstructor|getDeclaredConstructor|newInstance|newProxyInstance|invoke)$")) @hazard.java_metaprogramming
