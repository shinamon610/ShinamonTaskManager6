import Lean

namespace TaskManager

open Lean

/-- ソースで定義するタスク。同一性は name の完全一致。日付は ISO 8601 文字列。 -/
structure MyTask (Tag : Type) where
  name : String
  tags : List Tag := []
  assign : Option String := none
  plannedStart : Option String := none
  plannedEnd : Option String := none
  details : String := ""
deriving ToJson, FromJson

/-- タグ型は利用側から推論する。タスクの定義情報だけを作り、状態は DB で管理する。 -/
def MyTask.new {Tag : Type} (name : String) (tags : List Tag := [])
    (operator : Option String := none)
    (plannedStart : Option String := none) (plannedEnd : Option String := none)
    (details : String := "") : MyTask Tag :=
  { name, tags, assign := operator, plannedStart, plannedEnd, details }

instance : BEq (MyTask Tag) where
  beq a b := a.name == b.name

instance : Hashable (MyTask Tag) where
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

structure TaskRecord (Tag : Type) extends MyTask Tag where
  id : NodeId
  state : TaskState
deriving ToJson

instance [ToJson Tag] : BEq (TaskRecord Tag) where
  beq a b := a.id == b.id && a.name == b.name &&
    toJson a.toMyTask == toJson b.toMyTask && a.state == b.state

structure Node (Tag : Type) where
  id : NodeId
  task : MyTask Tag
  state : TaskState
deriving ToJson

structure Edge where
  source : NodeId
  target : NodeId
deriving BEq, ToJson

/-- 内部表現。JSON では依存先から後続へ dependents の入れ子で表示する。 -/
structure Graph (Tag : Type) where
  nodes : Array (Node Tag) := #[]
  edges : Array Edge := #[]

private partial def renderNode (graph : Graph Tag) (node : Node Tag) : StateM (List NodeId) Json := do
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
def Graph.toDependencyJson (graph : Graph Tag) : Json := Id.run do
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

instance : ToJson (Graph Tag) where
  toJson := Graph.toDependencyJson

end TaskManager
