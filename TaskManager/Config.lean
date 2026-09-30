import Lean

namespace TaskManager

structure TaskConfig where
  csvPath : String
deriving Lean.FromJson

/-- 相対 DB パスは設定ファイルのあるディレクトリを基準に解決する。 -/
def TaskConfig.loadDatabasePath (file : System.FilePath) : IO System.FilePath := do
  let text ← IO.FS.readFile file
  let config ← match Lean.Json.parse text >>= (Lean.fromJson? (α := TaskConfig)) with
    | .ok config => pure config
    | .error message => throw <| IO.userError s!"Invalid config {file}: {message}"
  if config.csvPath.isEmpty then
    throw <| IO.userError s!"Invalid config {file}: csvPath must not be empty"
  let path := System.FilePath.mk config.csvPath
  return if path.isAbsolute then path else file.parent.getD "." / path

end TaskManager
