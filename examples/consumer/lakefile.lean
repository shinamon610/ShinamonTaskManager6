import Lake
open Lake DSL

package ConsumerExample
require ShinamonTaskManager6 from "../.."

@[default_target]
lean_exe todo where
  root := `Main
