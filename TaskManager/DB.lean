import TaskManager.Program
import SQLite.LowLevel

namespace TaskManager.TaskDB

open Lean

private def schema : String := "CREATE TABLE IF NOT EXISTS task_states (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT UNIQUE NOT NULL,
  tags TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(tags)),
  assign TEXT,
  links TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(links)),
  plannedStart TEXT,
  plannedEnd TEXT,
  details TEXT NOT NULL DEFAULT '',
  state TEXT NOT NULL CHECK (json_valid(state))
)"

private def hasColumn (db : SQLite) (name : String) : IO Bool := do
  let stmt ← db.prepare "PRAGMA table_info(task_states)"
  while ← stmt.step do
    if (← stmt.columnText 1) == name then return true
  return false

private def initializeSchema (db : SQLite) : IO Unit := do
  db.exec schema
  unless ← hasColumn db "details" do
    let hasTask ← hasColumn db "task"
    let hasPersistentId ← hasColumn db "id"
    let highWater ← if hasPersistentId then do
      let sequence ← db.prepare "SELECT seq FROM sqlite_sequence WHERE name = 'task_states'"
      if ← sequence.step then pure (← sequence.columnInt64 0) else pure 0
      else pure 0
    db.exec "ALTER TABLE task_states RENAME TO task_states_legacy"
    db.exec schema
    if hasTask then
      db.exec "INSERT INTO task_states(id, name, tags, assign, links, plannedStart, plannedEnd, details, state)
        SELECT id, name, COALESCE(json_extract(task, '$.tags'), '[]'), json_extract(task, '$.assign'),
          COALESCE(json_extract(task, '$.links'), '[]'), json_extract(task, '$.plannedStart'),
          json_extract(task, '$.plannedEnd'), COALESCE(json_extract(task, '$.details'), ''), state
        FROM task_states_legacy ORDER BY id"
    else
      db.exec "INSERT INTO task_states(id, name, state)
        SELECT rowid, name, state FROM task_states_legacy ORDER BY rowid"
    db.exec "INSERT INTO sqlite_sequence(name, seq) SELECT 'task_states', 0
      WHERE NOT EXISTS (SELECT 1 FROM sqlite_sequence WHERE name = 'task_states')"
    let preserveSequence ← db.prepare "UPDATE sqlite_sequence SET seq = MAX(seq, ?1) WHERE name = 'task_states'"
    preserveSequence.bindInt64 1 highWater
    preserveSequence.exec
    db.exec "DROP TABLE task_states_legacy"

private def openExisting (path : System.FilePath) (flags : SQLite.OpenFlags) : IO SQLite := do
  let db ← SQLite.openWith path flags (busyTimeoutMs := 5000)
  unless (← hasColumn db "id") && (← hasColumn db "details") do
    throw <| IO.userError "Old or missing task schema. Run taskdb graph to initialize/migrate the configured database."
  return db

private def register (db : SQLite) (name : String) : IO Unit := do
  let stmt ← db.prepare "INSERT INTO task_states(name, state)
    SELECT ?1, ?2 WHERE NOT EXISTS (SELECT 1 FROM task_states WHERE name = ?1)"
  stmt.bindText 1 name
  stmt.bindText 2 (toJson ({} : TaskState)).compress
  stmt.exec
  let reached ← db.prepare "INSERT OR IGNORE INTO reached_tasks(name) VALUES (?)"
  reached.bindText 1 name
  reached.exec

private def readOptionalText (stmt : SQLite.Stmt) (column : Int32) : IO (Option String) := do
  if ← stmt.columnNull column then return none
  return some (← stmt.columnText column)

private def readJson [FromJson α] (stmt : SQLite.Stmt) (column : Int32) : IO α := do
  match Json.parse (← stmt.columnText column) >>= fromJson? with
  | .ok value => pure value
  | .error message => throw <| IO.userError s!"Invalid stored JSON: {message}"

private def readRecord (stmt : SQLite.Stmt) : IO TaskRecord := do
  let id ← stmt.columnInt64 0
  let name ← stmt.columnText 1
  return {
    id := id.toInt.toNat
    name := name
    state := ← readJson stmt 2
    tags := ← readJson stmt 3
    assign := ← readOptionalText stmt 4
    links := ← readJson stmt 5
    plannedStart := ← readOptionalText stmt 6
    plannedEnd := ← readOptionalText stmt 7
    details := ← stmt.columnText 8 }

private def selectRecords := "SELECT id, name, state, tags, assign, links, plannedStart, plannedEnd, details FROM task_states"

private def readByName (db : SQLite) (name : String) : IO TaskRecord := do
  let stmt ← db.prepare (selectRecords ++ " WHERE name = ?")
  stmt.bindText 1 name
  unless ← stmt.step do throw <| IO.userError s!"Task not found: {name}"
  readRecord stmt

private def bindId (stmt : SQLite.Stmt) (id : NodeId) : IO Unit := do
  if id == 0 || id > 9223372036854775807 then
    throw <| IO.userError "ID must be a positive SQLite integer"
  stmt.bindInt64 1 (Int64.ofInt id)

private def readById (db : SQLite) (id : NodeId) : IO TaskRecord := do
  let stmt ← db.prepare (selectRecords ++ " WHERE id = ?")
  bindId stmt id
  unless ← stmt.step do throw <| IO.userError s!"Task not found: {id}"
  readRecord stmt

private def writeState (db : SQLite) (id : NodeId) (state : TaskState) : IO Unit := do
  let stmt ← db.prepare "UPDATE task_states SET state = ?2 WHERE id = ?1"
  bindId stmt id
  stmt.bindText 2 (toJson state).compress
  stmt.exec
  if (← db.changes) == 0 then throw <| IO.userError s!"Task not found: {id}"

