import TaskManager.Program
import TaskManager.Csv
import Std.Time

namespace TaskManager.TaskDB

open Lean

private def alphabet : Array Char := "abcdefghijklmnopqrstuvwxyz234567".toList.toArray

private def randomId : IO NodeId := do
  let bytes ← IO.getRandomBytes 5
  return String.ofList (bytes.data.toList.map fun byte => alphabet[byte.toNat % 32]!)

/-- 既存 ID と衝突した候補は再生成する。draw は衝突時の動作を検証するため差し替え可能。 -/
def freshId (used : Std.HashSet NodeId) (draw : IO NodeId := randomId) : IO NodeId := do
  if used.size >= 32 ^ 5 then throw <| IO.userError "Task ID space exhausted"
  while true do
    let id ← draw
    unless NodeId.isValid id do throw <| IO.userError "Invalid generated task ID"
    if !used.contains id then return id
  throw <| IO.userError "Task ID generation failed"

private def header : Array String := #[
  "id", "name", "tags", "assign", "plannedStart", "plannedEnd", "details",
  "status", "progressCurrent", "progressTotal", "completedAt", "result"]

private def validateStatus (status : Status) : Except String Unit := do
  if let .Progress current total := status then
    if total == 0 || current > total then
      throw "Progress requires 0 <= CURRENT <= TOTAL and TOTAL > 0"

private def parseJson [FromJson α] (value : String) : Except String α :=
  Json.parse value >>= fromJson?

-- タグは生の JSON のまま保持する。状態のみの API は利用側のタグ型を必要としない。
private abbrev Stored := TaskRecord Json

private def parseRow (row : Array String) : Except String Stored := do
  if row.size != header.size then throw s!"Expected {header.size} CSV columns, got {row.size}"
  let id := row[0]!
  unless NodeId.isValid id do throw s!"Invalid task ID: {id}"
  let status ← match row[7]! with
    | "NotStarted" => pure Status.NotStarted
    | "Doing" => pure Status.Doing
    | "Pending" => pure Status.Pending
    | "Done" => pure Status.Done
    | "Progress" => do
      let some current := row[8]!.toNat? | throw "Invalid progressCurrent"
      let some total := row[9]!.toNat? | throw "Invalid progressTotal"
      pure (.Progress current total)
    | other => throw s!"Invalid status: {other}"
  validateStatus status
  unless status matches .Progress .. do
    unless row[8]!.isEmpty && row[9]!.isEmpty do
      throw "Progress columns must be empty for non-Progress status"
  return {
    id, name := row[1]!, tags := ← parseJson row[2]!,
    assign := ← parseJson row[3]!, plannedStart := ← parseJson row[4]!,
    plannedEnd := ← parseJson row[5]!, details := row[6]!,
    state := { status, completedAt := ← parseJson row[10]!, result := row[11]! } }

private def renderRow (record : Stored) : Array String := Id.run do
  let (status, current, total) := match record.state.status with
    | .NotStarted => ("NotStarted", "", "")
    | .Doing => ("Doing", "", "")
    | .Pending => ("Pending", "", "")
    | .Done => ("Done", "", "")
    | .Progress c t => ("Progress", toString c, toString t)
  return #[record.id, record.name, (toJson record.tags).compress,
    (toJson record.assign).compress, (toJson record.plannedStart).compress,
    (toJson record.plannedEnd).compress, record.details, status, current, total,
    (toJson record.state.completedAt).compress, record.state.result]

private def load (path : System.FilePath) (create := false) : IO (Array Stored) := do
  let text ← try IO.FS.readFile path catch e =>
    match e with
    | .noFileOrDirectory .. =>
      if create then return #[] else throw e
    | _ => throw e
  let rows ← IO.ofExcept (Csv.parse text)
  unless rows[0]? == some header do throw <| IO.userError s!"Invalid CSV header: {path}"
  let mut records := #[]
  let mut ids : Std.HashSet String := {}
  let mut names : Std.HashSet String := {}
  for i in [1:rows.size] do
    let record ← IO.ofExcept ((parseRow rows[i]!).mapError fun e => s!"{path}: record {i}: {e}")
    if ids.contains record.id then throw <| IO.userError s!"Duplicate task ID: {record.id}"
    if names.contains record.name then throw <| IO.userError s!"Duplicate task name: {record.name}"
    ids := ids.insert record.id
    names := names.insert record.name
    records := records.push record
  return records.qsort (fun a b => a.id < b.id)

