import TaskManager.Tag

namespace TaskManager

open Lean

/-- ソースで定義するタスク。同一性は name の完全一致。日付は ISO 8601 文字列。 -/
structure Task where
  name : String
  tags : List MyTag := []
  assign : Option String := none
  links : List String := []
  plannedStart : Option String := none
  plannedEnd : Option String := none
  details : String := ""
deriving ToJson

instance : BEq Task where
  beq a b := a.name == b.name

instance : Hashable Task where
  hash task := hash task.name

inductive Status where
  | NotStarted
  | Doing
  | Pending
  | Done
  | Progress (current total : Nat)
deriving BEq, Repr, ToJson, FromJson

/-- DB が管理する情報。タスク定義には埋め込まない。 -/
structure TaskState where
  status : Status := .NotStarted
  completedAt : Option String := none
  result : String := ""
deriving BEq, Repr, ToJson, FromJson

/-- DB が自動採番する永続的なタスク ID。ソースでは手書きしない。 -/
abbrev NodeId := Nat

structure TaskRecord where
  id : NodeId
  name : String
  state : TaskState
deriving BEq, ToJson

structure Node where
  id : NodeId
  task : Task
  state : TaskState
deriving ToJson

structure Edge where
  source : NodeId
  target : NodeId
deriving BEq, ToJson

/-- 内部表現。JSON では依存先から後続へ dependents の入れ子で表示する。 -/
structure Graph where
  nodes : Array Node := #[]
  edges : Array Edge := #[]

private partial def renderNode (graph : Graph) (node : Node) : StateM (List NodeId) Json := do
  let fields := [("id", toJson node.id), ("name", toJson node.task.name)]
  if (← get).contains node.id then
    return Json.mkObj fields
  modify (node.id :: ·)
  let mut dependents := #[]
  for edge in graph.edges do
    if edge.target == node.id then
      if let some dependent := graph.nodes.find? (·.id == edge.source) then
        dependents := dependents.push (← renderNode graph dependent)
  return Json.mkObj (fields ++ [("dependents", .arr dependents)])

/--
依存先を持たないタスクから後続へ展開する（既存 toEdges と同じ向き）。
再登場するノードは id/name のみの参照。
根のない循環成分も、未表示のノードを入口にして必ず出力する。
-/
def Graph.toDependencyJson (graph : Graph) : Json := Id.run do
  let render : StateM (List NodeId) Json := do
    let mut roots := #[]
    for node in graph.nodes do
      if !(graph.edges.any (·.source == node.id)) then
        roots := roots.push (← renderNode graph node)
    for node in graph.nodes do
      if !(← get).contains node.id then
        roots := roots.push (← renderNode graph node)
    return .arr roots
  return render.run [] |>.fst

instance : ToJson Graph where
  toJson := Graph.toDependencyJson

end TaskManager
