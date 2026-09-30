import TaskManager

open Lean TaskManager

-- タグはライブラリではなく利用側（ここではテスト）が定義する。
private inductive TestSource where
  | path : System.FilePath → TestSource
  deriving ToJson, FromJson

private inductive TestTag where
  | work
  | priority : Nat → TestTag
  | resource : TestSource → TestTag
  | url : String → TestTag
  deriving ToJson, FromJson

private def workflow : TaskProg TestTag Unit := do
  let design : MyTask TestTag := .new "設計" [.work] (details := "実装の方針を決める")
  if (← getTaskStatus "設計") == .Done then
    if (← getTaskStatus "実装") == .Done then
      pushU { name := "テスト", tags := [.work] } [
        push { name := "実装", tags := [.work] } [push design]
      ]
    else
      pushU { name := "実装", tags := [.work] } [push design]
  else
    pushU (.new "設計の見直し") [push design]

private def cycle : TaskProg TestTag Unit := do
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

private def names (graph : Graph TestTag) := graph.nodes.map (·.task.name)

private def idOf (path : System.FilePath) (name : String) : IO NodeId := do
  let some record := (← TaskDB.getTasks (Tag := TestTag) path).find? (·.name == name)
    | throw <| IO.userError s!"Missing test task: {name}"
  return record.id

private def refJson (id : NodeId) (name : String) (status : Status := .NotStarted) : Json :=
  Json.mkObj [("id", toJson id), ("name", toJson name), ("status", toJson status)]

