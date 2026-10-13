import TaskManager.Model

namespace TaskManager.Graph

private def reachable (graph : Graph Tag) (start : NodeId)
    (reverse : Bool := false) : Std.HashSet NodeId := Id.run do
  let mut seen : Std.HashSet NodeId := ({} : Std.HashSet NodeId).insert start
  for _ in [:graph.nodes.size] do
    let previous := seen
    for edge in graph.edges do
      let source := if reverse then edge.target else edge.source
      let target := if reverse then edge.source else edge.target
      if previous.contains source then
        seen := seen.insert target
    if seen.size == previous.size then break
  return seen

/-- 指定ノードの SCC。順方向・逆方向の到達集合の共通部分。 -/
private def component (graph : Graph Tag) (id : NodeId) : Std.HashSet NodeId :=
  let forward := reachable graph id
  let backward := reachable graph id true
  graph.nodes.foldl (fun ids node =>
    if forward.contains node.id && backward.contains node.id then ids.insert node.id else ids) {}

/-- 指定された未完了タスクの完了条件を検証する。完了済みタスクの再完了は許可する。 -/
def checkDoneable (graph : Graph Tag) (id : NodeId) : Except String Unit := do
  let some node := graph.nodes.find? (·.id == id)
    | throw s!"Task {id} is not in the current graph"
  if node.state.status == .Done then return ()
  let done := graph.nodes.foldl (fun (ids : Std.HashSet NodeId) node =>
    if node.state.status == .Done then ids.insert node.id else ids) {}
  let original := component graph id
  -- ① 元の SCC が依存する外部 SCC は、その全ノードの完了が必要。
  let mut checked : Std.HashSet NodeId := {}
  for edge in graph.edges do
    if original.contains edge.source && !original.contains edge.target &&
        !checked.contains edge.target then
      let prerequisite := component graph edge.target
      for dependency in graph.nodes do
        if prerequisite.contains dependency.id then
          checked := checked.insert dependency.id
          unless done.contains dependency.id do
            throw s!"Task {id} requires completed prerequisite component: {dependency.id} ({dependency.task.name})"
  let unfinished : Graph Tag := {
    nodes := graph.nodes.filter (fun node => !done.contains node.id)
    edges := graph.edges.filter (fun edge => !done.contains edge.source && !done.contains edge.target) }
  let remaining := component unfinished id
  -- ② 未完了 SCC の外に未完了の依存先があれば、完了不可。
  for edge in unfinished.edges do
    if remaining.contains edge.source && !remaining.contains edge.target then
      throw s!"Task {id} requires completed dependency {edge.target} of its unfinished component"
  -- ③ 完了済み依存先を持つ入口があれば、対象自身も入口であること。
  let isEntry := fun source =>
    graph.edges.any (fun edge => edge.source == source && done.contains edge.target)
  let hasEntry := graph.nodes.any (fun node => remaining.contains node.id && isEntry node.id)
  if hasEntry && !isEntry id then
    throw s!"Task {id} is not an entry of its unfinished component"

end TaskManager.Graph
