import Lean

namespace TaskManager.Csv

private inductive Mode where
  | start | plain | quoted | closed
  deriving BEq

/-- 引用符・カンマ・セル内の改行を扱う。LF と CRLF の両方を読み込む。 -/
def parse (text : String) : Except String (Array (Array String)) := do
  let mut rows := #[]
  let mut row := #[]
  let mut field := ""
  let mut mode := Mode.start
  let mut afterCR := false
  for c in text.toList do
    if afterCR && c == '\n' then
      afterCR := false
      continue
    afterCR := false
    if mode == .quoted then
      if c == '"' then mode := .closed else field := field.push c
    else if c == ',' then
      row := row.push field
      field := ""
      mode := .start
    else if c == '\n' || c == '\r' then
      rows := rows.push (row.push field)
      row := #[]
      field := ""
      mode := .start
      afterCR := c == '\r'
    else if c == '"' then
      if mode == .start then
        mode := .quoted
      else if mode == .closed then
        field := field.push c
        mode := .quoted
      else
        throw "Unexpected quote in unquoted CSV field"
    else
      if mode == .closed then throw "Unexpected character after closing CSV quote"
      field := field.push c
      mode := .plain
  if mode == .quoted then throw "Unterminated CSV quote"
  if mode != .start || !row.isEmpty then
    rows := rows.push (row.push field)
  return rows

private def quote (field : String) : String :=
  "\"" ++ field.replace "\"" "\"\"" ++ "\""

/-- 全セルを引用し、空文字・改行・引用符も失わずに保存する。 -/
def render (rows : Array (Array String)) : String :=
  String.join (rows.toList.map fun row =>
    String.intercalate "," (row.toList.map quote) ++ "\r\n")

end TaskManager.Csv