private def nodeJson (id : NodeId) (name : String) (dependents : Array Json := #[])
    (status : Status := .NotStarted) : Json :=
  (refJson id name status).mergeObj (Json.mkObj [("dependents", .arr dependents)])

private def registered (path : System.FilePath) (name : String) : IO Bool := do
  return (← TaskDB.getTasks (Tag := Json) path).any (·.name == name)

private def tests (path : System.FilePath) : IO Unit := do
  expectFailure (discard (TaskDB.getTask (Tag := TestTag) path "!!!!!")) "get must not create DB"
  expectFailure (discard (TaskDB.getTasks (Tag := TestTag) path)) "gets must not create DB"
  expectFailure (TaskDB.setStatus path "!!!!!" .Done) "set must not create DB"
  expectFailure (TaskDB.setState path "!!!!!" {}) "set-state must not create DB"
  check (!(← path.pathExists)) "read/update must leave missing DB absent"

  let (_, emptyGraph) ← TaskDB.run (Tag := TestTag) path (pure () : TaskProg TestTag Unit)
  check ((← TaskDB.getTasks (Tag := TestTag) path).isEmpty) "gets on empty database"
  check (toJson emptyGraph == Json.arr #[]) "empty JSON"
  expectFailure (discard (TaskDB.getTask (Tag := TestTag) path "!!!!!")) "unknown get"
  expectFailure (TaskDB.setStatus path "!!!!!" .Done) "unknown set"
  expectFailure (TaskDB.setState path "!!!!!" {}) "unknown set-state"
  check ((← TaskDB.getTasks (Tag := TestTag) path).isEmpty) "unknown IDs must not register"
  expectFailure (TaskDB.setState path "" {}) "zero ID"
  expectFailure (TaskDB.setState path "toolong" {}) "overflow ID"

  let (status, onlyState) ← TaskDB.run (Tag := TestTag) path (getTaskStatus "状態のみ")
  check (status == .NotStarted && onlyState.nodes.isEmpty) "on-demand state read"
  let stateOnlyId ← idOf path "状態のみ"
  TaskDB.setState path stateOnlyId {}
  TaskDB.setState path stateOnlyId {}
  check ((← TaskDB.getState path stateOnlyId) == ({} : TaskState)) "idempotent update"

  let (_, first) ← TaskDB.run (Tag := TestTag) path workflow
  check (names first == #["設計", "設計の見直し"]) "initial branch"
  check (!(← registered path "実装") && !(← registered path "テスト")) "unselected registration"
  let designId ← idOf path "設計"
  TaskDB.setState path designId { status := .Done, result := "approved", completedAt := some "2026-09-22" }
  let (_, second) ← TaskDB.run (Tag := TestTag) path workflow
  check (names second == #["設計", "実装"]) "DB branch"
  check (!(← registered path "テスト")) "nested unselected branch"
  let implementId ← idOf path "実装"
  expectFailure (TaskDB.setStatus path implementId (.Progress 3 2)) "invalid progress"
  expectFailure (TaskDB.setState path implementId { status := .Progress 0 0 }) "zero total"
  TaskDB.setStatus path implementId (.Progress 9223372036854775808 9223372036854775808)
  check ((← TaskDB.getState path implementId).status == .Progress 9223372036854775808 9223372036854775808) "large natural progress roundtrip"
  let beforeInvalid ← TaskDB.getState path implementId
  expectFailure (TaskDB.setState path implementId { status := .Progress 4 3 }) "invalid current and total"
  check ((← TaskDB.getState path implementId) == beforeInvalid) "invalid update preserves state"
  TaskDB.setStatus path implementId (.Progress 2 5)
  let (_, progress) ← TaskDB.run (Tag := TestTag) path workflow
  check (progress.nodes[1]?.map (·.state.status) == some (.Progress 2 5)) "progress persistence"
  TaskDB.setStatus path implementId .Done
  let (_, third) ← TaskDB.run (Tag := TestTag) path workflow
  let testId ← idOf path "テスト"
  check (third.edges == #[⟨implementId, designId⟩, ⟨testId, implementId⟩]) "edge direction"
  check (toJson third == Json.arr #[nodeJson designId "設計" #[nodeJson implementId "実装" #[nodeJson testId "テスト"] .Done] .Done])
    "JSON direction and persistent IDs"

  let records ← TaskDB.getTasks (Tag := TestTag) path
  check (!(records.any (·.name == "設計の見直し"))) "run removes tasks outside reached set"
  for record in records do
    check ((← TaskDB.getTask (Tag := TestTag) path record.id) == record) "gets is get for every row"

  let (_, changed) ← TaskDB.run (Tag := TestTag) path do
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

  let (_, cycle) ← TaskDB.run (Tag := TestTag) path cycle
  let a ← idOf path "A"
  let b ← idOf path "B"
  check (cycle.edges == #[⟨b, a⟩, ⟨a, b⟩]) "cycle"
  check (toJson cycle == Json.arr #[nodeJson a "A" #[nodeJson b "B" #[refJson a "A"]]]) "cycle JSON"

  let ((a, b, join, self), shared) ← TaskDB.run (Tag := TestTag) path do
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
  let (quoteId, _) ← TaskDB.run (Tag := TestTag) path (push { name := quoted })
  let expected : TaskState := { status := .Pending, result := "引用 \" と改行\n" }
  TaskDB.setState path quoteId expected
  check ((← TaskDB.getState path quoteId) == expected) "CSV state roundtrip"

  discard (TaskDB.run (Tag := Json) path (push { name := "unread", tags := [toJson (123 : Nat)] }))
  let (_, lazyGraph) ← TaskDB.run (Tag := TestTag) path do
    if (← getTaskStatus "設計") == .Done then
      discard (getTaskStatus "unread")
    else
      pushU { name := "選ばれた枝" }
  check (names lazyGraph == #["選ばれた枝"]) "unselected read must not run"
  expectFailure (discard (TaskDB.run (Tag := TestTag) path do
    let id ← push { name := "rollback" }
    addEdge id "!!!!!")) "invalid edge"
  check (!(← registered path "rollback")) "rollback registration"

private def snapshotTest (path : System.FilePath) : IO Unit := do
  let original : TaskManager.MyTask TestTag := {
    name := "snapshot"
    tags := [.priority 2, .resource (.path "/tmp/book"), .url "https://example.com"]
    assign := some ""
    plannedStart := some "2026-09-23"
    plannedEnd := some "2026-10-01"
    details := "詳細\n全文" }
  let constructed := MyTask.new "snapshot" original.tags (some "")
    (some "2026-09-23") (some "2026-10-01") "詳細\n全文"
  check (toJson constructed == toJson original) "constructor preserves all definition fields"
  let ((id, removed), _) ← TaskDB.run (Tag := TestTag) path do
    let id ← push original
    let removed ← push { name := "removed" }
    return (id, removed)
  check (toJson (← TaskDB.getTask (Tag := TestTag) path id).toMyTask == toJson original) "all task fields roundtrip"
  let state : TaskState := { status := .Done, completedAt := some "2026-09-23", result := "保持" }
  TaskDB.setState path id state
  let updated : TaskManager.MyTask TestTag := { original with
    tags := [], assign := none
    plannedStart := none, plannedEnd := none, details := "更新" }
  let (same, _) ← TaskDB.run (Tag := TestTag) path do
    let id ← push updated
    discard (push original)
    return id
  let record ← TaskDB.getTask (Tag := TestTag) path same
  check (same == id && record.name == original.name && record.state == state) "intersection preserves identity and state"
  check (toJson record.toMyTask == toJson updated) "metadata replaced including cleared fields; first definition wins"
  expectFailure (discard (TaskDB.getTask (Tag := TestTag) path removed)) "A minus B deleted"
  let before ← TaskDB.getTasks (Tag := TestTag) path
  expectFailure (discard (TaskDB.run (Tag := TestTag) path do
    discard (push original)
    let newId ← push { name := "failed" }
    addEdge newId "!!!!!")) "failed snapshot"
  check ((← TaskDB.getTasks (Tag := TestTag) path) == before) "failed snapshot preserves metadata, states and membership"
  let (readState, readGraph) ← TaskDB.run (Tag := TestTag) path (getTaskState original.name)
  check (readState == state && readGraph.nodes.isEmpty) "state-only reads remain reachable"
  check (toJson (← TaskDB.getTask (Tag := TestTag) path id).toMyTask == toJson updated) "state-only reads preserve full metadata"
  let (readThenAdded, _) ← TaskDB.run (Tag := TestTag) path do
    discard (getTaskState original.name)
    push original
  check (readThenAdded == id && toJson (← TaskDB.getTask (Tag := TestTag) path id).toMyTask == toJson original)
    "definition after state read replaces metadata"
  let (_, _) ← TaskDB.run (Tag := TestTag) path (pure () : TaskProg TestTag Unit)
  check ((← TaskDB.getTasks (Tag := TestTag) path).isEmpty) "empty snapshot deletes all tasks"
  let (fresh, _) ← TaskDB.run (Tag := TestTag) path (push original)
  check (NodeId.isValid fresh && (← TaskDB.getState path fresh) == ({} : TaskState)) "reappearance has fresh ID and state"

private def alternateTagTest (path : System.FilePath) : IO Unit := do
  let task : TaskManager.MyTask String := { name := "文字列タグ", tags := ["自由なタグ", "引用'\n"] }
  let (id, _) ← TaskDB.run path (push task)
  check ((← TaskDB.getTask (Tag := String) path id).tags == task.tags) "independent tag type roundtrip"

private def csvAndIdTests (path : System.FilePath) : IO Unit := do
  let cells := #[#["", "日本語,引用\"", "line1\r\nline2", "\"", "末尾", ""]]
  check ((← IO.ofExcept (Csv.parse (Csv.render cells))) == cells) "CSV quoting and multiline roundtrip"
  check ((← IO.ofExcept (Csv.parse "a,b\r\nc,d\n")) == #[#["a", "b"], #["c", "d"]]) "CSV CRLF and LF"
  check ((Csv.parse "\"unterminated").toOption.isNone) "unterminated quote rejected"
  check ((Csv.parse "a\"b").toOption.isNone) "bare quote rejected"
  check ((Csv.parse "\"a\"x").toOption.isNone) "trailing quote junk rejected"
  let calls ← IO.mkRef (0 : Nat)
  let draw := do
    let n ← calls.get
    calls.set (n + 1)
    return if n < 2 then "aaaaa" else "bbbbb"
  let used : Std.HashSet NodeId := ({} : Std.HashSet NodeId).insert "aaaaa"
  let id ← TaskDB.freshId used draw
  check (id == "bbbbb" && (← calls.get) == 3) "ID collision retries"
  expectFailure (discard (TaskDB.run (Tag := TestTag) path do
    let id ← push { name := "failed creation" }
    addEdge id "!!!!!")) "invalid fresh graph"
  check (!(← path.pathExists)) "failed execution must not create CSV"
  let (_, graph) ← TaskDB.run (Tag := TestTag) path do
    for i in [0:500] do
      pushU (.new s!"task {i}")
  let ids := graph.nodes.map (·.id)
  check (ids.all NodeId.isValid) "five character IDs"
  check ((ids.foldl (fun (s : Std.HashSet String) id => s.insert id) {}).size == ids.size)
    "all registered IDs are unique"

def main (args : List String) : IO UInt32 := do
  if let "--cli" :: cliArgs := args then
    return ← TaskManager.cli (do workflow; cycle) cliArgs
  try
    let [path] := args | throw <| IO.userError "Usage: taskdb_tests NEW_DB_PATH"
    if (← System.FilePath.pathExists path) then
      throw <| IO.userError "Use a new database path for tests"
    csvAndIdTests (path ++ ".ids")
    tests path
    snapshotTest (path ++ ".snapshot")
    alternateTagTest (path ++ ".alternate")
    IO.println "All taskdb integration tests passed."
    return (0 : UInt32)
  catch e =>
    (← IO.getStderr).putStrLn e.toString
    return (1 : UInt32)
