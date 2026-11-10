# 極端ミューテーション

[English](../../methods/extreme-mutation.md) | 日本語

**verified** 列（[基本概念](../concepts.md) を参照）を埋める手法です。実行されたメソッドごとに、本体を最も単純な振る舞いに置き換えたとき、どれかのテストが気づくかを調べます。

## 何をするか

通常のミューテーション演算子（`+` を `-` に置き換えるなど）ではなく、メソッド本体を丸ごと、戻り値型にとって最も単純な振る舞い（空の本体、`nil`、`true`/`false`、`0`/`1`、`""`、`[]` …）に置き換えます。どの置き換えでもテストが全て通るメソッドを **pseudo-tested**（実行されているが、何をしているかはどのテストも確かめていない）と報告します。

## 背景

- Niedermayr, Juergens & Wagner (2016), *Will My Tests Tell Me If I Break This Code?*：メソッド本体を空またはデフォルト値の返却に置き換え、それでもテストが通るメソッドを *pseudo-tested* と定義。
- Vera-Pérez, Monperrus & Baudry (2018), *Descartes: A PITest Engine to Detect Pseudo-Tested Methods*：Java (PIT) 向けのツール化。
- Vera-Pérez ら (2019), *A Comprehensive Study of Pseudo-tested Methods* (EMSE)：21 の OSS を調査し、成熟したプロジェクトにも pseudo-tested メソッドが存在すること、開発者がそのかなりの割合を対処する価値ありと判断したことを報告。

## 極端ミューテーションを選んだ理由

1. **コストが小さい。** メソッドあたり 1〜3 ミュータントで済み、`--since` による差分解析なら PR ごとの CI に入る。
2. **出力に反論の余地が小さい。** 「このメソッドの本体を消しても、どのテストも落ちない」という二値の事実で、解釈が要らない。
3. **同値ミュータント問題が小さい。** 元のプログラムと同じ振る舞いをするミュータントの判定は決定不能（Budd & Angluin 1982）だが、本体を丸ごとデフォルト値に置き換えたミュータントが同値になるのは、メソッド自体が自明な値しか返さない場合にほぼ限られる。

