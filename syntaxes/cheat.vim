" Vim syntax file
" Language: CLEAR
" Filetype: clear
" File extension: .clear
"
" Install for Neovim:
"   ln -s /path/to/cheat/syntaxes/cheat.vim ~/.config/nvim/syntax/clear.vim
" Or for Vim:
"   ln -s /path/to/cheat/syntaxes/cheat.vim ~/.vim/syntax/clear.vim
"
" The buffer must have `set filetype=clear` (the LSP autocmd in
" `src/lsp/README.md` handles this for `.clear` files).

if exists("b:current_syntax")
  finish
endif

" -------------------------------------------------------------------
" Comments — `#` line comments (was `--` historically)
" -------------------------------------------------------------------
syn match clearComment "#.*$"

" -------------------------------------------------------------------
" Control flow
" -------------------------------------------------------------------
syn keyword clearControl IF THEN ELSE ELSE_IF END WHILE DO FOR IN BG NEXT
syn keyword clearControl BREAK CONTINUE RETURN RETURNS
syn keyword clearControl MATCH PARTIAL START DEFAULT WHEN IFF
syn keyword clearControl CATCH EXIT DIE PASS PRUNE RAISE ASSERT
syn keyword clearControl TIGHT YIELD OR_RESCUE ON RETRY

" -------------------------------------------------------------------
" Storage / declarations
" -------------------------------------------------------------------
syn keyword clearStorage FN METHOD MUTABLE STRUCT ENUM UNION STREAM

" -------------------------------------------------------------------
" Ownership / memory operators
" -------------------------------------------------------------------
syn keyword clearMemory GIVE TAKES COPY MOVE SHARE LINK RESOLVE FREEZE CLONE

" -------------------------------------------------------------------
" Pipeline / query operators
" -------------------------------------------------------------------
syn keyword clearPipeline SELECT WHERE UNNEST EACH FIND ANY ALL
syn keyword clearPipeline INDEX SORT ORDER_BY LIMIT SKIP DISTINCT REDUCE
syn keyword clearPipeline COUNT SUM AVERAGE AVG MIN MAX
syn keyword clearPipeline CONCURRENT SHARD JOIN WINDOW
syn keyword clearPipeline TAKE_WHILE TAKEWHILE TAP FOLD COLLECT

" -------------------------------------------------------------------
" Module / FFI / visibility
" -------------------------------------------------------------------
syn keyword clearModule REQUIRE USE PUB PRIVATE EXTERN FROM EFFECTS CLOSE CAPTURES

" -------------------------------------------------------------------
" WITH-block capabilities + lock-cycle escape modifiers
" -------------------------------------------------------------------
syn keyword clearCapKeyword WITH EXCLUSIVE RESTRICT BORROWED VIEW MATERIALIZED
syn keyword clearCapKeyword SNAPSHOT POLYMORPHIC GUARD CAST AS
syn keyword clearCapKeyword POSSIBLE_DEADLOCK POSSIBLE_LOCK_CYCLE

" -------------------------------------------------------------------
" REQUIRES families and reentrance variants
" -------------------------------------------------------------------
syn keyword clearRequires REQUIRES LOCKED VERSIONED ATOMIC LOCAL ACTOR
syn keyword clearRequires NON_REENTRANT REENTRANT SNAPSHOTTED
syn keyword clearRequires MAX_DEPTH NOT_LOGICAL THUNK TAIL_CALL

" -------------------------------------------------------------------
" Predicate / contract clauses
" -------------------------------------------------------------------
syn keyword clearContract PRE DEBUG_POST

" -------------------------------------------------------------------
" SYNC POLICY (top-level concurrency policy)
" -------------------------------------------------------------------
syn keyword clearPolicy SYNC POLICY

" -------------------------------------------------------------------
" Test framework keywords
" -------------------------------------------------------------------
syn keyword clearTestKw TEST THAT BENCH BENCHMARK BEFORE AFTER SETUP
syn keyword clearTestKw LET EXPECT PENDING STUB

" -------------------------------------------------------------------
" Word-shaped operators
" -------------------------------------------------------------------
syn keyword clearWordOp AND OR NOT MOD IS

" -------------------------------------------------------------------
" Boolean / nil literals
" -------------------------------------------------------------------
syn keyword clearBoolean TRUE FALSE NIL

" -------------------------------------------------------------------
" Built-in primitive and stdlib types
" -------------------------------------------------------------------
syn keyword clearType Number Int8 Int16 Int32 Int64 UInt8 UInt16 UInt32 UInt64
syn keyword clearType Float32 Float64 Byte Bool String Void Auto Any
syn keyword clearType HashMap Set List Pool Map Stream Promise Id
syn keyword clearType TCPServer TCPClient File Counter Box

