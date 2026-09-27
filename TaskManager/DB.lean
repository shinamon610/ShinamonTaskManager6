import TaskManager.Program
import SQLite.LowLevel

namespace TaskManager.TaskDB

open Lean

private def schema : String := "CREATE TABLE IF NOT EXISTS tasks (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT UNIQUE NOT NULL,
  tags TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(tags)),
  assign TEXT,
  plannedStart TEXT,
  plannedEnd TEXT,
  details TEXT NOT NULL DEFAULT ''
);
CREATE TABLE IF NOT EXISTS task_states (
  task_id INTEGER PRIMARY KEY REFERENCES tasks(id) ON DELETE CASCADE,
  status TEXT NOT NULL DEFAULT 'NotStarted'
    CHECK (status IN ('NotStarted', 'Doing', 'Pending', 'Done', 'Progress')),
  progress_current INTEGER,
  progress_total INTEGER,
  completed_at TEXT,
  result TEXT NOT NULL DEFAULT '',
  CHECK ((status = 'Progress'
    AND progress_current IS NOT NULL AND typeof(progress_current) = 'integer'
    AND progress_total IS NOT NULL AND typeof(progress_total) = 'integer'
    AND progress_current >= 0 AND progress_total > 0 AND progress_current <= progress_total)
    OR (status <> 'Progress' AND progress_current IS NULL AND progress_total IS NULL))
)"

private def openDatabase (path : System.FilePath) (flags : SQLite.OpenFlags) : IO SQLite := do
  let db ← SQLite.openWith path flags (busyTimeoutMs := 5000)
  db.exec "PRAGMA foreign_keys = ON"
  return db

private def openExisting (path : System.FilePath) (flags : SQLite.OpenFlags) : IO SQLite := do
  let db ← openDatabase path flags
  discard (db.prepare "SELECT t.id, s.status FROM tasks t JOIN task_states s ON s.task_id = t.id LIMIT 0")
  return db

private def register (db : SQLite) (name : String) : IO Unit := do
  let stmt ← db.prepare "INSERT INTO tasks(name)
    SELECT ?1 WHERE NOT EXISTS (SELECT 1 FROM tasks WHERE name = ?1)"
  stmt.bindText 1 name
  stmt.exec
  let state ← db.prepare "INSERT INTO task_states(task_id)
    SELECT id FROM tasks WHERE name = ?1 AND NOT EXISTS
      (SELECT 1 FROM task_states WHERE task_id = tasks.id)"
  state.bindText 1 name
  state.exec
  let reached ← db.prepare "INSERT OR IGNORE INTO reached_tasks(name) VALUES (?)"
  reached.bindText 1 name
  reached.exec

private def readOptionalText (stmt : SQLite.Stmt) (column : Int32) : IO (Option String) := do
  if ← stmt.columnNull column then return none
  return some (← stmt.columnText column)

private def bindOptionalText (stmt : SQLite.Stmt) (index : Int32) : Option String → IO Unit
  | some value => stmt.bindText index value
  | none => stmt.bindNull index

private def readJson [FromJson α] (stmt : SQLite.Stmt) (column : Int32) : IO α := do
  match Json.parse (← stmt.columnText column) >>= fromJson? with
  | .ok value => pure value
  | .error message => throw <| IO.userError s!"Invalid stored JSON: {message}"

private def readState (stmt : SQLite.Stmt) (offset : Int32 := 0) : IO TaskState := do
  let status ← match ← stmt.columnText offset with
    | "NotStarted" => pure Status.NotStarted
    | "Doing" => pure Status.Doing
    | "Pending" => pure Status.Pending
    | "Done" => pure Status.Done
    | "Progress" => do
      let current ← stmt.columnInt64 (offset + 1)
      let total ← stmt.columnInt64 (offset + 2)
      pure (.Progress current.toInt.toNat total.toInt.toNat)
    | value => throw <| IO.userError s!"Invalid stored status: {value}"
  let completedAt ← readOptionalText stmt (offset + 3)
  let result ← stmt.columnText (offset + 4)
  return { status, completedAt, result }

private def readRecord [FromJson Tag] (stmt : SQLite.Stmt) : IO (TaskRecord Tag) := do
  let id ← stmt.columnInt64 0
  return {
    id := id.toInt.toNat
    name := ← stmt.columnText 1
    tags := ← readJson stmt 2
    assign := ← readOptionalText stmt 3
    plannedStart := ← readOptionalText stmt 4
    plannedEnd := ← readOptionalText stmt 5
    details := ← stmt.columnText 6
    state := ← readState stmt 7 }

