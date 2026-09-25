# ShinamonTaskManager6

Lean のタスク定義を initial encoding の `TaskProg` として記述し、SQLite の状態をオンデマンドに読みながらグラフを構築するライブラリ。
`TaskManager.cli tasks args` に利用側の定義を渡す。ライブラリ自身は特定の TODO やサンプルを知らない。

## ビルド

```sh
cd ~/Projects/ShinamonTaskManager6
nix develop
lake build
```

`lake build` でライブラリをビルドする。タスク定義と実行入口は利用側の repo に置く。

## 利用側のコード

```lean
import TaskManager

open TaskManager

def tasks : TaskProg Unit := do
  pushU { name := "テスト" } [
    push { name := "実装" } [
      push { name := "設計", tags := [.Programing] }
    ]
  ]

def main (args : List String) : IO UInt32 :=
  TaskManager.cli tasks args
```

`pushU 親 [push 子 …]` の入れ子が依存関係の木になる。子は親の前提タスクで、通常はノード ID を変数に束縛する必要がない。共有する既存ノードは第3引数の `refs` に渡し、循環は `addEdge` で結べる。
`TaskProg` は帰納型で操作と続きを表し、`Monad` により `do` / `if` を使える。任意の IO を埋め込む操作はない。
`getTaskStatus` / `getTaskState` に到達して初めて DB を読み、その結果で続きを選ぶ。未選択の分岐は実行しない。
複数ファイルのタスク群は、利用側の `tasks` で呼び出して合成する。

利用側の `lakefile.lean` に GitHub の依存を追加する（ユーザー名と revision は公開先に合わせて置き換える）。上記のコードは利用側の `Main.lean` に置く。

```lean
import Lake
open Lake DSL

package MyTodos
require ShinamonTaskManager6 from git
  "https://github.com/USER/ShinamonTaskManager6.git" @ "REVISION"

@[default_target]
lean_exe todo where
  root := `Main
```

利用側の `lean-toolchain` は `leanprover/lean4:v4.31.0` に合わせる。利用側の repo で `lake update`、`lake build` を実行し、以下の設定ファイルを置いて `lake exe todo graph` で起動する。引数なしは `graph` と同じ。

## 設定・コマンド

カレントディレクトリの `taskdb.json` を読む。

```json
{"sqlitePath": "tasks.sqlite3"}
```

相対 DB パスは設定ファイルの場所を基準にする。別設定は `--config /path/to/taskdb.json` をコマンドの前に指定する。
DB は必ず設定ファイルの `sqlitePath` を使う。コマンド引数での DB パス指定は受け付けない。設定がない・不正な場合はエラーにする。

| コマンド | 動作 |
| --- | --- |
| `graph` | ソースの定義を実行してグラフを JSON 出力 |
| `gets` | DB 内の全タスクを ID 順に JSON 配列で出力 |
| `get ID` | 1件の ID・名前・状態を出力 |
| `set ID ns/doing/pending` | 状態を更新（3つのうち1つを指定） |
| `set ID progress CURRENT TOTAL` | 進捗を更新 |
| `set ID done [RESULT]` | 完了にして UTC の完了日時を自動設定 |

結果に空白がある場合は引用符で囲む。結果省略時は既存結果を保持し、空文字を渡すと消去する。done の再実行は完了日時も更新する。他の状態への更新では結果と完了日時を保持する。
`set-state` コマンドは削除済み。`get` / `gets` は読み取り専用。`set` も未登録 ID や存在しない DB を新規作成しない。

CLI の文字列引数は入口の `Cli.parse` で `Command` / `DatabaseSource` を持つ `Request` に変換する。ID・状態・進捗もここで解析し、設定解決とコマンド実行は ADT で分岐する。

## データとグラフ

- `Task` は名前・タグ・担当・リンク・予定日・詳細を持つ独自型。`TaskState` は状態・完了日・結果。
- DB は `task_states(id, name, tags, assign, links, plannedStart, plannedEnd, details, state)`。Task の各フィールドをそのまま列として保存する。配列の tags・links と state は JSON。グラフや辺は保存しない。
- `get` / `gets` は Task の全フィールドに `id`・`state` を加えたレコードを返す。`task` の入れ子や名前の重複はない。
- ソース実行で名前を照合し、同名なら DB ID と状態を再利用する。ID は自動採番で、手書き不要。改名は別タスク。
- 初めて状態を読む、またはノードを追加したときに未登録の名前を NotStarted で登録する。状態取得だけではグラフにノードを追加しない。
- 同じ実行で同名を追加すると同一ノードになる。定義情報はその実行の最初の追加を採用する。
- `run` は今回到達した集合 B に DB を同期する。以前の集合 A に対し、A−B は削除、A∩B は ID・名前・状態を保持して定義情報を更新、B−A は新規登録する。空の集合なら全件削除する。
- 到達集合には状態を読むだけの名前も含む。その場合、既存の定義情報を保持し、新規なら名前以外を既定値で登録する。後でノードを追加した場合はその定義情報を保存する。
- 一回の実行はスキーマ移行・登録・定義更新・削除を含むトランザクション。失敗時はロールバックし、実行中の他接続の更新は待機する。
- JSON は依存先から後続へ `dependents` を入れ子にする。タスク情報は DB ID と名前のみ。
- 循環・共有による再登場は ID と名前だけの参照。根のない循環も出力する。
- 到達しなくなったタスクの履歴は保持しない。削除後に同名が再登場した場合は新しい ID と初期状態で登録する。
- 旧形式の DB は `graph` 時に状態を保持して移行する。get/gets/set は移行しない。

`set` は現在のタスク定義からグラフを構築し、以下の更新をエラーにする。

- 現在のグラフにないタスクへの更新。
- 直接の依存先に未完了のタスクがある場合の更新（自己依存や未完了の循環も含む）。
- Done から未完了の状態への変更。Done の再実行は許可する。

未完了の状態間の変更は、上記の条件を満たせば許可する。Progress の CURRENT は 0 以上 TOTAL 以下、TOTAL は正数とする。
検証と更新は同じトランザクションで行い、失敗時はグラフ構築中の登録もロールバックする。
`set` の検証中も到達した定義情報を保存するが、集合の削除同期は `run`（CLI の引数なし実行 / `graph`）で行う。
ライブラリの低水準 API `setState` / `setStatus` / `setDone` はグラフを検証しない。CLI と同じ検証には `setTaskStatus` にタスク定義を渡す。

## ファイル

- `TaskManager.lean`: 公開 import 入口
- `TaskManager/Model.lean`, `Tag.lean`: データ型
- `TaskManager/Program.lean`: 操作型・Monad・push 等
- `TaskManager/DB.lean`: SQLite 実行器と状態更新
- `TaskManager/Config.lean`, `Cli.lean`: 設定と再利用できる CLI

## テスト

```sh
lake build taskdb_tests
taskdb_test_dir=$(mktemp -d)
.lake/build/bin/taskdb_tests "$taskdb_test_dir/tasks.sqlite3"
python3 tests/test_taskdb_config.py
```

実 DB による分岐、名前と ID の保持、移行、循環・共有 JSON、ロールバック、設定、CLI を検証する。
