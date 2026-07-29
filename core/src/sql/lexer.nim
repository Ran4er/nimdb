## lexer.nim — SQL tokeniser

import std/[strutils, unicode]
import ../storage/types

type
  TokKind* = enum
    tkEof, tkError,
    # Literals
    tkInt, tkFloat, tkString, tkIdent,
    # Punctuation
    tkLParen, tkRParen, tkComma, tkSemicolon, tkDot,
    tkStar, tkSlash, tkPercent, tkPlus, tkMinus,
    tkEq, tkNe, tkLt, tkLe, tkGt, tkGe,
    tkLShift, tkRShift,
    # Keywords (all uppercased)
    tkSELECT, tkFROM, tkWHERE, tkAND, tkOR, tkNOT,
    tkINSERT, tkINTO, tkVALUES,
    tkUPDATE, tkSET,
    tkDELETE,
    tkCREATE, tkTABLE, tkINDEX, tkDROP,
    tkIF, tkEXISTS,
    tkPRIMARY, tkKEY, tkUNIQUE, tkNOT_NULL,
    tkJOIN, tkINNER, tkLEFT, tkRIGHT, tkFULL, tkON, tkCROSS,
    tkORDER, tkBY, tkASC, tkDESC, tkLIMIT, tkOFFSET,
    tkGROUP, tkHAVING, tkDISTINCT,
    tkAS, tkIN, tkLIKE, tkIS, tkNULL, tkBETWEEN,
    tkBEGIN, tkCOMMIT, tkROLLBACK, tkTRANSACTION,
    tkEXPLAIN, tkTRUE, tkFALSE,
    tkCAST,
    # Types used inline
    tkINT, tkBIGINT, tkFLOAT, tkTEXT, tkBOOL, tkBYTES, tkVARCHAR

  Token* = object
    kind*:  TokKind
    raw*:   string
    line*:  int
    col*:   int

const keywords: array[_, (string, TokKind)] = [
  ("SELECT",      tkSELECT),   ("FROM",     tkFROM),
  ("WHERE",       tkWHERE),    ("AND",      tkAND),
  ("OR",          tkOR),       ("NOT",      tkNOT),
  ("INSERT",      tkINSERT),   ("INTO",     tkINTO),
  ("VALUES",      tkVALUES),   ("UPDATE",   tkUPDATE),
  ("SET",         tkSET),      ("DELETE",   tkDELETE),
  ("CREATE",      tkCREATE),   ("TABLE",    tkTABLE),
  ("INDEX",       tkINDEX),    ("DROP",     tkDROP),
  ("IF",          tkIF),       ("EXISTS",   tkEXISTS),
  ("PRIMARY",     tkPRIMARY),  ("KEY",      tkKEY),
  ("UNIQUE",      tkUNIQUE),   ("JOIN",     tkJOIN),
  ("INNER",       tkINNER),    ("LEFT",     tkLEFT),
  ("RIGHT",       tkRIGHT),    ("FULL",     tkFULL),
  ("CROSS",       tkCROSS),    ("ON",       tkON),
  ("ORDER",       tkORDER),    ("BY",       tkBY),
  ("ASC",         tkASC),      ("DESC",     tkDESC),
  ("LIMIT",       tkLIMIT),    ("OFFSET",   tkOFFSET),
  ("GROUP",       tkGROUP),    ("HAVING",   tkHAVING),
  ("DISTINCT",    tkDISTINCT), ("AS",       tkAS),
  ("IN",          tkIN),       ("LIKE",     tkLIKE),
  ("IS",          tkIS),       ("NULL",     tkNULL),
  ("BETWEEN",     tkBETWEEN),  ("BEGIN",    tkBEGIN),
  ("COMMIT",      tkCOMMIT),   ("ROLLBACK", tkROLLBACK),
  ("TRANSACTION", tkTRANSACTION), ("EXPLAIN", tkEXPLAIN),
  ("TRUE",        tkTRUE),     ("FALSE",    tkFALSE),
  ("CAST",        tkCAST),
  ("INT",         tkINT),      ("INTEGER",  tkINT),
  ("BIGINT",      tkBIGINT),   ("INT8",     tkBIGINT),
  ("INT4",        tkINT),      ("FLOAT",    tkFLOAT),
  ("FLOAT8",      tkFLOAT),    ("REAL",     tkFLOAT),
  ("DOUBLE",      tkFLOAT),    ("TEXT",     tkTEXT),
  ("VARCHAR",     tkVARCHAR),  ("BOOL",     tkBOOL),
  ("BOOLEAN",     tkBOOL),     ("BYTES",    tkBYTES),
  ("BYTEA",       tkBYTES),
]

