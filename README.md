# ShinamonTaskManager6

Lean のタスク定義を initial encoding の `TaskProg` として記述し、CSV に保存した状態に応じてグラフを構築するライブラリ。
`TaskManager.cli tasks args` に利用側の定義を渡す。ライブラリ自身は特定の TODO やサンプルを知らない。

## ビルド

Lean 4.31.0 のツールチェーンで実行する。外部の Lean パッケージ、SQLite、追加の C ライブラリには依存しない。

```sh
lake build
```

Linux の開発環境には任意で `nix develop` を利用できる。Windows でも Nix は不要。

`lake build` でライブラリをビルドする。タスク定義と実行入口は利用側の repo に置く。

## 利用側のコード

```lean
import TaskManager

open TaskManager

inductive MyTag where
  | programming
  | url : String → MyTag
  deriving Lean.ToJson, Lean.FromJson

def tasks : TaskProg MyTag Unit := do
  pushU (.new "テスト") [
    push (.new "実装") [
      push (.new "設計" [.programming])
    ]
  ]

def main (args : List String) : IO UInt32 :=
  TaskManager.cli tasks args
```

`pushU 親 [push 子 …]` の入れ子が依存関係の木になる。子は親の前提タスクで、通常はノード ID を変数に束縛する必要がない。共有する既存ノードは第3引数の `refs` に渡し、循環は `addEdge` で結べる。
`TaskProg Tag α` は帰納型で操作と続きを表し、`Monad` により `do` / `if` を使える。任意の IO を埋め込む操作はない。
実行開始時に CSV 全体を読み込む。`getTaskStatus` / `getTaskState` に到達したときにメモリ上の状態を参照し、その結果で続きを選ぶ。未選択の分岐は実行・登録しない。
複数ファイルのタスク群は、利用側の `tasks` で呼び出して合成する。

