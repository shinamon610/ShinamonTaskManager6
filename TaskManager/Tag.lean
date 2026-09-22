import Lean

namespace TaskManager
open Lean

abbrev URL:=String

inductive Source
| link :URL->Source
| Kindle
| «物理本»
| NotPurchasedYet : (url:Option String:=none)->Source
| «会社のオライリー»
| path: System.FilePath -> Source
deriving Repr, BEq, Hashable, ToJson

inductive MyTag
| Idea
| Memo -- 断片的になんか考えたやつ
| Knowledge -- 本とかの内容を写経してみたとか
| Atcoder
| CTF
| Misskey
| Architecture
| «論文»
| Hardware
| Programing
| Keyboard
| «試験勉強»
| «統計検定»
| «環境構築»
| Nix
| Lean4
| Rust
| C
| Python
| Lisp
| Problem
| Project
| Shell
| Monad
| VRAR
| «読み物» (src:Source)
| WorkShop (src:Source)
| Youtube (url:URL)
| BuildSystem
| Math
| Linux
| «低レイヤー»
| «業務»
| «生活»
| DB
deriving Repr, BEq, Hashable,Inhabited,ToJson

end TaskManager