" User-defined types — capitalised identifiers
syn match clearUserType "\<[A-Z][a-zA-Z0-9]*\>"

" -------------------------------------------------------------------
" Capability sigils — @cap with optional :modifier:modifier... chain
" e.g. @shared:locked, @boxed:atomic, @list:soa
" -------------------------------------------------------------------
syn match clearCapability "@\(multiowned\|shared\|locked\|writeLocked\|list\|pool\|set\|map\|sharded\|striped\|local\|indirect\|atomic\|versioned\|observable\|pinned\|arena\|large\|xl\|service\|micro\|standard\|reentrant\|nonReentrant\|canSmash\|parallel\|soa\|split\|raw\|frozen\|alwaysMutable\|link\|thunk\|maxDepth\)\(:[a-zA-Z][a-zA-Z0-9]*\)*"

" -------------------------------------------------------------------
" Pipeline AS-binding alias and string-interpolation prefix
" -------------------------------------------------------------------
syn match clearBinding "\$[a-zA-Z_][a-zA-Z0-9_]*"

" -------------------------------------------------------------------
" Functions (calls and definitions)
" -------------------------------------------------------------------
syn match clearFunction "\w\+[!?]\?" display contained
syn match clearFunctionCall "\w\+[!?]\?(" contains=clearFunction

" -------------------------------------------------------------------
" Sigils and special operators
" -------------------------------------------------------------------
syn match clearPanic "!!"
syn match clearMutationBang "[a-zA-Z0-9_]\@<=!"
syn match clearErrorUnion "[a-zA-Z0-9_!]\@<!!"
syn match clearOptional "?"
syn match clearTense "\~"
syn match clearSigilHeap "%"
syn match clearPipelineOp "|>"
syn match clearArrow "->"
syn match clearRange "\.\.<\|\.\.=\|\.\."
syn match clearCompoundAssign "\(+=\|-=\|\*=\|/=\|\.=\)"
syn match clearComparison "==\|!=\|<=\|>=\|<\|>"
syn match clearPlaceholder "\<_\>"

" -------------------------------------------------------------------
" Numbers (with underscore separators and type suffixes)
" -------------------------------------------------------------------
syn match clearNumber "\<\d[\d_]*\(_\?\(u8\|u16\|u32\|u64\|i8\|i16\|i32\|i64\|f32\|f64\)\)\?\>"
syn match clearFloat  "\<\d[\d_]*\.\d[\d_]*\(_\?\(f32\|f64\)\)\?\>"
syn match clearHex    "\<0x[0-9a-fA-F_]\+\(_\?\(u8\|u16\|u32\|u64\|i8\|i16\|i32\|i64\)\)\?\>"
syn match clearBinary "\<0b[01_]\+\(_\?\(u8\|u16\|u32\|u64\|i8\|i16\|i32\|i64\)\)\?\>"

" -------------------------------------------------------------------
" Strings with ${...} interpolation
" -------------------------------------------------------------------
syn region clearString start='"' end='"' skip='\\"' contains=clearInterpolation,clearEscape
syn match  clearEscape "\\." contained
syn region clearInterpolation start='\${' end='}' contained contains=TOP

" -------------------------------------------------------------------
" Highlight links to standard groups
" -------------------------------------------------------------------
hi def link clearControl       Conditional
hi def link clearStorage       StorageClass
hi def link clearMemory        Exception
hi def link clearPipeline      Keyword
hi def link clearModule        Include
hi def link clearCapKeyword    Keyword
hi def link clearRequires      Keyword
hi def link clearContract      PreProc
hi def link clearPolicy        Keyword
hi def link clearTestKw        Macro
hi def link clearWordOp        Operator
hi def link clearBoolean       Boolean
hi def link clearType          Type
hi def link clearUserType      Type
hi def link clearComment       Comment
hi def link clearString        String
hi def link clearEscape        SpecialChar
hi def link clearInterpolation Special
hi def link clearNumber        Number
hi def link clearFloat         Float
hi def link clearHex           Number
hi def link clearBinary        Number
hi def link clearCapability    StorageClass
hi def link clearBinding       Identifier
hi def link clearPanic         Error
hi def link clearMutationBang  Special
hi def link clearErrorUnion    Special
hi def link clearOptional      Special
hi def link clearTense         Special
hi def link clearSigilHeap     Special
hi def link clearPipelineOp    Operator
hi def link clearArrow         Operator
hi def link clearRange         Operator
hi def link clearCompoundAssign Operator
hi def link clearComparison    Operator
hi def link clearPlaceholder   Special
hi def link clearFunction      Function

let b:current_syntax = "clear"
