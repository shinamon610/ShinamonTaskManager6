import TaskManager.Program

namespace TaskManager.Examples

/-- DB の状態を読んだ結果で、構築するグラフ自体が変わる。 -/
def workflow : TaskProg Unit := do
  let design ← push { name := "設計", tags := [.Programing], details := "実装の方針を決める" }
  if (← getTaskStatus "設計") == .Done then
    let implement ← push { name := "実装", tags := [.Programing] } [] [design]
    if (← getTaskStatus "実装") == .Done then
      pushU { name := "テスト", tags := [.Programing] } [] [implement]
  else
    pushU { name := "設計の見直し" } [] [design]

def cycle : TaskProg Unit := do
  let a ← push { name := "A" }
  let b ← push { name := "B" } [] [a]
  addEdge a b

/-- この実行ファイルが扱う全タスク。分割した定義はここで合成する。 -/
def tasks : TaskProg Unit := do
  workflow
  cycle

end TaskManager.Examples