通常の（演算子レベルの）ミューテーションは、同じ列をより細かく、より高いコストで埋めます（[基本概念](../concepts.md#ミューテーション分析) を参照）。これは置き換えではなく別の手法です。極端ミューテーションで明白な穴を安く見つけ、細かい手法は極端ミューテーションが `tested` とした宣言に集中できます。

## 結果

この手法は、executed 列で実行済みとされたメソッドだけに適用します（その列が使えないときは全メソッド）。Descartes の定義をそのまま採用しているので、論文の結果と比較できます。

| 結果 | 条件 | PIE での意味 |
|---|---|---|
| `pseudo-tested` | 全ミュータントが生存 | E は成立、I + P が不成立 |
| `partially-tested` | 一部のミュータントが生存 | 振る舞いの一部しか検証されていない |
| `tested` | 全ミュータントが検出された | 明白な穴はない |

タイムアウトしたミュータントは PIT/Descartes と同じく「検出された」とみなします。

## 戻り値型ごとのミュータント

| 戻り値型 | ミュータント |
|---|---|
| なし / `Void` / `()` | 本体を空にする（`return`） |
| `T?` / `T!` / `Optional<T>` | `return nil` |
| `Bool` | `return true` と `return false`（Descartes と同じく両方） |
| 整数・浮動小数点型（`Int`, `UInt8`, `Double`, `CGFloat`, `Decimal` …） | `return 0` と `return 1` |
| `String` / `Substring` | `return ""` と `return "A"` |
| `[T]` / `Array` / `Set` / `ContiguousArray` | `return []` |
| `[K: V]` / `Dictionary` | `return [:]` |
| `Data` | `return Data()` |
| `some View`（`var body`、`@ViewBuilder`、result builder のない関数や getter） | `EmptyView()` |
| 型指定なしの `throws`（`--throw-mutants` 指定時のみ） | 上記に加えて `throw` |
| `async` | 変更なし（上記の規則をそのまま適用） |

## 対象外

| 対象 | 理由 |
|---|---|
| `init` / `deinit` / `subscript` | 置き換えるべき「デフォルトの振る舞い」が定義できない |
| `Never` を返すメソッド | 同上 |
| `get` 以外のアクセサ（`set`, `willSet`, `didSet`, `_modify`） | 同上 |
| プロトコル要件（本体なし） | 本体がない。プロトコル拡張のデフォルト実装は対象 |
| ローカル関数・クロージャ | メソッド単位の分類から外れる |
| `@inlinable` / `@_transparent` / `@_alwaysEmitIntoClient` | 本体からミュータントのスイッチを参照できない（[詳細](../../../ARCHITECTURE.ja.md#mutant-schemata)） |
| `main.swift` 内の宣言 | トップレベルコードの初期化順の制約 |
| 本体がログ出力だけの `Void` メソッド（`--no-arid` 指定時を除く） | ログメッセージをアサートすべきテストはない（[arid な本体](#arid-な本体)） |
| `rethrows` の関数が返す `some View` | 元の本体を入れるローカル関数を `rethrows` にできない（[詳細](../../../ARCHITECTURE.ja.md#mutant-schemata)） |
| `View` 以外の result builder | builder がどの構文をサポートするか分からない |
| タプル、`Result`、ジェネリック型パラメータ、ユーザー定義型、`some View` 以外の opaque 型など | 汎用的なデフォルト値がない |

対象外のメソッドは黙って捨てず、レポートの *Not analyzed* に理由付きで列挙します。

### arid な本体

`func didTapRetry() { logger.info("retry") }` の空本体ミュータントは生き残ります。しかし、レポートが求めることになる対処（ログメッセージへのアサーション）は、誰もすべきでないものです。こうした指摘が混ざると、レポートが読まれなくなります。Google のミューテーションテストは、この種のコードのミュータントを *arid node* として抑制しています（Petrović & Ivanković 2018）。このツールは同じ考え方をメソッド本体全体に当てはめます。

本体は、文が 1 つ以上あり、すべての文が arid なら arid です。

- `print`、`debugPrint`、`dump`、`NSLog`、`os_log`、`os_signpost`、`assert`、`assertionFailure` の呼び出し
- ロガーらしいレシーバーに対する `log`、`trace`、`debug`、`info`、`notice`、`warning`、`error`、`critical`、`fault` の呼び出し。ロガーらしいとは、`log` という名前か、`logger` で終わる名前の要素を含むこと（`logger`、`self.logger`、`Self.logger`、`Log.network`、`Logger(…)`）
- `--arid-call` で指定した呼び出し（先頭の `self.` を除いた呼び出し式と比較する）
- 値のない `return`
- 中の文がすべて arid で、条件が何も呼び出さない `if`、`guard`、`defer`、`#if`（条件内の呼び出しは副作用を持ちうるため）

`try` と `await` は無視して中身を見ます。対象になるのは `Void` を返すメソッドだけです。それ以外の戻り値型では、ミュータントは結果を置き換えるので、本体が他に何をしていてもテストで確かめるべきだからです。

判定は構文だけで行うので、レシーバーの型は分かりません。`logger` が実際にはロガーでなくても `logger.info(…)` は arid とみなします。引数は見ないので、ログメッセージの中の副作用（`print(queue.removeFirst())`）は見逃します。`track(…)` のようなアナリティクス呼び出しはテストするチームもあるので、既定では arid に含めません。必要なら `--arid-call` で足してください。ログ出力そのものが役割のモジュールを解析するときは `--no-arid` を指定してください。

## 限界

- 極端ミューテーションは「メソッドが何かしら検証されているか」を見るだけで、検証が十分かは見ない。`tested` は品質の保証ではなく、「明白な穴がない」ことを意味する。詳細な検証は通常のミューテーションテストで行う。
- 戻り値型がサポート外のメソッドは解析できない（[対象外](#対象外) を参照）。

## 実装

全ミュータントを 1 つのバイナリに埋め込み、実行時に切り替えます（mutant schemata）。各ミュータントは、そのメソッドを実行するテストに対して流します。どのテストが実行するかは、テストスコープを 1 つずつ単独で流して記録します。すり抜けたミュータントを全テストでも流すのは、それらがメソッドを実行するテストのすべてだと言い切れないときだけです（[テスト選択](../../../README.ja.md#テスト選択)）。詳しくは [ARCHITECTURE.ja.md](../../../ARCHITECTURE.ja.md#mutant-schemata) を参照してください。

## 参考文献

- Niedermayr, Juergens, Wagner (2016). Will My Tests Tell Me If I Break This Code? *CSED@ICSE*.
- Vera-Pérez, Monperrus, Baudry (2018). Descartes: A PITest Engine to Detect Pseudo-Tested Methods. *ASE*.
- Vera-Pérez, Danglot, Monperrus, Baudry (2019). A Comprehensive Study of Pseudo-tested Methods. *Empirical Software Engineering*.
- Petrović, Ivanković (2018). State of Mutation Testing at Google. *ICSE-SEIP*.
- Budd, Angluin (1982). Two Notions of Correctness and Their Relation to Testing. *Acta Informatica*.
