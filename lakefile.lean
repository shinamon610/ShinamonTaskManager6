import Lake
open Lake DSL

package ShinamonTaskManager6 where
  version := v!"0.1.0"

require leansqlite from git
  "https://github.com/leanprover/leansqlite" @ "v4.31.0"

@[default_target]
lean_lib TaskManager
lean_lib ExampleTasks

@[default_target]
lean_exe taskdb where
  root := `Main

lean_exe taskdb_tests where
  root := `TaskDBTests