type Lexer* = object
  src*:  string
  pos*:  int
  line*: int
  col*:  int

proc newLexer*(src: string): Lexer =
  Lexer(src: src, pos: 0, line: 1, col: 1)

proc peek(lex: Lexer): char {.inline.} =
  if lex.pos < lex.src.len: lex.src[lex.pos] else: '\0'

proc advance(lex: var Lexer): char =
  result = lex.src[lex.pos]
  inc lex.pos
  if result == '\n': inc lex.line; lex.col = 1
  else: inc lex.col

proc skipWhitespace(lex: var Lexer) =
  while lex.pos < lex.src.len:
    let c = lex.peek()
    if c in {' ', '\t', '\r', '\n'}:
      discard lex.advance()
    elif c == '-' and lex.pos+1 < lex.src.len and lex.src[lex.pos+1] == '-':
      # line comment
      while lex.pos < lex.src.len and lex.peek() != '\n':
        discard lex.advance()
    elif c == '/' and lex.pos+1 < lex.src.len and lex.src[lex.pos+1] == '*':
      # block comment
      discard lex.advance(); discard lex.advance()
      while lex.pos+1 < lex.src.len:
        if lex.advance() == '*' and lex.peek() == '/':
          discard lex.advance(); break
    else:
      break

proc nextToken*(lex: var Lexer): Token =
  lex.skipWhitespace()
  if lex.pos >= lex.src.len:
    return Token(kind: tkEof, line: lex.line, col: lex.col)

  let line = lex.line
  let col  = lex.col
  let c    = lex.advance()

  template tok(k: TokKind; r: string = ""): Token =
    Token(kind: k, raw: (if r.len > 0: r else: $c), line: line, col: col)

  case c
  of '(': return tok(tkLParen)
  of ')': return tok(tkRParen)
  of ',': return tok(tkComma)
  of ';': return tok(tkSemicolon)
  of '.': return tok(tkDot)
  of '*': return tok(tkStar)
  of '/': return tok(tkSlash)
  of '%': return tok(tkPercent)
  of '+': return tok(tkPlus)
  of '-': return tok(tkMinus)
  of '=': return tok(tkEq)
  of '!':
    if lex.peek() == '=': discard lex.advance(); return tok(tkNe, "!=")
    return tok(tkError, "!")
  of '<':
    if lex.peek() == '=': discard lex.advance(); return tok(tkLe, "<=")
    if lex.peek() == '>': discard lex.advance(); return tok(tkNe, "<>")
    return tok(tkLt)
  of '>':
    if lex.peek() == '=': discard lex.advance(); return tok(tkGe, ">=")
    return tok(tkGt)
  of '\'':
    var s = ""
    while lex.pos < lex.src.len:
      let ch = lex.advance()
      if ch == '\'':
        if lex.peek() == '\'': s.add('\''); discard lex.advance()  # escaped ''
        else: break
      else: s.add(ch)
    return Token(kind: tkString, raw: s, line: line, col: col)
  of '"':
    var s = ""
    while lex.pos < lex.src.len:
      let ch = lex.advance()
      if ch == '"': break
      s.add(ch)
    return Token(kind: tkIdent, raw: s, line: line, col: col)
  else:
    if c.isDigit():
      var s = $c
      var isFloat = false
      while lex.pos < lex.src.len and (lex.peek().isDigit() or lex.peek() == '.'):
        let ch = lex.advance()
        if ch == '.': isFloat = true
        s.add(ch)
      if isFloat:
        # handle scientific notation
        if lex.pos < lex.src.len and lex.peek() in {'e', 'E'}:
          s.add(lex.advance())
          if lex.pos < lex.src.len and lex.peek() in {'+', '-'}:
            s.add(lex.advance())
          while lex.pos < lex.src.len and lex.peek().isDigit():
            s.add(lex.advance())
        return Token(kind: tkFloat, raw: s, line: line, col: col)
      return Token(kind: tkInt, raw: s, line: line, col: col)

    elif c.isAlphaAscii() or c == '_':
      var s = $c
      while lex.pos < lex.src.len and (lex.peek().isAlphaNumeric() or lex.peek() == '_'):
        s.add(lex.advance())
      let up = s.toUpperAscii()
      for (kw, kt) in keywords:
        if kw == up:
          return Token(kind: kt, raw: s, line: line, col: col)
      return Token(kind: tkIdent, raw: s, line: line, col: col)

    return tok(tkError, $c)

proc tokenize*(src: string): seq[Token] =
  var lex = newLexer(src)
  while true:
    let t = lex.nextToken()
    result.add(t)
    if t.kind == tkEof: break
