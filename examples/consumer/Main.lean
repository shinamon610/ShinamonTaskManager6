import TaskManager

open TaskManager

def tasks : TaskProg Unit := do
  let draft ← push { name := "利用側の下書き" }
  if (← getTaskStatus "利用側の下書き") == .Done then
    pushU { name := "利用側の公開" } [] [draft]

def main (args : List String) : IO UInt32 :=
  TaskManager.cli tasks args