private def selectRecords := "SELECT t.id, t.name, t.tags, t.assign, t.plannedStart, t.plannedEnd, t.details,
  s.status, s.progress_current, s.progress_total, s.completed_at, s.result
  FROM tasks t JOIN task_states s ON s.task_id = t.id"

private def readByName [FromJson Tag] (db : SQLite) (name : String) : IO (TaskRecord Tag) := do
  let stmt ← db.prepare (selectRecords ++ " WHERE t.name = ?")
  stmt.bindText 1 name
  unless ← stmt.step do throw <| IO.userError s!"Task not found: {name}"
  readRecord stmt

private def bindId (stmt : SQLite.Stmt) (id : NodeId) : IO Unit := do
  if id == 0 || id > 9223372036854775807 then
    throw <| IO.userError "ID must be a positive SQLite integer"
  stmt.bindInt64 1 (Int64.ofInt id)

private def readById [FromJson Tag] (db : SQLite) (id : NodeId) : IO (TaskRecord Tag) := do
  let stmt ← db.prepare (selectRecords ++ " WHERE t.id = ?")
  bindId stmt id
  unless ← stmt.step do throw <| IO.userError s!"Task not found: {id}"
  readRecord stmt

private def readStateById (db : SQLite) (id : NodeId) : IO TaskState := do
  let stmt ← db.prepare "SELECT status, progress_current, progress_total, completed_at, result
    FROM task_states WHERE task_id = ?"
  bindId stmt id
  unless ← stmt.step do throw <| IO.userError s!"Task not found: {id}"
  readState stmt

private def writeState (db : SQLite) (id : NodeId) (state : TaskState) : IO Unit := do
  let stmt ← db.prepare "UPDATE task_states SET status = ?2, progress_current = ?3,
    progress_total = ?4, completed_at = ?5, result = ?6 WHERE task_id = ?1"
  bindId stmt id
  let status ← match state.status with
    | .NotStarted => pure "NotStarted"
    | .Doing => pure "Doing"
    | .Pending => pure "Pending"
    | .Done => pure "Done"
    | .Progress current total => do
      if total == 0 || current > total || total > 9223372036854775807 then
        throw <| IO.userError "Progress requires 0 <= CURRENT <= TOTAL <= 9223372036854775807 and TOTAL > 0"
      stmt.bindInt64 3 (Int64.ofInt current)
      stmt.bindInt64 4 (Int64.ofInt total)
      pure "Progress"
  if status != "Progress" then
    stmt.bindNull 3
    stmt.bindNull 4
  stmt.bindText 2 status
  bindOptionalText stmt 5 state.completedAt
  stmt.bindText 6 state.result
  stmt.exec
  if (← db.changes) == 0 then throw <| IO.userError s!"Task not found: {id}"

/-- 登録済みタスクの状態全体を、DB の ID で指定して更新する。 -/
def setState (path : System.FilePath) (id : NodeId) (state : TaskState) : IO Unit := do
  writeState (← openExisting path .readWrite) id state

/-- 完了にし、UTC の現在日時を記録する。結果を省略した場合は既存の結果を保持する。 -/
def setDone (path : System.FilePath) (id : NodeId) (result : Option String := none) : IO Unit := do
  let db ← openExisting path .readWrite
  db.transaction (mode := .immediate) do
    let state ← readStateById db id
    let clock ← db.prepare "SELECT strftime('%Y-%m-%dT%H:%M:%fZ', 'now')"
    unless ← clock.step do throw <| IO.userError "Failed to read current time"
    let completedAt ← clock.columnText 0
    writeState db id { state with
      status := .Done, completedAt := some completedAt,
      result := result.getD state.result }

/-- Done は完了日時を自動設定する。他の状態への変更は結果・完了日を保持する。 -/
def setStatus (path : System.FilePath) (id : NodeId) (status : Status) : IO Unit := do
  if status == .Done then
    return ← setDone path id
  let db ← openExisting path .readWrite
  db.transaction (mode := .immediate) do
    let state ← readStateById db id
    writeState db id { state with status }

/-- 読み取り専用。未登録 ID はエラー。 -/
def getTask [FromJson Tag] (path : System.FilePath) (id : NodeId) : IO (TaskRecord Tag) := do
  readById (← openExisting path .readonly) id

def getState (path : System.FilePath) (id : NodeId) : IO TaskState := do
  readStateById (← openExisting path .readonly) id

/-- グラフに現れないものも含め、DB 内の全タスクを ID 順で取得する。 -/
def getTasks [FromJson Tag] (path : System.FilePath) : IO (Array (TaskRecord Tag)) := do
  let db ← openExisting path .readonly
  let stmt ← db.prepare (selectRecords ++ " ORDER BY t.id")
  let mut records := #[]
  while ← stmt.step do records := records.push (← readRecord stmt)
  return records

