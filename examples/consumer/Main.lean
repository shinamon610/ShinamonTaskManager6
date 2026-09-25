import TaskManager

open TaskManager

def tasks : TaskProg Unit := do
  if (← getTaskStatus "利用側の下書き") == .Done then
    pushU { name := "利用側の公開" } [
      push { name := "利用側の下書き" }
    ]
  else
    pushU { name := "利用側の下書き" }

def main (args : List String) : IO UInt32 :=
  TaskManager.cli tasks args
