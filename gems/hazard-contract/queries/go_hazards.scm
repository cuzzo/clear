(go_statement) @hazard.go_race_goroutine

(
  (selector_expression operand: (identifier) @obj) @hazard.go_race_atomic
  (#eq? @obj "atomic")
)

(
  (selector_expression operand: (identifier) @obj field: (field_identifier) @method) @hazard.go_race_lock
  (#match? @obj "^(sync|Mutex|RWMutex|Map|Once|Cond)$")
)

(
  (selector_expression field: (field_identifier) @method) @hazard.go_race_lock
  (#match? @method "^(Lock|Unlock|RLock|RUnlock)$")
)

(
  (selector_expression operand: _ @obj field: (field_identifier) @method) @hazard.go_concurrency_waitgroup
  (#match? @obj "(?i)(wg|wait|group)")
  (#match? @method "^(Add|Done|Wait)$")
)

;; Refined Go Channel check to only target channel creation
(
  (call_expression
    function: (identifier) @func
    arguments: (argument_list (channel_type))) @hazard.go_concurrency_channel
  (#eq? @func "make")
)

(select_statement) @hazard.go_concurrency_channel
(send_statement) @hazard.go_concurrency_channel

(
  (unary_expression operator: _ @op) @hazard.go_concurrency_channel
  (#eq? @op "<-")
)

;; Reflection is a hazard only when the receiver is the reflect package (or
;; a value returned by it), rather than every method named Call or Method.
(
  (call_expression
    function: (selector_expression
      operand: (identifier) @pkg
      field: (field_identifier) @constructor)) @hazard.go_reflection
  (#eq? @pkg "reflect")
  (#match? @constructor "^(ValueOf|TypeOf|New|PtrTo|SliceOf)$")
)

(
  (call_expression
    function: (selector_expression
      operand: (call_expression
        function: (selector_expression
          operand: (identifier) @pkg
          field: (field_identifier) @constructor))
      field: (field_identifier) @method)) @hazard.go_reflection
  (#eq? @pkg "reflect")
  (#eq? @constructor "ValueOf")
  (#match? @method "^(MethodByName|FieldByName|FieldByIndex|Call)$")
)