private def interpret [ToJson Tag] [FromJson Tag] (db : SQLite)
    (program : TaskProg Tag α) : StateT (Graph Tag) IO α := do
  match program with
  | .pure value => return value
  | .readState name next =>
    register db name
    let stmt ← db.prepare "SELECT status, progress_current, progress_total, completed_at, result
      FROM task_states JOIN tasks ON tasks.id = task_states.task_id WHERE name = ?"
    stmt.bindText 1 name
    unless ← stmt.step do throw <| IO.userError s!"Task not found: {name}"
    let state ← readState stmt
    interpret db (next state)
  | .addTask task next =>
    let graph ← get
    match graph.nodes.find? (fun node => node.task.name == task.name) with
    | some node => interpret db (next node.id)
    | none =>
      register db task.name
      let update ← db.prepare "UPDATE tasks SET tags = ?2, assign = ?3,
        plannedStart = ?4, plannedEnd = ?5, details = ?6 WHERE name = ?1"
      update.bindText 1 task.name
      update.bindText 2 (toJson task.tags).compress
      bindOptionalText update 3 task.assign
      bindOptionalText update 4 task.plannedStart
      bindOptionalText update 5 task.plannedEnd
      update.bindText 6 task.details
      update.exec
      let record ← readByName (Tag := Tag) db task.name
      set { graph with nodes := graph.nodes.push { id := record.id, task, state := record.state } }
      interpret db (next record.id)
  | .addEdge source target next =>
    let graph ← get
    unless graph.nodes.any (·.id == source) && graph.nodes.any (·.id == target) do
      throw <| IO.userError s!"Invalid edge: {source} -> {target}"
    set { graph with edges := graph.edges.push { source, target } }
    interpret db next

/--
必要な時点で状態を読み、実行結果のグラフを返す。DB に辺やグラフは保存しない。
同名は同じ DB ID と状態を引き継ぐ。定義情報は実行中の最初の追加を採用する。
全定義情報を保存し、状態参照も含め今回到達しなかった名前は削除する。
一回の実行は一つのトランザクションなので、分岐と出力の状態が整合する。
-/
def run [ToJson Tag] [FromJson Tag] (path : System.FilePath)
    (program : TaskProg Tag α) : IO (α × Graph Tag) := do
  let db ← openDatabase path .readWriteCreate
  db.transaction (mode := .immediate) do
    db.exec schema
    db.exec "CREATE TEMP TABLE reached_tasks (name TEXT PRIMARY KEY)"
    let output ← (interpret db program).run {}
    db.exec "DELETE FROM tasks WHERE name NOT IN (SELECT name FROM reached_tasks)"
    return output

/-- CLI 用の更新。現在のグラフの検証と更新を同じトランザクションで行う。 -/
def setTaskStatus [ToJson Tag] [FromJson Tag] (path : System.FilePath)
    (program : TaskProg Tag Unit) (id : NodeId) (status : Status)
    (result : Option String := none) : IO Unit := do
  let db ← openExisting path .readWrite
  db.transaction (mode := .immediate) do
    let oldState ← readStateById db id
    db.exec "CREATE TEMP TABLE reached_tasks (name TEXT PRIMARY KEY)"
    let (_, graph) ← (interpret db program).run {}
    unless graph.nodes.any (·.id == id) do
      throw <| IO.userError s!"Task {id} is not in the current graph"
    if oldState.status == .Done && status != .Done then
      throw <| IO.userError s!"Task {id} is already done and cannot return to an incomplete status"
    for edge in graph.edges do
      if edge.source == id then
        let some dependency := graph.nodes.find? (·.id == edge.target)
          | throw <| IO.userError s!"Missing dependency: {edge.target}"
        unless dependency.state.status == .Done do
          throw <| IO.userError s!"Task {id} requires completed dependency {dependency.id} ({dependency.task.name})"
    let mut state := { oldState with status }
    if status == .Done then
      let clock ← db.prepare "SELECT strftime('%Y-%m-%dT%H:%M:%fZ', 'now')"
      unless ← clock.step do throw <| IO.userError "Failed to read current time"
      let completedAt ← clock.columnText 0
      state := { state with
        completedAt := some completedAt
        result := result.getD state.result }
    writeState db id state

def runJson [ToJson Tag] [FromJson Tag] (path : System.FilePath)
    (program : TaskProg Tag α) : IO Json := do
  let (_, graph) ← run path program
  return toJson graph

end TaskManager.TaskDB
