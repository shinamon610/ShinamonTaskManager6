# ShinamonTaskManager6

Lean のタスク定義を initial encoding の `TaskProg` として記述し、SQLite の状態をオンデマンドに読みながらグラフを構築するライブラリ。
`TaskManager.cli tasks args` に利用側の定義を渡す。ライブラリ自身は特定の TODO やサンプルを知らない。

## ビルド・実行

```sh
cd ~/Projects/ShinamonTaskManager6
nix develop
lake build
.lake/build/bin/taskdb graph
.lake/build/bin/taskdb gets
.lake/build/bin/taskdb get 1
.lake/build/bin/taskdb set 1 done "確認完了"
.lake/build/bin/taskdb set 1 progress 2 5
```

`lake build` でライブラリと実行ファイルをビルドする。ソース変更時は再ビルドが必要。DB や設定変更時は不要。
`lake exe taskdb graph` でも実行できる。引数なしは `graph` と同じ。

`Main.lean` は CLI に `ExampleTasks.lean` の定義を渡すだけの入口。サンプルには設計・実装などの分岐と A/B の循環があり、単一の `graph` で両方を出力する。`tasks` / `cycle` の選択引数はない。
旧プロジェクトの個別 TODO 群は移行していない。移行した DB に記録されている状態は保持される。

## 利用側のコード

```lean
import TaskManager

open TaskManager

def tasks : TaskProg Unit := do
  let design ← push { name := "設計", tags := [.Programing] }
  if (← getTaskStatus "設計") == .Done then
    pushU { name := "実装" } [] [design]

def main (args : List String) : IO UInt32 :=
  TaskManager.cli tasks args
```

`TaskProg` は帰納型で操作と続きを表し、`Monad` により `do` / `if` を使える。任意の IO を埋め込む操作はない。
`getTaskStatus` / `getTaskState` に到達して初めて DB を読み、その結果で続きを選ぶ。未選択の分岐は実行しない。
複数ファイルのタスク群は、利用側の `tasks` で呼び出して合成する。

別プロジェクトの `lakefile.lean` では、現在はローカルパスで参照できる。

```lean
import Lake
open Lake DSL

package MyTodos
require ShinamonTaskManager6 from "../ShinamonTaskManager6"

@[default_target]
lean_exe todo where
  root := `Main
```

Git リポジトリとして公開した後は、この `require` を Git URL と revision の指定に置き換える。
実際に import する利用側の最小例は `examples/consumer/` にある。

## 設定・コマンド

カレントディレクトリの `taskdb.json` を読む。

```json
{"sqlitePath": "tasks.sqlite3"}
```

相対 DB パスは設定ファイルの場所を基準にする。別設定は `--config /path/to/taskdb.json` をコマンドの前に指定する。
DB パスを明示した場合は設定ファイルを読まない。設定がない・不正な場合はエラーにする。

| コマンド | 動作 |
| --- | --- |
| `graph [DB]` | ソースの定義を実行してグラフを JSON 出力 |
| `gets [DB]` | DB 内の全タスクを ID 順に JSON 配列で出力 |
| `get [DB] ID` | 1件の ID・名前・状態を出力 |
| `set [DB] ID not-started/doing/pending` | 状態を更新（3つのうち1つを指定） |
| `set [DB] ID progress CURRENT TOTAL` | 進捗を更新 |
| `set [DB] ID done [RESULT]` | 完了にして UTC の完了日時を自動設定 |

結果に空白がある場合は引用符で囲む。結果省略時は既存結果を保持し、空文字を渡すと消去する。done の再実行は完了日時も更新する。他の状態への更新では結果と完了日時を保持する。
`set-state` コマンドは削除済み。`get` / `gets` は読み取り専用。`set` も未登録 ID や存在しない DB を新規作成しない。

## データとグラフ

- `Task` は名前・タグ・担当・リンク・予定日・詳細を持つ独自型。`TaskState` は状態・完了日・結果。
- DB は `task_states(id, name, state)`。グラフや辺は保存しない。
- ソース実行で名前を照合し、同名なら DB ID と状態を再利用する。ID は自動採番で、手書き不要。改名は別タスク。
- 初めて状態を読む、またはノードを追加したときに未登録の名前を NotStarted で登録する。状態取得だけではグラフにノードを追加しない。
- 同じ実行で同名を追加すると同一ノードになる。定義情報はその実行の最初の追加を採用する。
- 一回の実行はトランザクション。失敗時の登録はロールバックし、実行中の他接続の更新は待機する。
- JSON は依存先から後続へ `dependents` を入れ子にする。タスク情報は DB ID と名前のみ。
- 循環・共有による再登場は ID と名前だけの参照。根のない循環も出力する。
- ソースから消えたタスクの DB 状態は残り、`gets` で確認できる。
- 旧形式の DB は `graph` 時に状態を保持して移行する。get/gets/set は移行しない。

現時点の `set` は依存関係による更新制限をまだ行わない。「末端」の意味の確認待ち。

## ファイル

- `TaskManager.lean`: 公開 import 入口
- `TaskManager/Model.lean`, `Tag.lean`: データ型
- `TaskManager/Program.lean`: 操作型・Monad・push 等
- `TaskManager/DB.lean`: SQLite 実行器と状態更新
- `TaskManager/Config.lean`, `Cli.lean`: 設定と再利用できる CLI
- `ExampleTasks.lean`, `Main.lean`: 利用側の定義と実行入口

## テスト

```sh
lake build taskdb_tests
taskdb_test_dir=$(mktemp -d)
.lake/build/bin/taskdb_tests "$taskdb_test_dir/tasks.sqlite3"
python3 tests/test_taskdb_config.py
cd examples/consumer
lake build
.lake/build/bin/todo graph
```

実 DB による分岐、名前と ID の保持、移行、循環・共有 JSON、ロールバック、設定、CLI を検証する。
