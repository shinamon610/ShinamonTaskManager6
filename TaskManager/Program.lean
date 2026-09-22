import TaskManager.Model

namespace TaskManager

/-- 操作をデータとして表現する initial encoding。任意の IO を持ち込む操作はない。 -/
inductive TaskProg (α : Type) where
  | pure : α → TaskProg α
  | readState : String → (TaskState → TaskProg α) → TaskProg α
  | addTask : Task → (NodeId → TaskProg α) → TaskProg α
  | addEdge : NodeId → NodeId → TaskProg α → TaskProg α

def TaskProg.bind (program : TaskProg α) (next : α → TaskProg β) : TaskProg β :=
  match program with
  | .pure value => next value
  | .readState name cont => .readState name (fun state => (cont state).bind next)
  | .addTask task cont => .addTask task (fun node => (cont node).bind next)
  | .addEdge source target cont => .addEdge source target (cont.bind next)

instance : Monad TaskProg where
  pure := TaskProg.pure
  bind := TaskProg.bind

def getTaskState (name : String) : TaskProg TaskState :=
  .readState name .pure

def getTaskStatus (name : String) : TaskProg Status := do
  return (← getTaskState name).status

def addTask (task : Task) : TaskProg NodeId :=
  .addTask task .pure

/-- source が依存する子 target を結ぶ。両方とも先に追加したノードを指定する。 -/
def addEdge (source target : NodeId) : TaskProg Unit :=
  .addEdge source target (.pure ())

/-- 既存の push と同様、子を構築してから親を追加する。 -/
def push (task : Task) (children : List (TaskProg NodeId) := [])
    (refs : List NodeId := []) : TaskProg NodeId := do
  let kids ← children.mapM id
  let parent ← addTask task
  for child in kids ++ refs do
    addEdge parent child
  return parent

def pushU (task : Task) (children : List (TaskProg NodeId) := [])
    (refs : List NodeId := []) : TaskProg Unit := do
  discard (push task children refs)

end TaskManager