/-- 排他制御は行わない。成功した内容を同じディレクトリの一時ファイル経由で保存する。 -/
private def save (path : System.FilePath) (records : Array Stored) : IO Unit := do
  if let some parent := path.parent then IO.FS.createDirAll parent
  let temp := System.FilePath.mk (path.toString ++ ".tmp")
  try
    let sorted := records.qsort (fun a b => a.id < b.id)
    IO.FS.writeFile temp (Csv.render (#[header] ++ sorted.map renderRow))
    IO.FS.rename temp path
  finally
    if ← temp.pathExists then IO.FS.removeFile temp

private def findRecord (records : Array Stored) (id : NodeId) : IO Stored := do
  let some record := records.find? (·.id == id)
    | throw <| IO.userError s!"Task not found: {id}"
  return record

private def withState (records : Array Stored) (id : NodeId) (state : TaskState) : IO (Array Stored) := do
  IO.ofExcept (validateStatus state.status)
  discard (findRecord records id)
  return records.map fun record => if record.id == id then { record with state } else record

private def completed (state : TaskState) (result : Option String) : IO TaskState := do
  let now ← Std.Time.DateTime.now (tz := .GMT)
  return { state with
    status := .Done, completedAt := some now.toISO8601String,
    result := result.getD state.result }

private def decodeRecord [FromJson Tag] (record : Stored) : IO (TaskRecord Tag) := do
  let tags ← IO.ofExcept (record.tags.mapM fromJson?)
  return {
    id := record.id, name := record.name, tags,
    assign := record.assign, plannedStart := record.plannedStart,
    plannedEnd := record.plannedEnd, details := record.details, state := record.state }

/-- 登録済みタスクの状態全体を更新する。グラフの検証は行わない。 -/
def setState (path : System.FilePath) (id : NodeId) (state : TaskState) : IO Unit := do
  let records ← load path
  save path (← withState records id state)

def setDone (path : System.FilePath) (id : NodeId) (result : Option String := none) : IO Unit := do
  let records ← load path
  let record ← findRecord records id
  save path (← withState records id (← completed record.state result))

def setStatus (path : System.FilePath) (id : NodeId) (status : Status) : IO Unit := do
  if status == .Done then return ← setDone path id
  let records ← load path
  let record ← findRecord records id
  save path (← withState records id { record.state with status })

/-- 読み取り専用。未登録 ID や存在しないファイルはエラー。 -/
def getTask [FromJson Tag] (path : System.FilePath) (id : NodeId) : IO (TaskRecord Tag) := do
  decodeRecord (← findRecord (← load path) id)

def getState (path : System.FilePath) (id : NodeId) : IO TaskState := do
  return (← findRecord (← load path) id).state

/-- CSV の全タスクを ID の辞書順で取得する。 -/
def getTasks [FromJson Tag] (path : System.FilePath) : IO (Array (TaskRecord Tag)) := do
  (← load path).mapM decodeRecord

private structure Execution (Tag : Type) where
  records : Array Stored
  usedIds : Std.HashSet NodeId
  reached : Std.HashSet String := {}
  graph : Graph Tag := {}

private def initial (records : Array Stored) : Execution Tag :=
  { records, usedIds := records.foldl (fun ids record => ids.insert record.id) {} }

private def register (name : String) : StateT (Execution Tag) IO Stored := do
  modify fun s => { s with reached := s.reached.insert name }
  if let some record := (← get).records.find? (·.name == name) then return record
  let id ← freshId (← get).usedIds
  let record : Stored := { id, name, state := {} }
  modify fun s => { s with records := s.records.push record, usedIds := s.usedIds.insert id }
  return record

private def interpret [ToJson Tag] (program : TaskProg Tag α) : StateT (Execution Tag) IO α := do
  match program with
  | .pure value => return value
  | .readState name next =>
    let record ← register name
    interpret (next record.state)
  | .addTask task next =>
    if let some node := (← get).graph.nodes.find? (·.task.name == task.name) then
      interpret (next node.id)
    else
      let record ← register task.name
      let updated : Stored := {
        id := record.id, name := task.name, tags := task.tags.map toJson,
        assign := task.assign, plannedStart := task.plannedStart, plannedEnd := task.plannedEnd,
        details := task.details, state := record.state }
      modify fun s => { s with
        records := s.records.map (fun r => if r.id == record.id then updated else r)
        graph := { s.graph with nodes := s.graph.nodes.push { id := record.id, task, state := record.state } } }
      interpret (next record.id)
  | .addEdge source target next =>
    let graph := (← get).graph
    unless graph.nodes.any (·.id == source) && graph.nodes.any (·.id == target) do
      throw <| IO.userError s!"Invalid edge: {source} -> {target}"
    modify fun s => { s with graph := { graph with edges := graph.edges.push { source, target } } }
    interpret next

/--
CSV を読み込み、定義をメモリ上で実行し、成功した場合のみ到達集合を保存する。
状態参照だけの名前も残すため、グラフとは別に reached を管理する。
同名は ID と状態を引き継ぎ、定義情報は実行中の最初の追加を採用する。
-/
def run [ToJson Tag] (path : System.FilePath) (program : TaskProg Tag α) : IO (α × Graph Tag) := do
  let (value, s) ← (interpret program).run (initial (← load path true))
  save path (s.records.filter fun record => s.reached.contains record.name)
  return (value, s.graph)

/-- グラフの検証に成功した場合のみ保存する。未到達タスクの削除は run のみで行う。 -/
def setTaskStatus [ToJson Tag] (path : System.FilePath)
    (program : TaskProg Tag Unit) (id : NodeId) (status : Status)
    (result : Option String := none) : IO Unit := do
  let records ← load path
  let oldState := (← findRecord records id).state
  let (_, s) ← (interpret program).run (initial records)
  unless s.graph.nodes.any (·.id == id) do
    throw <| IO.userError s!"Task {id} is not in the current graph"
  if oldState.status == .Done && status != .Done then
    throw <| IO.userError s!"Task {id} is already done and cannot return to an incomplete status"
  for edge in s.graph.edges do
    if edge.source == id then
      let some dependency := s.graph.nodes.find? (·.id == edge.target)
        | throw <| IO.userError s!"Missing dependency: {edge.target}"
      unless dependency.state.status == .Done do
        throw <| IO.userError s!"Task {id} requires completed dependency {dependency.id} ({dependency.task.name})"
  let state ← if status == .Done then completed oldState result else pure { oldState with status }
  save path (← withState s.records id state)

def runJson [ToJson Tag] (path : System.FilePath) (program : TaskProg Tag α) : IO Json := do
  let (_, graph) ← run path program
  return toJson graph

end TaskManager.TaskDB
