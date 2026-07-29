## model_registry.nim — Versioned ML model storage
##
## Models stored as typed byte blobs with full version history.
## Supports A/B testing: two versions serve traffic with configurable split.
## Rollback = one call. Model promotion = one call.
##
## SQL integration:
##   TRAIN MODEL <name> ON <table> PREDICT <col> USING linear|logistic|kmeans
##   PREDICT FROM MODEL <name> [VERSION <v>] WHERE ...
##   DROP MODEL <name>

import std/[tables, locks, times, json, os, strformat]
import ../storage/types
import linear

type
  ModelKind* = enum
    mkLinear, mkLogistic, mkKMeans, mkCustom

  ModelVersion* = object
    version*:   int
    kind*:      ModelKind
    weights*:   seq[byte]       ## serialised model blob
    trainedAt*: int64           ## unix timestamp
    metrics*:   Table[string, float64]  ## "r2", "accuracy", "inertia", ...
    tag*:       string          ## "production", "shadow", "archived"
    nSamples*:  int64

  ModelEntry* = object
    name*:       string
    versions*:   seq[ModelVersion]
    production*: int            ## version index currently serving
    shadow*:     int            ## -1 = no shadow
    abRatio*:    float32        ## fraction of traffic to shadow (A/B test)

  ModelRegistry* = ref object
    mu*:      Lock
    entries*: Table[string, ModelEntry]
    dataDir*: string

proc newModelRegistry*(dataDir: string): ModelRegistry =
  result = ModelRegistry(dataDir: dataDir)
  initLock(result.mu)
  createDir(dataDir / "models")
  ## Load existing registry from JSON
  let metaPath = dataDir / "models" / "registry.json"
  if fileExists(metaPath):
    try:
      let js = parseFile(metaPath)
      for name, jentry in js:
        var entry = ModelEntry(name: name)
        entry.production = jentry["production"].getInt()
        entry.shadow     = jentry{"shadow"}.getInt(-1)
        entry.abRatio    = float32(jentry{"abRatio"}.getFloat(0.0))
        for jver in jentry["versions"]:
          var mv = ModelVersion()
          mv.version   = jver["version"].getInt()
          mv.kind      = ModelKind(jver["kind"].getInt())
          mv.trainedAt = jver["trainedAt"].getBiggestInt()
          mv.tag       = jver{"tag"}.getStr("")
          mv.nSamples  = jver{"nSamples"}.getBiggestInt()
          ## Reload weights blob from file
          let wpath = dataDir / "models" / name & "_v" & $mv.version & ".bin"
          if fileExists(wpath):
            let f = open(wpath, fmRead)
            mv.weights = newSeq[byte](getFileSize(wpath))
            if mv.weights.len > 0:
              discard f.readBuffer(addr mv.weights[0], mv.weights.len)
            f.close()
          entry.versions.add(mv)
        result.entries[name] = entry
    except: discard

proc save(reg: ModelRegistry) =
  var root = newJObject()
  for name, entry in reg.entries:
    var je = newJObject()
    je["production"] = %entry.production
    je["shadow"]     = %entry.shadow
    je["abRatio"]    = %entry.abRatio
    var vers = newJArray()
    for mv in entry.versions:
      var jv = newJObject()
      jv["version"]   = %mv.version
      jv["kind"]      = %int(mv.kind)
      jv["trainedAt"] = %mv.trainedAt
      jv["tag"]       = %mv.tag
      jv["nSamples"]  = %mv.nSamples
      vers.add(jv)
    je["versions"] = vers
    root[name] = je
  writeFile(reg.dataDir / "models" / "registry.json", $root)

