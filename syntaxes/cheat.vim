" Vim syntax file
" Language: CLEAR
" Maintainer: CLEAR Language Team
" Latest Revision: 31 March 2026

if exists("b:current_syntax")
  finish
endif

" Control flow
syn keyword clearControl IF THEN ELSE ELSE_IF END WHILE DO FOR IN BG NEXT
syn keyword clearControl BREAK CONTINUE RETURN RETURNS
syn keyword clearControl MATCH START DEFAULT WHEN IFF
syn keyword clearControl CATCH EXIT DIE PASS PRUNE RAISE ASSERT
syn keyword clearControl TIGHT YIELD

" Storage and declarations
syn keyword clearStorage FN MUTABLE STRUCT ENUM UNION STREAM

" Ownership and memory
syn keyword clearMemory GIVE TAKES COPY MOVE

" Pipeline / query operators
syn keyword clearPipeline SELECT WHERE UNNEST EACH FIND ANY ALL
syn keyword clearPipeline INDEX SORT ORDER_BY LIMIT DISTINCT REDUCE
syn keyword clearPipeline COUNT SUM AVERAGE MIN MAX CONCURRENT SHARD

" Module system and FFI
syn keyword clearModule REQUIRE USE PUB PRIVATE EXTERN FROM EFFECTS CLOSE

" Other keywords
syn keyword clearOther WITH EXCLUSIVE RESTRICT CAST AS MOD OR

" Boolean and nil literals
syn keyword clearBoolean TRUE FALSE NIL

" Built-in types
syn keyword clearType Number Int64 Float64 Byte Bool String Void
syn keyword clearType HashMap Id TCPServer TCPClient File

" User-defined types (capitalized identifiers)
syn match clearUserType "\<[A-Z][a-zA-Z0-9]*\>"

" Comments
syn match clearComment "--.*$"

" Functions (including mutation/predicate suffix)
syn match clearFunction "\w\+[!?]\?" display contained
syn match clearFunctionCall "\w\+[!?]\?("he=e-1 contains=clearFunction

" Capability annotations
syn match clearCapability "@\(multiowned\|shared\|locked\|writeLocked\|list\|pool\|set\|sharded\|local\|indirect\|pinned\|arena\|large\|xl\|service\|micro\|standard\)"

" Sigils and special operators
syn match clearSigilHeap "%"
syn match clearSigilBorrow "&"
syn match clearPanic "!!"
syn match clearPipelineOp "s>"
syn match clearArrow "->"
syn match clearRange "\.\.<\|\.\.=\|\.\."
syn match clearTense "\~"
syn match clearPlaceholder "\<_\>"
syn match clearCompoundAssign "\(+=\|-=\|\*=\|/=\)"

" Numbers (with underscore separators and type suffixes)
syn match clearNumber "\<\d[\d_]*\(_i64\|_f64\|u8\|u16\|u32\|u64\|i8\|i16\|i32\|i64\)\?\>"
syn match clearFloat "\<\d[\d_]*\.\d[\d_]*\(f32\|f64\)\?\>"
syn match clearHex "\<0x[0-9a-fA-F_]\+\>"
syn match clearBinary "\<0b[01_]\+\>"

" Strings with interpolation
syn region clearString start='"' end='"' skip='\\"' contains=clearInterpolation,clearEscape
syn match clearEscape "\\." contained
syn region clearInterpolation start='\${' end='}' contained contains=TOP

" Highlighting links
hi def link clearControl Conditional
hi def link clearStorage StorageClass
hi def link clearMemory Exception
hi def link clearPipeline Keyword
hi def link clearModule Include
hi def link clearOther Keyword
hi def link clearBoolean Boolean
hi def link clearType Type
hi def link clearUserType Type
hi def link clearComment Comment
hi def link clearString String
hi def link clearEscape SpecialChar
hi def link clearInterpolation Special
hi def link clearNumber Number
hi def link clearFloat Float
hi def link clearHex Number
hi def link clearBinary Number
hi def link clearCapability StorageClass
hi def link clearSigilHeap Special
hi def link clearSigilBorrow Special
hi def link clearPanic Error
hi def link clearPipelineOp Operator
hi def link clearArrow Operator
hi def link clearRange Operator
hi def link clearTense Special
hi def link clearPlaceholder Special
hi def link clearCompoundAssign Operator
hi def link clearFunction Function

let b:current_syntax = "clear"
