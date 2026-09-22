import TaskManager
import ExampleTasks

def main (args : List String) : IO UInt32 :=
  TaskManager.cli TaskManager.Examples.tasks args
