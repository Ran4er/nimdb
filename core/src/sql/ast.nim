## ast.nim — SQL Abstract Syntax Tree nodes

import ../catalog/schema

type
  # ─── Expressions ──────────────────────────────────────────────────────
  ExprKind* = enum
    ekLit, ekCol, ekBinOp, ekUnOp, ekStar, ekFunc, ekCast

  BinOp* = enum
    boAdd, boSub, boMul, boDiv, boMod,
    boEq, boNe, boLt, boLe, boGt, boGe,
    boAnd, boOr, boLike, boIs, boIsNot, boIn

  UnOp* = enum
    uoNeg, uoNot, uoIsNull, uoIsNotNull

  Expr* = ref object
    case kind*: ExprKind
    of ekLit:
      lit*: Value
    of ekCol:
      table*: string   ## may be empty (no qualifier)
      col*:   string
    of ekBinOp:
      op*:    BinOp
      left*:  Expr
      right*: Expr
    of ekUnOp:
      uop*:   UnOp
      operand*: Expr
    of ekStar:
      discard
    of ekFunc:
      fname*:  string
      fargs*:  seq[Expr]
    of ekCast:
      castExpr*: Expr
      castTo*:   ColKind

  # ─── Statements ───────────────────────────────────────────────────────
  StmtKind* = enum
    skSelect, skInsert, skUpdate, skDelete,
    skCreateTable, skDropTable, skCreateIndex, skBegin,
    skCommit, skRollback, skExplain

  OrderDir* = enum
    odAsc, odDesc

  OrderBy* = object
    expr*: Expr
    dir*:  OrderDir

  SelectItem* = object
    expr*:  Expr
    alias*: string   ## may be empty

  JoinKind* = enum
    jkInner, jkLeft, jkRight, jkFull, jkCross

  JoinClause* = object
    kind*:   JoinKind
    table*:  string
    alias*:  string
    on*:     Expr    ## may be nil for CROSS JOIN

  Stmt* = ref object
    case kind*: StmtKind
    of skSelect:
      selItems*:   seq[SelectItem]
      fromTable*:  string
      fromAlias*:  string
      joins*:      seq[JoinClause]
      whereExpr*:  Expr        ## may be nil
      groupBy*:    seq[Expr]
      having*:     Expr        ## may be nil
      orderBy*:    seq[OrderBy]
      limitVal*:   int         ## -1 = no limit
      offsetVal*:  int         ## 0 = no offset
      distinct*:   bool

    of skInsert:
      insTable*:   string
      insCols*:    seq[string]
      insVals*:    seq[seq[Expr]]   ## multiple row values

    of skUpdate:
      updTable*:   string
      updSets*:    seq[(string, Expr)]
      updWhere*:   Expr

    of skDelete:
      delTable*:   string
      delWhere*:   Expr

    of skCreateTable:
      ctName*:     string
      ctCols*:     seq[ColDef]
      ctIfNotExists*: bool

    of skDropTable:
      dtName*:     string
      dtIfExists*: bool

    of skCreateIndex:
      ciName*:     string
      ciTable*:    string
      ciCol*:      string
      ciUnique*:   bool

    of skBegin, skCommit, skRollback:
      discard

    of skExplain:
      explainStmt*: Stmt
