## btree.nim — In-memory B+ Tree index
##
## Leaf nodes hold (key → seq[TupleId]) for non-unique indexes.
## Inner nodes hold separator keys and child pointers.
## Order B = 64 → max 128 keys per node before split.

import std/[algorithm, sequtils]
import ../storage/types
import ../catalog/schema
import ../storage/heap_file

const B* = 64   ## B+ tree order

type
  NodeKind* = enum
    nkLeaf, nkInner

  TupleId* = object
    pageId*: PageId
    slotId*: uint16

  BTreeNode* = ref object
    case kind*: NodeKind
    of nkLeaf:
      keys*:   seq[Value]
      tids*:   seq[seq[TupleId]]  ## parallel to keys (multi-value)
      next*:   BTreeNode           ## right sibling (leaf chain)
    of nkInner:
      keys*:   seq[Value]          ## len = children.len - 1
      children*: seq[BTreeNode]

  BTree* = ref object
    root*:   BTreeNode
    unique*: bool
    colIdx*: int

# ─── BTree creation ───────────────────────────────────────────────────────

proc newBTree*(colIdx: int; unique = false): BTree =
  BTree(
    root:   BTreeNode(kind: nkLeaf, keys: @[], tids: @[], next: nil),
    unique: unique,
    colIdx: colIdx
  )

# ─── Search ───────────────────────────────────────────────────────────────

proc findLeaf(node: BTreeNode; key: Value): BTreeNode =
  ## Traverse from root to the leaf that could contain key.
  var n = node
  while n.kind == nkInner:
    var i = 0
    while i < n.keys.len and n.keys[i] <= key: inc i
    n = n.children[i]
  n

proc search*(bt: BTree; key: Value): seq[TupleId] =
  let leaf = findLeaf(bt.root, key)
  let idx  = leaf.keys.lowerBound(key, proc(a, b: Value): int =
    if a < b: -1 elif a == b: 0 else: 1)
  if idx < leaf.keys.len and leaf.keys[idx] == key:
    leaf.tids[idx]
  else:
    @[]

proc rangeSearch*(bt: BTree; lo, hi: Value; inclusive = true): seq[TupleId] =
  ## Return all TupleIds where lo <= key <= hi.
  var leaf = findLeaf(bt.root, lo)
  while not leaf.isNil:
    for i, k in leaf.keys:
      if k < lo: continue
      if inclusive and k > hi: return
      if not inclusive and k >= hi: return
      result.add(leaf.tids[i])
    leaf = leaf.next

# ─── Insert helpers ───────────────────────────────────────────────────────

type SplitResult = object
  promotedKey: Value
  right:       BTreeNode

proc splitLeaf(leaf: BTreeNode): SplitResult =
  let mid = leaf.keys.len div 2
  let right = BTreeNode(kind: nkLeaf,
    keys: leaf.keys[mid..^1],
    tids: leaf.tids[mid..^1],
    next: leaf.next)
  leaf.keys.setLen(mid)
  leaf.tids.setLen(mid)
  leaf.next = right
  SplitResult(promotedKey: right.keys[0], right: right)

proc splitInner(node: BTreeNode): SplitResult =
  let mid   = node.keys.len div 2
  let pkey  = node.keys[mid]
  let right = BTreeNode(kind: nkInner,
    keys:     node.keys[mid+1..^1],
    children: node.children[mid+1..^1])
  node.keys.setLen(mid)
  node.children.setLen(mid+1)
  SplitResult(promotedKey: pkey, right: right)

proc insertIntoLeaf(leaf: BTreeNode; key: Value; tid: TupleId; unique: bool) =
  let idx = leaf.keys.lowerBound(key, proc(a, b: Value): int =
    if a < b: -1 elif a == b: 0 else: 1)
  if idx < leaf.keys.len and leaf.keys[idx] == key:
    if unique:
      raise newException(StorageError, "Unique constraint violation")
    leaf.tids[idx].add(tid)
  else:
    leaf.keys.insert(key, idx)
    leaf.tids.insert(@[tid], idx)

proc insertRec(node: BTreeNode; key: Value; tid: TupleId;
               unique: bool): Option[SplitResult] =
  if node.kind == nkLeaf:
    insertIntoLeaf(node, key, tid, unique)
    if node.keys.len > 2 * B:
      return some(splitLeaf(node))
    return none(SplitResult)
  else:
    var i = 0
    while i < node.keys.len and node.keys[i] <= key: inc i
    let child = node.children[i]
    let res   = insertRec(child, key, tid, unique)
    if res.isSome:
      let sr = res.get()
      node.keys.insert(sr.promotedKey, i)
      node.children.insert(sr.right, i + 1)
      if node.keys.len > 2 * B:
        return some(splitInner(node))
    return none(SplitResult)

import std/options

proc insert*(bt: BTree; key: Value; tid: TupleId) =
  let res = insertRec(bt.root, key, tid, bt.unique)
  if res.isSome:
    let sr = res.get()
    let newRoot = BTreeNode(kind: nkInner,
      keys:     @[sr.promotedKey],
      children: @[bt.root, sr.right])
    bt.root = newRoot

# ─── Delete ───────────────────────────────────────────────────────────────

proc delete*(bt: BTree; key: Value; tid: TupleId) =
  let leaf = findLeaf(bt.root, key)
  let idx  = leaf.keys.lowerBound(key, proc(a, b: Value): int =
    if a < b: -1 elif a == b: 0 else: 1)
  if idx >= leaf.keys.len or leaf.keys[idx] != key: return
  leaf.tids[idx] = leaf.tids[idx].filterIt(
    not (it.pageId == tid.pageId and it.slotId == tid.slotId))
  if leaf.tids[idx].len == 0:
    leaf.keys.delete(idx)
    leaf.tids.delete(idx)

# ─── Build index from heap scan ───────────────────────────────────────────

proc buildFromHeap*(bt: BTree; hf: HeapFile; ncols: int) =
  import ../catalog/schema as sch
  hf.scan(proc(tid: storage_heap_file.TupleId; data: seq[byte]): bool =
    let row = decodeTuple(data, ncols)
    if bt.colIdx < row.len:
      bt.insert(row[bt.colIdx],
        BTree_TupleId(pageId: tid.pageId, slotId: tid.slotId))
    true
  )
