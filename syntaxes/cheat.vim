" Vim syntax file
" Language: CHEAT
" Maintainer: You
" Latest Revision: 17 December 2025

if exists("b:current_syntax")
  finish
endif

" Keywords
syn keyword cheatControl IF THEN ELSE ELSE_IF END MATCH START WHEN WHILE DO FOR BREAK CONTINUE RETURN OR PASS CATCH PARALLEL ASYNC SYNC COLLECT STRUCT USE
syn keyword cheatStorage VAR MUTABLE SET FN
syn keyword cheatMemory GIVE TAKES COPY FREE
syn keyword cheatSQL SELECT WHERE UNNEST EACH INDEX SORT
syn keyword cheatBoolean TRUE FALSE
syn keyword cheatType Number UInt8 UInt16 UInt32 UInt64 Int8 Int16 Int32 Int64 Float32 Float64 Bool String Stream

" Matches
syn match cheatComment "--.*$"
syn match cheatIdentifier "[a-zA-Z_][a-zA-Z0-9_]*"

" Functions (including mutation suffix)
syn match cheatFunction "\w\+!\?" display contained
syn match cheatFunctionCall "\w\+!\?("he=e-1 contains=cheatFunction

" Sigils and Special Operators
syn match cheatSigilHeap "%"
syn match cheatSigilAtomic "\^"
syn match cheatSigilBorrow "&"
syn match cheatBind "@\w\+"
syn match cheatPanic "!!"
syn match cheatMutate "!"
syn match cheatPipeline "s>"
syn match cheatForce "|>"
syn match cheatArrow "->"
syn match cheatRange "\.\.<\|\.\.=\|\.\."
syn match cheatPlaceholder "\<_\>"

" Numbers
syn match cheatNumber "\<\d\+\(u8\|u16\|u32\|u64\|i8\|i16\|i32\|i64\)\?\>"
syn match cheatFloat "\<\d\+\.\d\+\(f32\|f64\)\?\>"
syn match cheatHex "\<0x[0-9a-fA-F]\+\>"
syn match cheatOctal "\<0o[0-7]\+\>"
syn match cheatBinary "\<0b[01]\+\>"

" Strings
syn region cheatString start='"' end='"' skip='\\"'

" Highlighting Links
hi def link cheatControl Conditional
hi def link cheatStorage StorageClass
hi def link cheatMemory Exception
hi def link cheatSQL Keyword
hi def link cheatBoolean Boolean
hi def link cheatType Type
hi def link cheatComment Comment
hi def link cheatString String
hi def link cheatNumber Number
hi def link cheatFloat Float
hi def link cheatHex Number
hi def link cheatOctal Number
hi def link cheatBinary Number

" Special Highlighting for Sigils to enforce 'Explicit over Implicit'
hi def link cheatSigilHeap Special
hi def link cheatSigilAtomic Special
hi def link cheatSigilBorrow Special
hi def link cheatBind Identifier
hi def link cheatPanic Error
hi def link cheatPipeline Operator
hi def link cheatArrow Operator
hi def link cheatRange Operator
hi def link cheatPlaceholder Special

" Function names
hi def link cheatFunction Function

let b:current_syntax = "cheat"
