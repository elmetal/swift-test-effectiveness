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

1. **コストが小さい。** メソッドあたり（`--case-mutants` 指定時は switch の case あたりも）1〜3 ミュータントで済み、`--since` による差分解析なら PR ごとの CI に入る。
2. **出力に反論の余地が小さい。** 「このメソッドの本体を消しても、どのテストも落ちない」という二値の事実で、解釈が要らない。
3. **同値ミュータント問題が小さい。** 元のプログラムと同じ振る舞いをするミュータントの判定は決定不能（Budd & Angluin 1982）だが、本体を丸ごとデフォルト値に置き換えたミュータントが同値になるのは、メソッド自体が自明な値しか返さない場合にほぼ限られる。

通常の（演算子レベルの）ミューテーションは、同じ列をより細かく、より高いコストで埋めます（[基本概念](../concepts.md#ミューテーション分析) を参照）。これは置き換えではなく別の手法です。極端ミューテーションで明白な穴を安く見つけ、細かい手法は極端ミューテーションが `tested` とした宣言に集中できます。

## 結果

この手法は、executed 列で実行済みとされたメソッドだけに適用します（その列が使えないときは全メソッド）。Descartes の定義をそのまま採用しているので、論文の結果と比較できます。

| 結果 | 条件 | PIE での意味 |
|---|---|---|
| `pseudo-tested` | 全ミュータントが生存 | E は成立、I + P が不成立 |
| `partially-tested` | 一部のミュータントが生存。または `--case-mutants` 指定時に、[switch の case](#switch-の-case) のどれかが検証されていない | 振る舞いの一部しか検証されていない |
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
| `[T]` / `Array` / `Set` / `ContiguousArray` / `ArraySlice` | `return []` |
| `[K: V]` / `Dictionary` | `return [:]` |
| `Data` | `return Data()` |
| `some View`（`var body`、`@ViewBuilder`、result builder のない関数や getter） | `EmptyView()` |
| 型指定なしの `throws`（`--throw-mutants` 指定時のみ） | 上記に加えて `throw` |
| `async` | 変更なし（上記の規則をそのまま適用） |

### 値を返すだけの本体

本体がすでに返している値を返すミュータントは、元の本体と同じものです。どのテストにも検出できないので、テストが何をアサートしていても、メソッドは `pseudo-tested` と報告されてしまいます。こうしたミュータントは入れません。

| 本体 | ミュータント |
|---|---|
| `var isEnabled: Bool { true }` | `return false` だけ |
| `func retries() -> Int { return 0 }` | `return 1` だけ |
| `var delegate: Delegate? { nil }`、`func items() -> [Item] { [] }` | なし。メソッドは *Not analyzed* に載る |
| `func total() -> Money { .zero }`（`--default-value 'Money=.zero'` 指定時） | なし。同上 |
| `func load() throws -> Item? { nil }`（`--throw-mutants` 指定時） | `throw` だけ |
| `func reset() {}`、コメントだけの本体、`{ return }` | なし。同上 |
| `func prepare() throws {}`（`--throw-mutants` 指定時） | `throw` だけ |

対象になるのは、本体が 1 つの `return` か 1 つの式で、その値が上の表のリテラルか、`--default-value` で指定した式（コードとして比較するので、空白やコメントの違いは無視する）のときです。[switch の case](#case-ごとのミュータント) と同じ比較です。それ以外の本体のミュータントは変わりません。値を返す前に何かをする本体や、同じ値の別の書き方（`Optional.none`、`.zero` に対する `Money.zero`）がこれに当たります。

何もしない本体では、本体を空にするミュータントが元の本体と同じになります。何もしない本体とは、文がないか、値のない `return` だけの本体です。

### そのほかの戻り値型の値

上の規則が扱うのは標準ライブラリの型です。プロジェクトやライブラリの型にも、最も単純な値はたいていあります（`.zero`、`.empty`、`.none`）。ただし、それを知っているのはプロジェクトだけです。`--default-value` でその値を指定します。

```sh
swift-test-effectiveness --default-value 'Money=.zero' --default-value 'Tint=.gray'
```

`Money` を返すメソッドには、`return .zero` のミュータントが入ります。`--case-mutants` を指定すると、switch の各 case にも同じミュータントが入ります。別の case と同じことをさせるミュータントは使いません。

どの型に値を指定すればよいかは、レポートに出ます。*Not analyzed* のメソッドの一覧の後に、最も単純な値がない戻り値型を、メソッドの数が多い順に挙げます。`--dry-run` は、何もビルドせずに同じ行を出力します。

```
Not analyzed (2)
  Sources/Switches/Switches.swift:106  LoadState.tint — unsupported return type `Tint`
  Sources/Switches/Switches.swift:117  LoadState.severity(threshold:) — unsupported return type `Severity`
  → To analyze the methods that return a type without a simplest value, give the type one with `--default-value TYPE=EXPRESSION`: `Severity` (1 method) and `Tint` (1 method).
```

型は、`--default-value` に渡す形で挙げます。ジェネリック引数は付けません（`Box<Int>` は `Box`）。この行は候補の一覧で、そうした値がある型の一覧ではありません。ジェネリック型パラメータ（`T`）も挙がりますが、指定できる値はありません。`--closure` で [指定したクロージャ](#クロージャ) を囲むメソッドは数えません。そのロジックは、クロージャとして解析されるためです。

- 式は、その型を返すすべてのメソッドに書き込まれるので、どのメソッドでもコンパイルできる必要がある。ローカルな名前ではなく、先頭がドットの式（`.zero`）やイニシャライザ（`Money(cents: 0)`）を使う。
- 戻り値型は、書かれたとおりに比較する。このツールは型を解決しないためである。`Money=…` は `Money`、`Shop.Money`、`Money<Yen>` に一致する。`Shop.Money=…` と `Money<Yen>=…` はより具体的で、`Money=…` より優先される。型全体も指定できる（`'Result<Int, Error>=.success(0)'`、`'(Int, Int)=(0, 0)'`）。typealias は別の名前なので、別に値を指定する。`Money?` と `[Money]` には、表の規則がそのまま当たる。
- 1 つの型に複数の値を指定すると、`true` と `false` のように、値ごとにミュータントができる。
- 表にある型に値を指定すると、その型のミュータントを置き換える。
- `some` の型と result builder には値を使わない。`some` の型では、すべての `return` が同じ具体型を返すためである。

## switch の case

既定ではオフです。`--case-mutants` で有効になります。

ロジックが switch になっているメソッドは case ごとに検証されるものですが、本体全体のミュータントは、どれか 1 つの case をテストするだけで全て検出されます。

```swift
func title(for state: LoadState) -> String {
    switch state {
    case .idle: "Idle"
    case .loading: "Loading"
    case .failed(let message): "Failed: \(message)"
    }
}
```

`.idle` のタイトルをアサートするテストが 1 つあれば、`return ""` も `return "A"` も検出されるので、ほかの case が何を返していてもメソッドは `tested` になります。`--case-mutants` を指定すると、メソッドの末尾にある switch の各 case を、それぞれ 1 つの本体としてミューテーションします。case の先頭で、戻り値型にとって最も単純な値を返します（`Void` ならその場で return します）。レポートは、テストが取りこぼしている case を名指しします。

```
Sources/App/Presenter.swift:18  Presenter.title(for:) -> String
    detected: `return ""`, `return "A"`
    → No test runs `case .loading` (line 21) of `Presenter.title(for:)`. Add a test of this case.
    → In `case .failed(let message)` (line 22), `Presenter.title(for:)` can `return ""` or `return "A"` without any test failing. Add a test of this case that asserts the result.
```

### 対象になる switch

本体の最後の文になっている、case が 2 つ以上の switch だけです。この形なら、case の先頭でメソッドを抜けることが「その case が何もしない」ことと同じになります。本体の途中にある switch では、後に続く文まで飛ばしてしまいます。メソッドが暗黙に返す switch 式も、ほかの文（`guard` など）の後にある switch も対象です。

result builder の本体や `some View` を返すメソッドの中の switch、case を `#if` で囲んだ switch（どの case が存在するかがビルド構成で変わる）は対象外です。

### case ごとのミュータント

各 case には、メソッドの戻り値型のミュータント（[戻り値型ごとのミュータント](#戻り値型ごとのミュータント) を参照）を入れます。ただし、検出しようのないものは除きます。

| case | ミュータント |
|---|---|
| ミュータントが返すのと同じリテラルを返す（`case .none: return nil`、`case .a: true`）。または `--default-value` で指定した式を返す（コードとして比較するので、空白やコメントの違いは無視する） | そのミュータントを除く（`true` には `return false` が残る） |
| `Void` メソッドで、何もしない（`break`、値のない `return`）か、ログ出力だけ（[arid](#arid-な本体)） | なし |
| `fatalError()` か `preconditionFailure()` を呼ぶだけ | なし |
| throw する（`--throw-mutants` 指定時） | `throw` のミュータントを除く |

### 最も単純な値がない戻り値型

enum やプロジェクト独自の型など、汎用的なデフォルト値がない型を返すメソッドには、メソッド自身のミュータントがありません（[対象外](#対象外) を参照）。ただし、`--default-value` で [その型に値を指定した](#そのほかの戻り値型の値) 場合を除きます。`--case-mutants` を指定すると、こうしたメソッドを case だけで解析します。各 case には、別の case と同じことをさせます。

```swift
var tint: Tint {
    switch self {
    case .idle: .gray       // ミュータント：`case .loading` と同じことをする
    case .loading: .blue    // ミュータント：`case .loaded` と同じことをする
    case .loaded: .green    // ミュータント：`case .failed` と同じことをする
    case .failed: .red      // ミュータント：`case .idle` と同じことをする
    }
}
```

相手の case は、後ろに続く case から順に（最後まで行ったら先頭から）探し、変数を束縛せず（束縛する case の文はその変数を必要とするため）、かつ違うことをする最初の case にします。

- 次の case には `fallthrough` で移る。
- それ以外の case からは文を借り、この case の中で実行する。借りるのは、どの文も 1 行に収まり、`fallthrough` も `defer` も含まず、この case が束縛する変数に隠される名前を使っていないときだけ。switch 式では fallthrough できないので、次の case からも同じように式を借りる。

`fatalError()` を呼ぶだけの case は相手にしません。ミュータントがクラッシュするだけになるためです。相手が見つからない case にはミュータントを入れず、どの case にも入らないメソッドは *Not analyzed* のままです。opaque 型（`some ToolbarContent` など）を返すメソッドも同じです。属性がなくても本体が result builder になっていることがあるためです。

```
Sources/App/LoadState.swift:106  LoadState.tint: Tint
    → In `case .loading` (line 109), `LoadState.tint` can do what `case .loaded` does without any test failing. Add a test of this case that asserts the result.
```

### 結果の扱い

case のミュータントは、本体全体のミュータントの後に流します。流すのは、本体全体のミュータントが 1 つでも検出されたメソッドだけです。全て生存したメソッドは `pseudo-tested` で、case を調べても分かることが増えないためです。メソッド自身のミュータントがないメソッドは case だけが手がかりなので、カバレッジで「どのテストも実行しない」と分かっている場合を除いて流します。

各ミュータントは、その case を実行するテストに対して流します。どのテストが実行するかは、各テストスコープが実行するメソッドと一緒に記録します（[テスト選択](../../../README.ja.md#テスト選択)）。スコープ全体がテストスイート全体と一致するとき、どのスコープも実行しなかった case は「どのテストも実行しない case」として報告し、ミュータントは流しません。一致しないときは全テストで流し、ミュータントが生存したほかの case と同じように報告します。

| メソッド | case | 結果 |
|---|---|---|
| `tested` | どの case もテストが実行し、case のミュータントが 1 つも生存しない | `tested` |
| `tested` | どのテストも実行しない case があるか、case のミュータントが生存した | `partially-tested` |
| `partially-tested`、`pseudo-tested`、`not-covered` | — | 変わらない。case によってメソッドの評価が良くなることはない |
| 自身のミュータントなし | 流したミュータントが全て生存したか、1 つも流れなかった | `pseudo-tested` |
| 自身のミュータントなし | どの case もテストが実行し、ミュータントが 1 つも生存しない | `tested` |
| 自身のミュータントなし | 上記以外 | `partially-tested` |

JSON レポートでは、case を流したメソッドに `cases` が付きます。ミュータントのある case ごとに `label`、`line`、`executed`、`mutants` が入ります。

### case のミュータントの限界

- ミュータントのない case は、どのテストも実行していなくても報告されない。
- 別の case の文はテキストとして移す。上の条件は構文だけで判定するので、移した先で文がコンパイルできないと、スキーマがビルドできず解析が止まる。その場合は `--case-mutants` を外して実行し、該当する構文を報告してほしい。
- 本体の途中の switch、result builder の中の switch、`some View` を返すメソッドの中の switch は、case ごとには解析しない。

## クロージャ

既定ではオフです。`--closure` で、クロージャを解析する呼び出しを指定します。

ロジックがメソッドとして書かれていないことがあります。イベントごとに呼び出す型へ渡すハンドラはクロージャで、それが書かれているメソッドはクロージャを作るだけです。

```swift
var handler: Handler<State, Event> {
    Handler { state, event in
        switch event {
        case .received:
            state.unread += 1
            return .none
        case .opened:
            state.unread = 0
            return .save
        case .muted:
            state.isMuted = true
            return .save
        }
    }
}
```

`handler` が返す `Handler` には最も単純な値がなく、クロージャはメソッドではないので、このコードは何も解析されません。`--closure` で、呼び出しの名前と、そのクロージャが返す型を指定します。

```sh
swift-test-effectiveness --closure 'Handler=Command' --default-value 'Command=.none' --case-mutants
```

これで、`Handler` の呼び出しの trailing closure が、1 つのメソッドとして扱われます。レポートには、クロージャが書かれているメソッドの名前と呼び出しの名前で出ます。ミュータントは、指定した型のものです。`--case-mutants` を指定すると、クロージャの末尾にある switch の各 case もミューテーションします。

```
Partially tested (1)
  Sources/Closures/Closures.swift:42  Inbox.handler, Handler { } -> Command
    detected: `return .none`
    → In `case .opened` (line 47), `Inbox.handler, Handler { }` can `return .none` without any test failing. Add a test of this case that asserts the result.
    → No test runs `case .muted` (line 50) of `Inbox.handler, Handler { }`. Add a test of this case.
```

- **型**：クロージャには戻り値型が書かれないので、オプションで指定する。型には、戻り値型の規則がそのまま当たる。[表](#戻り値型ごとのミュータント) の型、何も返さないクロージャの `Void`（`--closure 'subscribe=Void'`）、`--default-value` で指定した値である。戻り値型を書いているクロージャ（`{ item -> Bool in … }`）では、書かれた型を使う。opaque 型は指定できない。
- **名前**：呼び出しは、書かれたとおりに比較する。このツールは名前を解決しないためである。比較するのは、呼び出し先の末尾の要素である。`subscribe` は `subscribe { }`、`store.subscribe { }`、`.subscribe { }` に一致する。`store.subscribe` は、末尾がその両方である呼び出しにだけ一致する。ジェネリック引数は名前に含めない（`Handler<State, Event> { }` は `Handler`）。`.init { }` は `init` である。複数の名前が一致するときは、要素の多い名前の型を使う。
- **対象になるクロージャ**：ツールが見つける関数と computed property の本体にある、呼び出しの trailing closure（複数あるときは最初のもの）。クロージャの中のクロージャも対象になる。それ以外の場所（stored property の初期値、イニシャライザ、トップレベルコード）のクロージャは対象にならない。
- **値を返すだけのクロージャ、何もしないクロージャ**：`{ _, _ in .none }`（`--default-value 'Command=.none'` 指定時）や `{ _ in }` には、テストが検出できるミュータントがない。[同じ形のメソッド](#値を返すだけの本体) と同じく、*Not analyzed* に載る。
- **クロージャを囲むメソッド**：これまでどおり解析する。クロージャを作るだけのメソッドは、戻り値型が理由で *Not analyzed* に残る。`--default-value` に指定する型を挙げる行には、数えない。
- **実行と参照**：テストがクロージャを実行するかどうかは、クロージャ自身について調べる。[参照](static-references.md) の列は `unknown` になる。テストからクロージャを参照することはできず、インデックスにもクロージャのシンボルはないためである。

### クロージャの限界

- ミュータントはクロージャの先頭に入る文なので、式 1 つのクロージャは複数の文のクロージャになる。このとき、クロージャの型は本体からではなく、呼び出しから決まっている必要がある。result builder が変換するクロージャ（`VStack { … }`）は指定できない。スキーマがビルドできないと解析は止まるので、その名前を外して実行する。
- その名前の呼び出しは、何を呼んでいてもすべて対象になる。2 つの関数が同じ名前のときは、名前の要素を増やして区別する。区別できなければ指定できない。

## 対象外

| 対象 | 理由 |
|---|---|
| `init` / `deinit` / `subscript` | 置き換えるべき「デフォルトの振る舞い」が定義できない |
| `Never` を返すメソッド | 同上 |
| `get` 以外のアクセサ（`set`, `willSet`, `didSet`, `_modify`） | 同上 |
| プロトコル要件（本体なし） | 本体がない。プロトコル拡張のデフォルト実装は対象 |
| ローカル関数・クロージャ | メソッド単位の分類から外れる。`--closure` で指定した呼び出しのクロージャは、[1 つのメソッドとして扱う](#クロージャ) |
| `@inlinable` / `@_transparent` / `@_alwaysEmitIntoClient` | 本体からミュータントのスイッチを参照できない（[詳細](../../../ARCHITECTURE.ja.md#mutant-schemata)） |
| `main.swift` 内の宣言 | トップレベルコードの初期化順の制約 |
| 本体が何もしないメソッド（`{}`）、または唯一のミュータントと同じ値を返すだけのメソッド（`{ nil }`、`{ [] }`） | ミュータントが元の本体と同じになり、どのテストにも検出できない（[詳細](#値を返すだけの本体)） |
| 本体がログ出力だけの `Void` メソッド（`--no-arid` 指定時を除く） | ログメッセージをアサートすべきテストはない（[arid な本体](#arid-な本体)） |
| `rethrows` の関数が返す `some View` | 元の本体を入れるローカル関数を `rethrows` にできない（[詳細](../../../ARCHITECTURE.ja.md#mutant-schemata)） |
| すべてコンパイルから外れうる `#if` ブロックと並んだ式 | 暗黙に返されるかどうかがビルド構成で決まる（[詳細](../../../ARCHITECTURE.ja.md#mutant-schemata)） |
| `View` 以外の result builder | builder がどの構文をサポートするか分からない |
| タプル、`Result`、ジェネリック型パラメータ、ユーザー定義型、`some View` 以外の opaque 型など | 汎用的なデフォルト値がない。opaque 型以外は、`--default-value` で [値を指定できる](#そのほかの戻り値型の値)。`--case-mutants` を指定すると、末尾が switch のメソッドは [case ごとに](#最も単純な値がない戻り値型) 解析する |

対象外のメソッドは黙って捨てず、レポートの *Not analyzed* に理由付きで列挙します。デフォルト値がない戻り値型については、[どの型に値を指定すればよいか](#そのほかの戻り値型の値) も示します。

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
- 戻り値型がサポート外のメソッドは解析できない（[対象外](#対象外) を参照）。ただし `--default-value` で値を指定した型は解析できる。また、末尾が switch のメソッドは、case ごとになら解析できる（[switch の case](#switch-の-case) を参照）。
- クロージャとして書かれたロジックは解析できない。ただし、`--closure` で指定した呼び出しのクロージャは解析できる（[クロージャ](#クロージャ) を参照）。
- switch のどれか 1 つの case をテストすれば、本体全体のミュータントは全て検出される。`--case-mutants` を指定しないと、こうしたメソッドは、テストが確かめている case がどれだけ少なくても `tested` になる。

## 実装

全ミュータントを 1 つのバイナリに埋め込み、実行時に切り替えます（mutant schemata）。各ミュータントは、そのメソッドを実行するテストに対して流します。どのテストが実行するかは、テストスコープを 1 つずつ単独で流して記録します。すり抜けたミュータントを全テストでも流すのは、それらがメソッドを実行するテストのすべてだと言い切れないときだけです（[テスト選択](../../../README.ja.md#テスト選択)）。詳しくは [ARCHITECTURE.ja.md](../../../ARCHITECTURE.ja.md#mutant-schemata) を参照してください。

## 参考文献

- Niedermayr, Juergens, Wagner (2016). Will My Tests Tell Me If I Break This Code? *CSED@ICSE*.
- Vera-Pérez, Monperrus, Baudry (2018). Descartes: A PITest Engine to Detect Pseudo-Tested Methods. *ASE*.
- Vera-Pérez, Danglot, Monperrus, Baudry (2019). A Comprehensive Study of Pseudo-tested Methods. *Empirical Software Engineering*.
- Petrović, Ivanković (2018). State of Mutation Testing at Google. *ICSE-SEIP*.
- Budd, Angluin (1982). Two Notions of Correctness and Their Relation to Testing. *Acta Informatica*.
