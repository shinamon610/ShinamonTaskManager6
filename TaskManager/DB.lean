import TaskManager.Program
import SQLite.LowLevel

namespace TaskManager.TaskDB

open Lean

private def schema : String := "CREATE TABLE IF NOT EXISTS task_states (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT UNIQUE NOT NULL,
  state TEXT NOT NULL CHECK (json_valid(state))
)"

private def hasId (db : SQLite) : IO Bool := do
  let stmt ← db.prepare "PRAGMA table_info(task_states)"
  while ← stmt.step do
    if (← stmt.columnText 1) == "id" then return true
  return false

private def openDB (path : System.FilePath) : IO SQLite := do
  let db ← SQLite.open path 5000
  db.transaction (mode := .immediate) do
    db.exec schema
    unless ← hasId db do
      -- 旧形式の名前・状態を保持して、rowid を永続 ID に移行する。
      db.exec "ALTER TABLE task_states RENAME TO task_states_legacy"
      db.exec schema
      db.exec "INSERT INTO task_states(id, name, state)
        SELECT rowid, name, state FROM task_states_legacy ORDER BY rowid"
      db.exec "DROP TABLE task_states_legacy"
  return db

private def openExisting (path : System.FilePath) (flags : SQLite.OpenFlags) : IO SQLite := do
  let db ← SQLite.openWith path flags (busyTimeoutMs := 5000)
  unless ← hasId db do
    throw <| IO.userError "Old or missing task schema. Run taskdb graph DB to initialize/migrate it."
  return db

private def register (db : SQLite) (name : String) : IO Unit := do
  let stmt ← db.prepare "INSERT INTO task_states(name, state)
    SELECT ?1, ?2 WHERE NOT EXISTS (SELECT 1 FROM task_states WHERE name = ?1)"
  stmt.bindText 1 name
  stmt.bindText 2 (toJson ({} : TaskState)).compress
  stmt.exec

private def readRecord (stmt : SQLite.Stmt) : IO TaskRecord := do
  let id ← stmt.columnInt64 0
  let name ← stmt.columnText 1
  let text ← stmt.columnText 2
  match Json.parse text >>= fromJson? with
  | .ok state => return { id := id.toInt.toNat, name, state }
  | .error message => throw <| IO.userError s!"Invalid state for {name}: {message}"

private def readByName (db : SQLite) (name : String) : IO TaskRecord := do
  let stmt ← db.prepare "SELECT id, name, state FROM task_states WHERE name = ?"
  stmt.bindText 1 name
  unless ← stmt.step do throw <| IO.userError s!"Task not found: {name}"
  readRecord stmt

private def bindId (stmt : SQLite.Stmt) (id : NodeId) : IO Unit := do
  if id == 0 || id > 9223372036854775807 then
    throw <| IO.userError "ID must be a positive SQLite integer"
  stmt.bindInt64 1 (Int64.ofInt id)

private def readById (db : SQLite) (id : NodeId) : IO TaskRecord := do
  let stmt ← db.prepare "SELECT id, name, state FROM task_states WHERE id = ?"
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
  let stmt ← db.prepare "SELECT id, name, state FROM task_states ORDER BY id"
  let mut records := #[]
  while ← stmt.step do records := records.push (← readRecord stmt)
  return records

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
一回の実行は一つのトランザクションなので、分岐と出力の状態が整合する。
-/
def run (path : System.FilePath) (program : TaskProg α) : IO (α × Graph) := do
  let db ← openDB path
  db.transaction (mode := .immediate) do
    (interpret db program).run {}

def runJson (path : System.FilePath) (program : TaskProg α) : IO Json := do
  let (_, graph) ← run path program
  return toJson graph

end TaskManager.TaskDB
