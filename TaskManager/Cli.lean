import TaskManager.DB
import TaskManager.Config

namespace TaskManager

open Lean

private def usage : String :=
  "Usage:\n  taskdb [--config FILE] [graph [DB]]\n  taskdb [--config FILE] gets [DB]\n  taskdb [--config FILE] get [DB] ID\n  taskdb [--config FILE] set [DB] ID not-started|doing|pending\n  taskdb [--config FILE] set [DB] ID done [RESULT]\n  taskdb [--config FILE] set [DB] ID progress CURRENT TOTAL\n\nDefault config: ./taskdb.json (sqlitePath, relative to the config file).\nAn explicit DB path overrides the config.\ndone records the current UTC time; omit RESULT to keep the existing result.\ngraph builds the graph using DB states and prints JSON.\ngets lists all registered tasks; get/set use their database IDs."

private def resolveDatabase (config : System.FilePath) (args : List String) : IO (List String) := do
  match args with
  | [] | ["graph"] => return ["graph", (← TaskConfig.loadDatabasePath config).toString]
  | ["gets"] => return ["gets", (← TaskConfig.loadDatabasePath config).toString]
  | ["get", id] => return ["get", (← TaskConfig.loadDatabasePath config).toString, id]
  | ["set", id, status] => return ["set", (← TaskConfig.loadDatabasePath config).toString, id, status]
  | ["set", id, "done", result] =>
    return ["set", (← TaskConfig.loadDatabasePath config).toString, id, "done", result]
  | ["set", id, "progress", current, total] =>
    return ["set", (← TaskConfig.loadDatabasePath config).toString, id, "progress", current, total]
  | _ => return args

private def parseId (text : String) : IO NodeId := do
  if let some id := text.toNat? then
    if id > 0 && id <= 9223372036854775807 then return id
  throw <| IO.userError "ID must be a positive SQLite integer"

private def parseStatus (text : String) : IO Status :=
  match text with
  | "not-started" => pure .NotStarted
  | "doing" => pure .Doing
  | "pending" => pure .Pending
  | "done" => pure .Done
  | _ => throw <| IO.userError s!"Unknown status: {text}"

def cli (program : TaskProg Unit) (args : List String) : IO UInt32 := do
  try
    let (config, args) := match args with
      | "--config" :: file :: rest => (file, rest)
      | _ => ("taskdb.json", args)
    let args ← resolveDatabase config args
    match args with
    | ["graph", path] => IO.println (← TaskDB.runJson path program).pretty
    | ["gets", path] => IO.println (toJson (← TaskDB.getTasks path)).pretty
    | ["get", path, id] => IO.println (toJson (← TaskDB.getTask path (← parseId id))).pretty
    | ["set", path, id, status] => TaskDB.setStatus path (← parseId id) (← parseStatus status)
    | ["set", path, id, "done", result] => TaskDB.setDone path (← parseId id) (some result)
    | ["set", path, id, "progress", current, total] =>
      match current.toNat?, total.toNat? with
      | some c, some t =>
        if t == 0 || c > t then
          throw <| IO.userError "Progress requires 0 <= CURRENT <= TOTAL and TOTAL > 0"
        TaskDB.setStatus path (← parseId id) (.Progress c t)
      | _, _ => throw <| IO.userError "Progress requires natural numbers"
    | ["--help"] | ["-h"] => IO.println usage
    | _ => throw <| IO.userError usage
    return 0
  catch e =>
    (← IO.getStderr).putStrLn e.toString
    return 1

end TaskManager