proc register*(reg: ModelRegistry; name: string; kind: ModelKind;
               weights: seq[byte]; metrics: Table[string, float64];
               nSamples: int64 = 0): int =
  ## Add a new model version. Returns the version number.
  acquire(reg.mu); defer: release(reg.mu)
  if name notin reg.entries:
    reg.entries[name] = ModelEntry(name: name, production: 0, shadow: -1)
  var entry = reg.entries[name]
  let ver   = entry.versions.len
  let mv    = ModelVersion(
    version:   ver,
    kind:      kind,
    weights:   weights,
    trainedAt: getTime().toUnix(),
    metrics:   metrics,
    tag:       if ver == 0: "production" else: "archived",
    nSamples:  nSamples)
  ## Persist weights to disk
  let wpath = reg.dataDir / "models" / name & "_v" & $ver & ".bin"
  let f = open(wpath, fmWrite)
  if weights.len > 0: discard f.writeBuffer(unsafeAddr weights[0], weights.len)
  f.close()
  entry.versions.add(mv)
  if ver == 0: entry.production = 0
  reg.entries[name] = entry
  reg.save()
  ver

proc promote*(reg: ModelRegistry; name: string; version: int) =
  ## Promote a version to production.
  acquire(reg.mu); defer: release(reg.mu)
  var entry = reg.entries[name]
  if version >= entry.versions.len:
    raise newException(StorageError, "Version not found")
  entry.versions[entry.production].tag = "archived"
  entry.production = version
  entry.versions[version].tag = "production"
  reg.entries[name] = entry
  reg.save()

proc rollback*(reg: ModelRegistry; name: string) =
  ## Roll back to the previous version.
  acquire(reg.mu); defer: release(reg.mu)
  var entry = reg.entries[name]
  if entry.production == 0:
    raise newException(StorageError, "No previous version")
  let prev = entry.production - 1
  entry.versions[entry.production].tag = "archived"
  entry.production = prev
  entry.versions[prev].tag = "production"
  reg.entries[name] = entry
  reg.save()

proc startAB*(reg: ModelRegistry; name: string; challenger: int;
              ratio = 0.1'f32) =
  ## Start A/B test: `ratio` fraction of traffic goes to `challenger`.
  acquire(reg.mu); defer: release(reg.mu)
  var entry = reg.entries[name]
  entry.shadow  = challenger
  entry.abRatio = ratio
  entry.versions[challenger].tag = "shadow"
  reg.entries[name] = entry
  reg.save()

proc stopAB*(reg: ModelRegistry; name: string; promoteChallenger: bool) =
  acquire(reg.mu); defer: release(reg.mu)
  var entry = reg.entries[name]
  if entry.shadow < 0: return
  if promoteChallenger:
    entry.versions[entry.production].tag = "archived"
    entry.production = entry.shadow
    entry.versions[entry.production].tag = "production"
  else:
    entry.versions[entry.shadow].tag = "archived"
  entry.shadow  = -1
  entry.abRatio = 0.0'f32
  reg.entries[name] = entry
  reg.save()

proc getWeights*(reg: ModelRegistry; name: string;
                 version = -1): seq[byte] =
  ## Retrieve weights (production version if version=-1).
  acquire(reg.mu); defer: release(reg.mu)
  if name notin reg.entries: return @[]
  let entry = reg.entries[name]
  let ver   = if version < 0: entry.production else: version
  if ver >= entry.versions.len: return @[]
  entry.versions[ver].weights

proc getLinearModel*(reg: ModelRegistry; name: string;
                     version = -1): LinearModel =
  let w = reg.getWeights(name, version)
  if w.len == 0: return nil
  linearFromBytes(w)

proc listModels*(reg: ModelRegistry): seq[string] =
  acquire(reg.mu); defer: release(reg.mu)
  for name in reg.entries.keys: result.add(name)

proc describe*(reg: ModelRegistry; name: string): string =
  acquire(reg.mu); defer: release(reg.mu)
  if name notin reg.entries: return "Model not found: " & name
  let entry = reg.entries[name]
  result = &"Model '{name}'\n"
  result &= &"  production: v{entry.production}\n"
  if entry.shadow >= 0:
    result &= &"  shadow: v{entry.shadow} (A/B ratio={entry.abRatio:.0%})\n"
  for mv in entry.versions:
    result &= &"  v{mv.version}: {mv.kind} [{mv.tag}] " &
              &"samples={mv.nSamples} "
    for k, v in mv.metrics: result &= &"{k}={v:.4f} "
    result &= "\n"