`MyTask Tag`・`TaskRecord Tag`・`Node Tag`・`Graph Tag` のタグ型は利用側で定義する。`Status` はライブラリ固定の `NotStarted` / `Doing` / `Pending` / `Done` / `Progress current total`。
`MyTask.new name tags operator plannedStart plannedEnd details` で定義を作れる。`name` 以外は省略可能で、タグ型は文脈から推論される。担当を指定する `operator` は `assign` フィールドに格納する。
`run` / `setTaskStatus` には `ToJson Tag`、`getTask` / `getTasks` には `FromJson Tag`、CLI には両方が必要。`TaskProg` の構築だけには不要。
`TaskDB.getTask (Tag := MyTag) path id` / `TaskDB.getTasks (Tag := MyTag) path` のように、返り値から推論できないタグ型は明示する。状態のみを扱う `TaskDB.getState` / `setState` / `setStatus` / `setDone` はタグ型を要求しない。

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
{"csvPath": "data/tasks.csv"}
```

相対 CSV パスは設定ファイルの場所を基準にする。別設定は `--config /path/to/taskdb.json` をコマンドの前に指定する。
保存先は必ず設定ファイルの `csvPath` を使う。コマンド引数での CSV パス指定は受け付けない。設定がない・不正な場合はエラーにする。

| コマンド | 動作 |
| --- | --- |
| `graph` | ソースの定義を実行してグラフを JSON 出力 |
| `gets` | CSV 内の全タスクを ID の辞書順に JSON 配列で出力 |
| `get ID` | 1件の ID・名前・状態を出力 |
| `set ID ns/doing/pending` | 状態を更新（3つのうち1つを指定） |
| `set ID progress CURRENT TOTAL` | 進捗を更新 |
| `set ID done [RESULT]` | 完了にして UTC の完了日時を自動設定 |

ID は `a-z` と `2-7` からなる5文字の文字列（例: `k3mqp`）。`set k3mqp done` のように指定する。
結果に空白がある場合は引用符で囲む。結果省略時は既存結果を保持し、空文字を渡すと消去する。done の再実行は完了日時も更新する。他の状態への更新では結果と完了日時を保持する。
`set-state` コマンドは削除済み。`get` / `gets` は読み取り専用。`set` も未登録 ID や存在しない DB を新規作成しない。

CLI の文字列引数は入口の `Cli.parse` で `Command` / `DatabaseSource` を持つ `Request` に変換する。ID・状態・進捗もここで解析し、設定解決とコマンド実行は ADT で分岐する。

## データとグラフ

- `MyTask Tag` は名前・タグ・担当・予定日・詳細を持つ独自型。未使用の `links` フィールドは削除済み。タグに含まれる URL は保存できる。`TaskState` は状態・完了日・結果。
- 定義と現在状態を1つの CSV の1行にまとめる。グラフ・辺・状態履歴は保存しない。CLI の `state` JSON 出力は維持する。
- CSV は UTF-8、ヘッダー付きで、列は以下の順序。出力は CRLF、入力は LF / CRLF の両方に対応する。セル内のカンマ・引用符・改行は CSV の引用規則で保持する。

  ```text
  id,name,tags,assign,plannedStart,plannedEnd,details,status,progressCurrent,progressTotal,completedAt,result
  ```

- `tags` は JSON 配列。`assign` / `plannedStart` / `plannedEnd` / `completedAt` は JSON の `null` または文字列をセルに格納する。これにより未指定と空文字を区別する。`status` は `NotStarted` / `Doing` / `Pending` / `Done` / `Progress`。Progress 以外では進捗セルを空にする。
- 不正な CSV、重複した ID・名前、不正な状態や進捗はエラーにし、ファイルを上書きしない。
- `get` / `gets` は MyTask の全フィールドに `id`・`state` を加えたレコードを返す。`task` の入れ子や名前の重複はない。
- ソース実行で名前を照合し、同名なら ID と状態を再利用する。ID は5文字のランダム文字列で、新規登録時に現在の保存データと今回の新規登録分に対する重複を確認し、衝突したら再生成する。改名は別タスク。
- 初めて状態を読む、またはノードを追加したときに未登録の名前を NotStarted で登録する。状態取得だけではグラフにノードを追加しない。
- 同じ実行で同名を追加すると同一ノードになる。定義情報はその実行の最初の追加を採用する。
- `run` は今回到達した集合 B に DB を同期する。以前の集合 A に対し、A−B は削除、A∩B は ID・名前・状態を保持して定義情報を更新、B−A は新規登録する。空の集合なら全件削除する。
- 到達集合には状態を読むだけの名前も含む。その場合、既存の定義情報を保持し、新規なら名前以外を既定値で登録する。後でノードを追加した場合はその定義情報を保存する。
- 到達集合は Lean の `Std.HashSet String` で管理する。一時テーブルは不要。
- 定義の実行・検証はメモリ上で行い、成功後に全行を ID 順に保存する。保存は同じディレクトリの `.tmp` ファイルを書き終えてから置き換える。定義実行・検証の失敗時は元の CSV を変更しない。
- 排他制御は行わない。同じ CSV を複数プロセスから同時更新する運用は対象外。SQLite のトランザクションや耐障害性を提供するものではない。
- JSON は依存先から後続へ `dependents` を入れ子にする。各タスクに `id`・`name`・`status` を表示する。`status` の形式は `get` / `gets` の `state.status` と同じ。完了したタスクも表示する。
- 循環・共有による再登場は `id`・`name`・`status` を表示し、`dependents` は再展開しない。根のない循環も出力する。
- 到達しなくなったタスクの履歴は保持しない。削除後に同名が再登場した場合は ID を再生成し、初期状態で登録する。削除済み ID の履歴は持たないため、過去の ID が再利用される可能性はある。
- 旧 `sqlitePath` 設定・SQLite ファイルは読み込まない。`csvPath` に変更すると `graph` で新規 CSV を作成する。旧データの自動移行は行わない。

`set` は現在のタスク定義からグラフを構築し、以下の更新をエラーにする。

- 現在のグラフにないタスクへの更新。
- 直接の依存先に未完了のタスクがある場合の更新（自己依存や未完了の循環も含む）。
- Done から未完了の状態への変更。Done の再実行は許可する。

未完了の状態間の変更は、上記の条件を満たせば許可する。Progress の CURRENT は 0 以上 TOTAL 以下、TOTAL は正数とする。SQLite 由来の64ビット上限はなく、Lean の自然数として扱う。低水準の状態更新 API でも検証する。
検証に失敗した場合は、グラフ構築中に登録・更新した内容も保存しない。
`set` の検証中も到達した定義情報を保存するが、集合の削除同期は `run`（CLI の引数なし実行 / `graph`）で行う。
ライブラリの低水準 API `setState` / `setStatus` / `setDone` はグラフを検証しない。CLI と同じ検証には `setTaskStatus` にタスク定義を渡す。

## ファイル

- `TaskManager.lean`: 公開 import 入口
- `TaskManager/Model.lean`: データ型（具体的タグ型は利用側）
- `TaskManager/Program.lean`: 操作型・Monad・push 等
- `TaskManager/DB.lean`: CSV 保存・読み込み、実行器、状態更新
- `TaskManager/Csv.lean`: CSV の解析と出力
- `TaskManager/Config.lean`, `Cli.lean`: 設定と再利用できる CLI

## テスト

```sh
lake build taskdb_tests
taskdb_test_dir=$(mktemp -d)
.lake/build/bin/taskdb_tests "$taskdb_test_dir/tasks.csv"
python3 tests/test_taskdb_config.py
```

CSV による状態分岐、名前と ID の保持、ID 衝突時の再生成、タグ型の差し替え、引用符・改行・日本語の往復、不正データの拒否、到達集合への同期、循環・共有 JSON、失敗時のファイル保持、設定、CLI を検証する。Python はテストにのみ使用し、ライブラリ実行には不要。
