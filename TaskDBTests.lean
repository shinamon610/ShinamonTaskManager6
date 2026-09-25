import TaskManager

open Lean TaskManager

private def workflow : TaskProg Unit := do
  let design : Task := { name := "設計", tags := [.Programing], details := "実装の方針を決める" }
  if (← getTaskStatus "設計") == .Done then
    if (← getTaskStatus "実装") == .Done then
      pushU { name := "テスト", tags := [.Programing] } [
        push { name := "実装", tags := [.Programing] } [push design]
      ]
    else
      pushU { name := "実装", tags := [.Programing] } [push design]
  else
    pushU { name := "設計の見直し" } [push design]

private def cycle : TaskProg Unit := do
  let a ← push { name := "A" }
  let b ← push { name := "B" } [] [a]
  addEdge a b

private def check (condition : Bool) (message : String) : IO Unit := do
  unless condition do throw <| IO.userError message

private def expectFailure (action : IO Unit) (message : String) : IO Unit := do
  let failed ← try
    action
    pure false
  catch _ => pure true
  check failed message

private def names (graph : Graph) := graph.nodes.map (·.task.name)

private def idOf (path : System.FilePath) (name : String) : IO NodeId := do
  let some record := (← TaskDB.getTasks path).find? (·.name == name)
    | throw <| IO.userError s!"Missing test task: {name}"
  return record.id

private def refJson (id : Nat) (name : String) : Json :=
  Json.mkObj [("id", toJson id), ("name", toJson name)]

