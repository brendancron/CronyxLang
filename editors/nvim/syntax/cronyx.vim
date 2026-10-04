if exists('b:current_syntax')
  finish
endif

syn keyword cronyxConditional if else match
syn keyword cronyxRepeat      for while in
syn keyword cronyxStatement   return break continue defer
syn keyword cronyxKeyword     fn var type trait impl derive with
syn keyword cronyxEffect      effect ctl final handle handler resume discontinue run
syn keyword cronyxMeta        meta gen code typeof
syn keyword cronyxInclude     import from as
syn match   cronyxInclude     "\<global\ze\s\+import\>"
syn keyword cronyxBoolean     true false
syn keyword cronyxType        int float bool string char byte unit never any
syn keyword cronyxSelf        self Self

syn match cronyxFuncCall  "\<\h\w*\ze\s*("
syn match cronyxFuncDecl  "\%(\<\%(fn\|ctl\)\s\+\)\@<=\h\w*"
syn match cronyxTypeName  "\<\u\w*\>"
syn match cronyxAttribute "@\h\w*"

syn match cronyxNumber "\<\d\+\>"
syn match cronyxNumber "\<0[xX]\x\+\>"
syn match cronyxNumber "\<0[bB][01]\+\>"
syn match cronyxFloat  "\<\d\+\.\d\+\>"

syn match  cronyxEscape    contained "\\[ntr0\\\"']"
syn match  cronyxBadEscape contained "\\[^ntr0\\\"']"
syn region cronyxString start=+"+ skip=+\\.+ end=+"+ contains=cronyxEscape,cronyxBadEscape,@Spell
syn match  cronyxChar   "'\%(\\[ntr0\\\"']\|[^\\']\)'" contains=cronyxEscape

syn match cronyxOperator "[-+*/%=!<>&|^~]\+"
syn match cronyxOperator "\.\.\."

syn keyword cronyxTodo contained TODO FIXME XXX NOTE
syn region  cronyxLineComment  start="//" end="$" contains=cronyxTodo,@Spell
" Block comments nest, so commenting out a region that holds one still works.
syn region  cronyxBlockComment matchgroup=cronyxBlockComment start="/\*" end="\*/" contains=cronyxBlockComment,cronyxTodo,@Spell fold
syn region  cronyxDocComment   matchgroup=cronyxDocComment start="/\*\*\%([*/]\)\@!" end="\*/" contains=cronyxBlockComment,cronyxTodo,@Spell fold

syn region cronyxBlock start="{" end="}" transparent fold

hi def link cronyxConditional  Conditional
hi def link cronyxRepeat       Repeat
hi def link cronyxStatement    Statement
hi def link cronyxKeyword      Keyword
hi def link cronyxEffect       Keyword
hi def link cronyxMeta         PreProc
hi def link cronyxInclude      Include
hi def link cronyxBoolean      Boolean
hi def link cronyxType         Type
hi def link cronyxSelf         Special
hi def link cronyxTypeName     Type
hi def link cronyxFuncDecl     Function
hi def link cronyxFuncCall     Function
hi def link cronyxAttribute    PreProc
hi def link cronyxNumber       Number
hi def link cronyxFloat        Float
hi def link cronyxEscape       SpecialChar
hi def link cronyxBadEscape    Error
hi def link cronyxString       String
hi def link cronyxChar         Character
hi def link cronyxOperator     Operator
hi def link cronyxTodo         Todo
hi def link cronyxLineComment  Comment
hi def link cronyxBlockComment Comment
hi def link cronyxDocComment   SpecialComment

let b:current_syntax = 'cronyx'
