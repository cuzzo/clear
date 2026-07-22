(
  (navigation_expression
    _
    (identifier) @name
  )
  (#match? @name "^(forName|getMethod|getDeclaredMethod|getField|getDeclaredField|memberProperties|memberFunctions|declaredMemberProperties|declaredMemberFunctions)$")
) @hazard.kotlin_metaprogramming

;; call/callBy are generic method names; require a reflection-shaped receiver
;; so ordinary invocations like service.call() are not flagged.
(
  (navigation_expression
    _ @recv
    (identifier) @name
  )
  (#match? @name "^(call|callBy)$")
  (#match? @recv "(?i)(method|function|callable|member|property|constructor|kclass|reflect)")
) @hazard.kotlin_metaprogramming

(
  (call_expression
    (identifier) @name
  )
  (#match? @name "^(forName|getMethod|getDeclaredMethod|getField|getDeclaredField)$")
) @hazard.kotlin_metaprogramming