private def nodeJson (id : Nat) (name : String) (dependents : Array Json := #[]) : Json :=
  (refJson id name).mergeObj (Json.mkObj [("dependents", .arr dependents)])

private def registered (path : System.FilePath) (name : String) : IO Bool := do
  let db ← SQLite.openWith path .readonly
  let query ← db.prepare "SELECT 1 FROM task_states WHERE name = ?"
  query.bindText 1 name
  query.step

private def tests (path : System.FilePath) : IO Unit := do
  expectFailure (discard (TaskDB.getTask path 999999)) "get must not create DB"
  expectFailure (discard (TaskDB.getTasks path)) "gets must not create DB"
  expectFailure (TaskDB.setStatus path 999999 .Done) "set must not create DB"
  expectFailure (TaskDB.setState path 999999 {}) "set-state must not create DB"
  check (!(← path.pathExists)) "read/update must leave missing DB absent"

  let (_, emptyGraph) ← TaskDB.run path (pure () : TaskProg Unit)
  check ((← TaskDB.getTasks path).isEmpty) "gets on empty database"
  check (toJson emptyGraph == Json.arr #[]) "empty JSON"
  expectFailure (discard (TaskDB.getTask path 999999)) "unknown get"
  expectFailure (TaskDB.setStatus path 999999 .Done) "unknown set"
  expectFailure (TaskDB.setState path 999999 {}) "unknown set-state"
  check ((← TaskDB.getTasks path).isEmpty) "unknown IDs must not register"
  expectFailure (TaskDB.setState path 0 {}) "zero ID"
  expectFailure (TaskDB.setState path 9223372036854775808 {}) "overflow ID"

  let (status, onlyState) ← TaskDB.run path (getTaskStatus "状態のみ")
  check (status == .NotStarted && onlyState.nodes.isEmpty) "on-demand state read"
  let stateOnlyId ← idOf path "状態のみ"
  TaskDB.setState path stateOnlyId {}
  TaskDB.setState path stateOnlyId {}
  check ((← TaskDB.getState path stateOnlyId) == ({} : TaskState)) "idempotent update"

  let (_, first) ← TaskDB.run path workflow
  check (names first == #["設計", "設計の見直し"]) "initial branch"
  check (!(← registered path "実装") && !(← registered path "テスト")) "unselected registration"
  let designId ← idOf path "設計"
  TaskDB.setState path designId { status := .Done, result := "approved", completedAt := some "2026-09-22" }
  let (_, second) ← TaskDB.run path workflow
  check (names second == #["設計", "実装"]) "DB branch"
  check (!(← registered path "テスト")) "nested unselected branch"
  let implementId ← idOf path "実装"
  TaskDB.setStatus path implementId (.Progress 2 5)
  let (_, progress) ← TaskDB.run path workflow
  check (progress.nodes[1]?.map (·.state.status) == some (.Progress 2 5)) "progress persistence"
  TaskDB.setStatus path implementId .Done
  let (_, third) ← TaskDB.run path workflow
  let testId ← idOf path "テスト"
  check (third.edges == #[⟨implementId, designId⟩, ⟨testId, implementId⟩]) "edge direction"
  check (toJson third == Json.arr #[nodeJson designId "設計" #[nodeJson implementId "実装" #[nodeJson testId "テスト"]]])
    "JSON direction and persistent IDs"

  let records ← TaskDB.getTasks path
  check (!(records.any (·.name == "設計の見直し"))) "run removes tasks outside reached set"
  for record in records do
    check ((← TaskDB.getTask path record.id) == record) "gets is get for every row"

  let (_, changed) ← TaskDB.run path do
    let earlier ← push { name := "前に追加" }
    let design ← push { name := "設計", details := "変更後" } [] [earlier]
    let same ← push { name := "設計" }
    addEdge same design
  check (names changed == #["前に追加", "設計"]) "same-name merge"
  check (changed.nodes[1]?.map (·.id) == some designId) "stable ID across graph changes"
  check (changed.nodes[1]?.map (·.state.status) == some .Done) "state across graph changes"
  check (changed.nodes[1]?.map (·.task.details) == some "変更後") "source metadata"
  TaskDB.setStatus path designId .Doing
  let state ← TaskDB.getState path designId
  check (state.result == "approved" && state.completedAt == some "2026-09-22") "status-only update"

  let (_, cycle) ← TaskDB.run path cycle
  let a ← idOf path "A"
  let b ← idOf path "B"
  check (cycle.edges == #[⟨b, a⟩, ⟨a, b⟩]) "cycle"
  check (toJson cycle == Json.arr #[nodeJson a "A" #[nodeJson b "B" #[refJson a "A"]]]) "cycle JSON"

  let ((a, b, join, self), shared) ← TaskDB.run path do
    let a ← push { name := "前提A" }
    let b ← push { name := "前提B" }
    let join ← push { name := "合流" } [] [a, b]
    let self ← push { name := "独立した循環" }
    addEdge self self
    return (a, b, join, self)
  check (toJson shared == Json.arr #[nodeJson a "前提A" #[nodeJson join "合流"],
    nodeJson b "前提B" #[refJson join "合流"],
    nodeJson self "独立した循環" #[refJson self "独立した循環"]]) "shared and disconnected JSON"

  let quoted := "日本語 ' ; DROP TABLE task_states; --\n"
  let (quoteId, _) ← TaskDB.run path (push { name := quoted })
  let expected : TaskState := { status := .Pending, result := "引用 \" と改行\n" }
  TaskDB.setState path quoteId expected
  check ((← TaskDB.getState path quoteId) == expected) "parameter binding and JSON roundtrip"

  let db ← SQLite.open path
  db.exec "INSERT INTO task_states(name, state) VALUES ('unread', '\"not a state\"')"
  let (_, lazyGraph) ← TaskDB.run path do
    if (← getTaskStatus "設計") == .Done then
      discard (getTaskStatus "unread")
    else
      pushU { name := "選ばれた枝" }
  check (names lazyGraph == #["選ばれた枝"]) "unselected read must not run"
  expectFailure (discard (TaskDB.run path do
    let id ← push { name := "rollback" }
    addEdge id 999999)) "invalid edge"
  check (!(← registered path "rollback")) "rollback registration"
  let tables ← db.prepare "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'"
  let mut tableNames := #[]
  while ← tables.step do tableNames := tableNames.push (← tables.columnText 0)
  check (tableNames == #["task_states"]) "no graph tables"

private def migrationTest (path : System.FilePath) : IO Unit := do
  let db ← SQLite.open path
  db.exec "CREATE TABLE task_states (name TEXT PRIMARY KEY NOT NULL, state TEXT NOT NULL)"
  let insert ← db.prepare "INSERT INTO task_states(rowid, name, state) VALUES (42, ?, ?)"
  insert.bindText 1 "既存タスク"
  let expected : TaskState := { status := .Done, result := "移行前の結果" }
  insert.bindText 2 (toJson expected).compress
  insert.exec
  expectFailure (discard (TaskDB.getTasks path)) "reads must not migrate schema"
  let (id, _) ← TaskDB.run path (push { name := "既存タスク" })
  check (id == 42 && (← TaskDB.getState path id) == expected) "migration preserves row and state"
  let (newId, _) ← TaskDB.run path do
    discard (push { name := "既存タスク" })
    push { name := "追加タスク" }
  check (newId > id) "migration sequence"
  let (again, _) ← TaskDB.run path (push { name := "既存タスク" })
  check (again == id && (← TaskDB.getTasks path).size == 1) "migration and pruning"

private def snapshotTest (path : System.FilePath) : IO Unit := do
  let original : Task := {
    name := "snapshot"
    tags := [.Rust, .«読み物» (.path "/tmp/book"), .Youtube "https://example.com"]
    assign := some "担当"
    links := ["https://example.com", "引用'\n"]
    plannedStart := some "2026-09-23"
    plannedEnd := some "2026-10-01"
    details := "詳細\n全文" }
  let ((id, removed), _) ← TaskDB.run path do
    let id ← push original
    let removed ← push { name := "removed" }
    return (id, removed)
  check (toJson (← TaskDB.getTask path id).toTask == toJson original) "all task fields roundtrip"
  let state : TaskState := { status := .Done, completedAt := some "2026-09-23", result := "保持" }
  TaskDB.setState path id state
  let updated : Task := { original with
    tags := [], assign := none, links := []
    plannedStart := none, plannedEnd := none, details := "更新" }
  let (same, _) ← TaskDB.run path do
    let id ← push updated
    discard (push original)
    return id
  let record ← TaskDB.getTask path same
  check (same == id && record.name == original.name && record.state == state) "intersection preserves identity and state"
  check (toJson record.toTask == toJson updated) "metadata replaced including cleared fields; first definition wins"
  expectFailure (discard (TaskDB.getTask path removed)) "A minus B deleted"
  let before ← TaskDB.getTasks path
  expectFailure (discard (TaskDB.run path do
    discard (push original)
    let newId ← push { name := "failed" }
    addEdge newId 999999)) "failed snapshot"
  check ((← TaskDB.getTasks path) == before) "failed snapshot preserves metadata, states and membership"
  let (readState, readGraph) ← TaskDB.run path (getTaskState original.name)
  check (readState == state && readGraph.nodes.isEmpty) "state-only reads remain reachable"
  check (toJson (← TaskDB.getTask path id).toTask == toJson updated) "state-only reads preserve full metadata"
  let (readThenAdded, _) ← TaskDB.run path do
    discard (getTaskState original.name)
    push original
  check (readThenAdded == id && toJson (← TaskDB.getTask path id).toTask == toJson original)
    "definition after state read replaces metadata"
  let (_, _) ← TaskDB.run path (pure () : TaskProg Unit)
  check ((← TaskDB.getTasks path).isEmpty) "empty snapshot deletes all tasks"
  let (fresh, _) ← TaskDB.run path (push original)
  check (fresh > removed && (← TaskDB.getState path fresh) == ({} : TaskState)) "reappearance has fresh ID and state"

private def previousSchemaTest (path : System.FilePath) : IO Unit := do
  let db ← SQLite.open path
  db.exec "CREATE TABLE task_states (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT UNIQUE NOT NULL, state TEXT NOT NULL)"
  let insert ← db.prepare "INSERT INTO task_states(id, name, state) VALUES (77, 'existing', ?)"
  let state : TaskState := { status := .Progress 1 3, result := "keep" }
  insert.bindText 1 (toJson state).compress
  insert.exec
  let task : Task := { name := "existing", details := "移行時の定義", tags := [.Lean4] }
  let (id, _) ← TaskDB.run path (push task)
  let record ← TaskDB.getTask path id
  check (id == 77 && record.state == state && toJson record.toTask == toJson task) "three-column migration"

private def nestedSchemaTest (path : System.FilePath) : IO Unit := do
  let db ← SQLite.open path
  db.exec "CREATE TABLE task_states (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT UNIQUE NOT NULL,
    task TEXT NOT NULL, state TEXT NOT NULL)"
  let task : Task := {
    name := "nested", tags := [.Rust], assign := some "担当"
    links := ["link"], plannedStart := some "start", plannedEnd := some "end", details := "本文" }
  let state : TaskState := { status := .Done, result := "結果", completedAt := some "date" }
  let insert ← db.prepare "INSERT INTO task_states(id, name, task, state) VALUES (80, 'nested', ?1, ?2)"
  insert.bindText 1 (toJson task).compress
  insert.bindText 2 (toJson state).compress
  insert.exec
  db.exec "UPDATE sqlite_sequence SET seq = 100 WHERE name = 'task_states'"
  expectFailure (discard (TaskDB.run path do
    discard (getTaskState "nested")
    addEdge 80 999)) "migration rollback"
  let columns ← db.prepare "SELECT COUNT(*) FROM pragma_table_info('task_states') WHERE name = 'task'"
  discard columns.step
  check ((← columns.columnInt 0) == 1) "failed migration preserves old schema"
  discard columns.step
  discard (TaskDB.run path (getTaskState "nested"))
  let record ← TaskDB.getTask path 80
  check (toJson record.toTask == toJson task && record.state == state) "nested migration preserves all fields"
  let columns ← db.prepare "SELECT COUNT(*) FROM pragma_table_info('task_states') WHERE name = 'task'"
  discard columns.step
  check ((← columns.columnInt 0) == 0) "nested column removed"
  discard columns.step
  let (id, _) ← TaskDB.run path do
    discard (getTaskState "nested")
    push { name := "new" }
  check (id > 100) "migration preserves autoincrement high water"

def main (args : List String) : IO UInt32 := do
  if let "--cli" :: cliArgs := args then
    return ← TaskManager.cli (do workflow; cycle) cliArgs
  try
    let [path] := args | throw <| IO.userError "Usage: taskdb_tests NEW_DB_PATH"
    let legacy := System.FilePath.mk (path ++ ".legacy")
    if (← System.FilePath.pathExists path) || (← legacy.pathExists) then
      throw <| IO.userError "Use a new database path for tests"
    tests path
    migrationTest legacy
    snapshotTest (path ++ ".snapshot")
    previousSchemaTest (path ++ ".previous")
    nestedSchemaTest (path ++ ".nested")
    IO.println "All taskdb integration tests passed."
    return (0 : UInt32)
  catch e =>
    (← IO.getStderr).putStrLn e.toString
    return (1 : UInt32)
