import TaskManager.DB
import TaskManager.Config

namespace TaskManager

open Lean

private def usage : String :=
  "Usage:\n  taskdb [--config FILE] [graph [DB]]\n  taskdb [--config FILE] gets [DB]\n  taskdb [--config FILE] get [DB] ID\n  taskdb [--config FILE] set [DB] ID not-started|doing|pending\n  taskdb [--config FILE] set [DB] ID done [RESULT]\n  taskdb [--config FILE] set [DB] ID progress CURRENT TOTAL\n\nDefault config: ./taskdb.json (sqlitePath, relative to the config file).\nAn explicit DB path overrides the config.\ndone records the current UTC time; omit RESULT to keep the existing result.\ngraph builds the graph using DB states and prints JSON.\ngets lists all registered tasks; get/set use their database IDs."
namespace Cli

/-- DB の指定方法。設定解決後に文字列の引数列を組み直さない。 -/
inductive DatabaseSource where
  | config (file : System.FilePath)
  | explicit (file : System.FilePath)

/-- 入力の解析を終えたコマンド。ID と状態は実行前に型へ変換する。 -/
inductive Command where
  | graph
  | gets
  | get (id : NodeId)
  | set (id : NodeId) (status : Status)
  | done (id : NodeId) (result : Option String)
  | help

structure Request where
  database : DatabaseSource
  command : Command

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

private def parseProgress (current total : String) : IO Status := do
  match current.toNat?, total.toNat? with
  | some c, some t =>
    if t == 0 || c > t then
      throw <| IO.userError "Progress requires 0 <= CURRENT <= TOTAL and TOTAL > 0"
    return .Progress c t
  | _, _ => throw <| IO.userError "Progress requires natural numbers"

/-- 外部の文字列表現を扱う境界。以降の設定解決・実行は ADT のみで分岐する。 -/
def parse (args : List String) : IO Request := do
  let (config, args) := match args with
    | "--config" :: file :: rest => (System.FilePath.mk file, rest)
    | _ => (System.FilePath.mk "taskdb.json", args)
  let defaultDB := DatabaseSource.config config
  match args with
  | []  => return ⟨defaultDB, .graph⟩
  | ["graph", path] => return ⟨.explicit path, .graph⟩
  | ["gets"] => return ⟨defaultDB, .gets⟩
  | ["gets", path] => return ⟨.explicit path, .gets⟩
  | ["get", id] => return ⟨defaultDB, .get (← parseId id)⟩
  | ["get", path, id] => return ⟨.explicit path, .get (← parseId id)⟩
  | ["set", id, status] => return ⟨defaultDB, .set (← parseId id) (← parseStatus status)⟩
  | ["set", id, "done", result] => return ⟨defaultDB, .done (← parseId id) (some result)⟩
  | ["set", path, id, status] => return ⟨.explicit path, .set (← parseId id) (← parseStatus status)⟩
  | ["set", path, id, "done", result] =>
    return ⟨.explicit path, .done (← parseId id) (some result)⟩
  | ["set", id, "progress", current, total] =>
    return ⟨defaultDB, .set (← parseId id) (← parseProgress current total)⟩
  | ["set", path, id, "progress", current, total] =>
    return ⟨.explicit path, .set (← parseId id) (← parseProgress current total)⟩
  | ["--help"] | ["-h"] => return ⟨defaultDB, .help⟩
  | _ => throw <| IO.userError usage

def DatabaseSource.resolve : DatabaseSource → IO System.FilePath
  | .config file => TaskConfig.loadDatabasePath file
  | .explicit file => pure file

def Request.execute (request : Request) (program : TaskProg Unit) : IO Unit := do
  let withDatabase (action : System.FilePath → IO Unit) : IO Unit := do
    action (← request.database.resolve)
  match request.command with
  | .help => IO.println usage
  | .graph => withDatabase fun path => do IO.println (← TaskDB.runJson path program).pretty
  | .gets => withDatabase fun path => do IO.println (toJson (← TaskDB.getTasks path)).pretty
  | .get id => withDatabase fun path => do IO.println (toJson (← TaskDB.getTask path id)).pretty
  | .set id status => withDatabase fun path => TaskDB.setTaskStatus path program id status
  | .done id result => withDatabase fun path => TaskDB.setTaskStatus path program id .Done result

end Cli

def cli (program : TaskProg Unit) (args : List String) : IO UInt32 := do
  try
    (← Cli.parse args).execute program
    return 0
  catch e =>
    (← IO.getStderr).putStrLn e.toString
    return 1

end TaskManager