/-- 登録済みタスクの状態全体を、DB の ID で指定して更新する。 -/
def setState (path : System.FilePath) (id : NodeId) (state : TaskState) : IO Unit := do
  writeState (← openExisting path .readWrite) id state

/-- 完了にし、UTC の現在日時を記録する。結果を省略した場合は既存の結果を保持する。 -/
def setDone (path : System.FilePath) (id : NodeId) (result : Option String := none) : IO Unit := do
  let db ← openExisting path .readWrite
  db.transaction (mode := .immediate) do
    let record ← readById db id
    let clock ← db.prepare "SELECT strftime('%Y-%m-%dT%H:%M:%fZ', 'now')"
    unless ← clock.step do throw <| IO.userError "Failed to read current time"
    let completedAt ← clock.columnText 0
    writeState db id { record.state with
      status := .Done, completedAt := some completedAt,
      result := result.getD record.state.result }

/-- Done は完了日時を自動設定する。他の状態への変更は結果・完了日を保持する。 -/
def setStatus (path : System.FilePath) (id : NodeId) (status : Status) : IO Unit := do
  if status == .Done then
    return ← setDone path id
  let db ← openExisting path .readWrite
  db.transaction (mode := .immediate) do
    let record ← readById db id
    writeState db id { record.state with status }

/-- 読み取り専用。未登録 ID はエラー。 -/
def getTask (path : System.FilePath) (id : NodeId) : IO TaskRecord := do
  readById (← openExisting path .readonly) id

def getState (path : System.FilePath) (id : NodeId) : IO TaskState := do
  return (← getTask path id).state

/-- グラフに現れないものも含め、DB 内の全タスクを ID 順で取得する。 -/
def getTasks (path : System.FilePath) : IO (Array TaskRecord) := do
  let db ← openExisting path .readonly
  let stmt ← db.prepare (selectRecords ++ " ORDER BY id")
  let mut records := #[]
  while ← stmt.step do records := records.push (← readRecord stmt)
  return records

private def bindOptionalText (stmt : SQLite.Stmt) (index : Int32) : Option String → IO Unit
  | some value => stmt.bindText index value
  | none => stmt.bindNull index

private def interpret (db : SQLite) (program : TaskProg α) : StateT Graph IO α := do
  match program with
  | .pure value => return value
  | .readState name next =>
    register db name
    let record ← readByName db name
    interpret db (next record.state)
  | .addTask task next =>
    let graph ← get
    match graph.nodes.find? (fun node => node.task.name == task.name) with
    | some node => interpret db (next node.id)
    | none =>
      register db task.name
      let update ← db.prepare "UPDATE task_states SET tags = ?2, assign = ?3, links = ?4,
        plannedStart = ?5, plannedEnd = ?6, details = ?7 WHERE name = ?1"
      update.bindText 1 task.name
      update.bindText 2 (toJson task.tags).compress
      bindOptionalText update 3 task.assign
      update.bindText 4 (toJson task.links).compress
      bindOptionalText update 5 task.plannedStart
      bindOptionalText update 6 task.plannedEnd
      update.bindText 7 task.details
      update.exec
      let record ← readByName db task.name
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
def run (path : System.FilePath) (program : TaskProg α) : IO (α × Graph) := do
  let db ← SQLite.open path 5000
  db.transaction (mode := .immediate) do
    initializeSchema db
    db.exec "CREATE TEMP TABLE reached_tasks (name TEXT PRIMARY KEY)"
    let output ← (interpret db program).run {}
    db.exec "DELETE FROM task_states WHERE name NOT IN (SELECT name FROM reached_tasks)"
    return output

/-- CLI 用の更新。現在のグラフの検証と更新を同じトランザクションで行う。 -/
def setTaskStatus (path : System.FilePath) (program : TaskProg Unit)
    (id : NodeId) (status : Status) (result : Option String := none) : IO Unit := do
  let db ← openExisting path .readWrite
  db.transaction (mode := .immediate) do
    let record ← readById db id
    db.exec "CREATE TEMP TABLE reached_tasks (name TEXT PRIMARY KEY)"
    let (_, graph) ← (interpret db program).run {}
    unless graph.nodes.any (·.id == id) do
      throw <| IO.userError s!"Task {id} is not in the current graph"
    if record.state.status == .Done && status != .Done then
      throw <| IO.userError s!"Task {id} is already done and cannot return to an incomplete status"
    for edge in graph.edges do
      if edge.source == id then
        let some dependency := graph.nodes.find? (·.id == edge.target)
          | throw <| IO.userError s!"Missing dependency: {edge.target}"
        unless dependency.state.status == .Done do
          throw <| IO.userError s!"Task {id} requires completed dependency {dependency.id} ({dependency.task.name})"
    if let .Progress current total := status then
      if total == 0 || current > total then
        throw <| IO.userError "Progress requires 0 <= CURRENT <= TOTAL and TOTAL > 0"
    let mut state := { record.state with status }
    if status == .Done then
      let clock ← db.prepare "SELECT strftime('%Y-%m-%dT%H:%M:%fZ', 'now')"
      unless ← clock.step do throw <| IO.userError "Failed to read current time"
      let completedAt ← clock.columnText 0
      state := { state with
        completedAt := some completedAt
        result := result.getD record.state.result }
    writeState db id state

def runJson (path : System.FilePath) (program : TaskProg α) : IO Json := do
  let (_, graph) ← run path program
  return toJson graph

end TaskManager.TaskDB
