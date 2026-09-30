import TaskManager.Model

namespace TaskManager

/-- 操作をデータとして表現する initial encoding。任意の IO を持ち込む操作はない。 -/
inductive TaskProg (Tag : Type) (α : Type) where
  | pure : α → TaskProg Tag α
  | readState : String → (TaskState → TaskProg Tag α) → TaskProg Tag α
  | addTask : MyTask Tag → (NodeId → TaskProg Tag α) → TaskProg Tag α
  | addEdge : NodeId → NodeId → TaskProg Tag α → TaskProg Tag α

def TaskProg.bind (program : TaskProg Tag α) (next : α → TaskProg Tag β) : TaskProg Tag β :=
  match program with
  | .pure value => next value
  | .readState name cont => .readState name (fun state => (cont state).bind next)
  | .addTask task cont => .addTask task (fun node => (cont node).bind next)
  | .addEdge source target cont => .addEdge source target (cont.bind next)

instance : Monad (TaskProg Tag) where
  pure := TaskProg.pure
  bind := TaskProg.bind

def getTaskState (name : String) : TaskProg Tag TaskState :=
  .readState name .pure

def getTaskStatus (name : String) : TaskProg Tag Status := do
  return (← getTaskState name).status

def addTask (task : MyTask Tag) : TaskProg Tag NodeId :=
  .addTask task .pure

/-- source が依存する子 target を結ぶ。両方とも先に追加したノードを指定する。 -/
def addEdge (source target : NodeId) : TaskProg Tag Unit :=
  .addEdge source target (.pure ())

/-- 既存の push と同様、子を構築してから親を追加する。 -/
def push (task : MyTask Tag) (children : List (TaskProg Tag NodeId) := [])
    (refs : List NodeId := []) : TaskProg Tag NodeId := do
  let kids ← children.mapM id
  let parent ← addTask task
  for child in kids ++ refs do
    addEdge parent child
  return parent

def pushU (task : MyTask Tag) (children : List (TaskProg Tag NodeId) := [])
    (refs : List NodeId := []) : TaskProg Tag Unit := do
  discard (push task children refs)

end TaskManager
