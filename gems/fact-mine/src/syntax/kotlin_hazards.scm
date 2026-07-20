(
  (navigation_expression
    _
    (identifier) @name
  )
  (#match? @name "^(forName|getMethod|getDeclaredMethod|getField|getDeclaredField|call|callBy|memberProperties|memberFunctions|declaredMemberProperties|declaredMemberFunctions)$")
) @hazard.kotlin_metaprogramming

(
  (call_expression
    (identifier) @name
  )
  (#match? @name "^(forName|getMethod|getDeclaredMethod|getField|getDeclaredField|call|callBy)$")
) @hazard.kotlin_metaprogramming
