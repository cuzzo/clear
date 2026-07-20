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
  (selector_expression operand: (identifier) @obj field: (field_identifier) @method) @hazard.go_concurrency_waitgroup
  (#match? @obj "^(WaitGroup)$")
)

(
  (selector_expression field: (field_identifier) @method) @hazard.go_concurrency_waitgroup
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
