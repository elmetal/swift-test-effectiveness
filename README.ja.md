# swift-test-effectiveness

[English](README.md) | 日本語

Swift プロジェクトのテストが「実行している」だけでなく「検証している」かを調べ、メソッド単位でフィードバックするツールです。

各メソッドの本体を、戻り値型にとって最も単純な振る舞い（空の本体、`nil`、`true`/`false`、`0`/`1`、`""`、`[]` …）に置き換え、それでもテストが全て通るメソッドを **pseudo-tested**（実行されているが検証されていない）として報告します。

```
Pseudo-tested (2)
  Tests execute these methods, but every extreme mutant survived: no test checks what they do.

  Sources/Sample/Calculator.swift:17  Calculator.greeting(for:) -> String
    survived: `return ""`, `return "A"`
    → `Calculator.greeting(for:)` can always return `""` without any test failing. Assert the exact string.
    ...

Partially tested (2)
  Sources/Sample/Calculator.swift:12  Calculator.isPositive(_:) -> Bool
    survived: `return true`
    detected: `return false`
    → `Calculator.isPositive(_:)` can always return `true` without any test failing. Add a case where it must return `false`.
```

この README は「なぜ効くかの理論」「何を実装したかの手法」「それが妥当だという証拠と限界」の順に書いています。使い方だけ知りたい場合は [使い方](#使い方) へ。

---

## 1. 理論：ミューテーション分析と PIE モデル

### ミューテーション分析

土台はミューテーション分析（DeMillo, Lipton & Sayward 1978, *Hints on Test Data Selection*）です。プログラムを人工的に小さく壊し（ミュータント）、テストがそれを検出（kill）できるかを見ます。この方法の正当性は 2 つの仮説に支えられています。

- **Competent programmer hypothesis** — 実際のバグは、正しいプログラムからの小さな逸脱である。
- **Coupling effect** — 単純なミュータントを検出できるテストは、より複雑な故障も検出する。

### PIE モデル：カバレッジとの違い

Voas (1992) の PIE モデルは、テストが故障を検出するための条件を 3 段階に分けます。

| 段階 | 意味 |
|---|---|
| **E**xecution | 故障箇所が実行される |
| **I**nfection | プログラムの状態が汚染される |
| **P**ropagation | 汚染がアサーションまで伝播し、テストが失敗する |

**カバレッジは E しか測らず、ミューテーションは E + I + P を測る。** このツールの存在理由はこの一文に尽きます。カバレッジ 100% でも、戻り値を一切アサートしないテストは E を満たすだけで、故障を検出しません。

本ツールは両方を使います。カバレッジで E を満たさないメソッドを `not-covered` とし、E を満たすメソッドに対してだけミュータントを実行して I + P を確かめます。`pseudo-tested` は「E は満たすが I + P が成立しない」メソッド、つまりカバレッジでは見えないオラクルの欠落です。

## 2. 手法：極端ミューテーション（pseudo-tested methods）

通常のミューテーション（演算子の置換など）ではなく、**極端ミューテーション（extreme mutation）** を主軸にしています。

- Niedermayr, Juergens & Wagner (2016), *Will My Tests Tell Me If I Break This Code?* — メソッド本体を空またはデフォルト値の返却に置き換え、それでもテストが通るメソッドを *pseudo-tested* と定義。
- Vera-Pérez, Monperrus & Baudry (2018), *Descartes: A PITest Engine to Detect Pseudo-Tested Methods* — Java (PIT) 向けのツール化。
- Vera-Pérez ら (2019), *A Comprehensive Study of Pseudo-tested Methods* (EMSE) — 21 の OSS を調査し、成熟したプロジェクトにも pseudo-tested メソッドが存在すること、開発者がそのかなりの割合を対処する価値ありと判断したことを報告。

極端ミューテーションを選んだ理由は 3 つです。

1. **コストが小さい。** メソッドあたり 1〜3 ミュータントで済み、`--since` による差分解析なら PR ごとの CI に入る。
2. **出力に反論の余地が小さい。** 「このメソッドの本体を消しても、どのテストも落ちない」という二値の事実で、解釈が要らない。
3. **同値ミュータント問題が小さい。** 元のプログラムと同じ振る舞いをするミュータントの判定は決定不能（Budd & Angluin 1982）だが、本体を丸ごとデフォルト値に置き換えたミュータントが同値になるのは、メソッド自体が自明な値しか返さない場合にほぼ限られる。

通常のミューテーション（演算子レベル）は swift-mutation-testing のような既存ツールに委ね、本ツールでは扱いません。

### 分類

Descartes の定義をそのまま採用しているので、論文の結果と比較できます。

| 分類 | 条件 | PIE での意味 |
|---|---|---|
| `not-covered` | どのテストもメソッドを実行しない（ミュータントは実行しない） | E が不成立 |
| `pseudo-tested` | 全ミュータントが生存 | E は成立、I + P が不成立 |
| `partially-tested` | 一部のミュータントが生存 | 振る舞いの一部しか検証されていない |
| `tested` | 全ミュータントが検出された | — |

タイムアウトしたミュータントは PIT/Descartes と同じく「検出された」とみなします。

## 3. 妥当性の証拠と、限界

### 証拠

- **Just ら (2014, FSE)**, *Are Mutants a Valid Substitute for Real Faults in Software Testing?* — ミュータントの検出と実バグの検出には統計的に有意な相関がある。
- **Inozemtseva & Holmes (2014, ICSE)**, *Coverage Is Not Strongly Correlated with Test Suite Effectiveness* — テストスイートのサイズを統制すると、カバレッジとテストの有効性の相関はほぼ消える。「カバレッジでは足りない」の根拠。

### 限界と、それを受けた設計：スコアを出さない

**Papadakis ら (2018, ICSE)**, *Are Mutation Scores Correlated with Real Fault Detection?* は、テストスイートのサイズを統制するとミューテーションスコアと実バグ検出の相関も弱まることを示しました。

これを受けて、本ツールは **集計スコア（ミューテーションスコア、割合）を一切出力しません**。主出力はメソッド単位の分類と、生き残ったミュータントごとの具体的な指摘です。

もう一つの理由は Goodhart の法則です。スコアを目標にすると、人間でも AI エージェントでも「スコアだけを上げる」最適化（アサーションの水増しなど）が起きます。「`isPositive(_:)` が常に `true` を返してもテストが落ちない。`false` になるべきケースを追加せよ」という指摘は、満たす方法がテストの改善しかありません。

そのほかの限界：

- 極端ミューテーションは「メソッドが何かしら検証されているか」を見るだけで、検証が十分かは見ない。`tested` は品質の保証ではなく、「明白な穴がない」ことを意味する。詳細な検証は通常のミューテーションテストで行う。
- 戻り値型がサポート外のメソッドは解析できない（レポートの *Not analyzed* に理由付きで列挙される）。

---

## 使い方

### Swift Package

```bash
swift run swift-test-effectiveness /path/to/package
```

処理の流れ：

1. `swift package describe` でテスト以外のターゲットのソースを列挙し、メソッドを発見する。
2. プロジェクトを `<package>/.build/test-effectiveness/project` にコピーし、全ミュータントを埋め込んだ *mutant schema* に書き換える。
3. `swift build --build-tests --enable-code-coverage` で **1 回だけ** ビルドする。
4. ミュータント無しでテストを実行（ベースライン）。失敗した場合は中止。カバレッジを取得する。
5. 実行されたメソッドのミュータントごとに `STE_MUTANT=<id> swift test --skip-build` を実行する。
6. メソッドを分類してレポートする。

元のソースは変更しません。

### 主なオプション

| オプション | 説明 |
|---|---|
| `--since <rev>` | `git diff <rev>` で変更された行を含むメソッドだけを解析する（PR 用） |
| `--target <name>` | 指定ターゲットのみ（複数可） |
| `--test-filter <pattern>` | `swift test --filter` に渡す |
| `--exclude <substring>` | パスに文字列を含むファイルを除外（複数可） |
| `--throw-mutants` | 型指定なしの `throws` メソッドに `throw` するミュータントを追加 |
| `--no-coverage` | カバレッジを使わず、全ミュータントを実行する |
| `--format text\|markdown\|json` | レポート形式（markdown は PR コメント向け） |
| `-o, --output <file>` | レポートをファイルに書き出す |
| `--dry-run` | メソッドとミュータントの一覧だけを表示する |
| `--fail-on-pseudo-tested` | pseudo-tested メソッドがあれば終了コード 1 |
| `--swift <path>` | 使用する `swift` 実行ファイル |
| `--timeout-factor`, `--minimum-timeout` | ミュータントごとのタイムアウト（ベースライン時間 × 係数、下限秒数） |

終了コード：`0` 成功、`1` `--fail-on-pseudo-tested` に該当、`2` ビルド失敗やベースライン失敗など。

### Xcode プロジェクトなど（カスタムモード）

`--source-dir`、`--build-command`、`--test-command` を指定すると、任意のビルドシステムで動きます。コマンドはコピーしたプロジェクト内で `/bin/sh -c` で実行されます。アクティブなミュータントは `STE_MUTANT` と `TEST_RUNNER_STE_MUTANT` の両方で渡されます（`xcodebuild test` は `TEST_RUNNER_` 付きの環境変数をテストプロセスに転送します）。

```bash
swift run swift-test-effectiveness /path/to/App \
  --source-dir App \
  --build-command "xcodebuild build-for-testing -scheme App -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.2'" \
  --test-command  "xcodebuild test-without-building -scheme App -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.2'"
```

カスタムモードではカバレッジを使わないため、テストから実行されないメソッドも `pseudo-tested` として報告されます。

### CI での例

```bash
swift run swift-test-effectiveness . --since origin/main --format markdown -o effectiveness.md
```

生成された Markdown を PR コメントに貼ると、変更されたメソッドのうち検証されていないものだけが、直し方とともに表示されます。

---

## Swift への適用：設計上の判断

### デフォルト値（ミューテーション演算子）

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
| result builder 内の `some View`（`var body`、`@ViewBuilder`） | `EmptyView()` |
| 型指定なしの `throws`（`--throw-mutants` 指定時のみ） | 上記に加えて `throw` |
| `async` | 変更なし（上記の規則をそのまま適用） |

### 対象外

| 対象 | 理由 |
|---|---|
| `init` / `deinit` / `subscript` | 置き換えるべき「デフォルトの振る舞い」が定義できない |
| `Never` を返すメソッド | 同上 |
| `get` 以外のアクセサ（`set`, `willSet`, `didSet`, `_modify`） | 同上 |
| プロトコル要件（本体なし） | 本体がない。プロトコル拡張のデフォルト実装は対象 |
| ローカル関数・クロージャ | メソッド単位の分類から外れる |
| `@inlinable` / `@_transparent` / `@_alwaysEmitIntoClient` | 本体から `fileprivate` のスイッチを参照できない |
| `main.swift` 内の宣言 | トップレベルコードの初期化順の制約 |
| result builder 外で `some View` を返すメソッド | opaque 型は分岐ごとに同じ具象型が必要なため |
| `View` 以外の result builder | builder がどの構文をサポートするか分からない |
| タプル、`Result`、ジェネリック型パラメータ、ユーザー定義型など | 汎用的なデフォルト値がない |

対象外のメソッドは黙って捨てず、*Not analyzed* として理由付きでレポートします。

### Mutant schemata

ミュータントごとにビルドし直すと遅いので、全ミュータントを 1 つのバイナリに埋め込み、実行時に環境変数で切り替えます（Untch, Offutt & Harrold 1993, *Mutation Analysis Using Mutant Schemata*）。

```swift
// 元のコード
func add(_ a: Int, _ b: Int) -> Int {
    a + b
}

// mutant schema
func add(_ a: Int, _ b: Int) -> Int { switch __steActiveMutant { case 1: return 0; case 2: return 1; default: break };
    return a + b
}

// result builder の場合
var body: some View { if __steActiveMutant == 7 { EmptyView() } else {
    Text("Hello")
} }
```

- 挿入はすべて既存の行の中で行うので、**行番号が元のソースと一致** します。カバレッジ（llvm-cov の関数リージョンは本体の `{` から始まる）をそのまま元のメソッドに対応付けられ、コンパイルエラーの行番号も元のソースと同じになります。
- 単一式の本体（暗黙の `return`）には `return` を補います。`if`/`switch` 式も同様ですが、内部に `return` 文を含む場合は文として扱います。
- スイッチ変数は各ファイルの末尾に `nonisolated fileprivate let` として生成し、`getenv` で読みます。ファイル単位なので、ビルド設定やプロジェクトファイルを変更する必要がなく、`defaultIsolation(MainActor.self)` のモジュールでも動きます。

## 関連研究・発展候補

- **Checked coverage**（Schuler & Zeller 2011）— アサーションから動的スライスで遡り、アサーションに影響する文だけをカバレッジとして数える。オラクルの質を直接測る手法だが、Swift で動的スライスを取るのは現実的でないため実装していない。
- **オラクルギャップ** — カバレッジとミューテーション検出の差。本ツールでは「カバーされているのに `pseudo-tested`」なメソッドがそれに当たり、レポートの *Pseudo-tested* セクションがそのままオラクルギャップの一覧になる。

## 開発

```bash
swift test
```

フィクスチャに対する統合テスト（遅い）：

```bash
STE_INTEGRATION=1 swift test --filter IntegrationTests
```

- `Tests/Fixtures/SampleProject` — 各分類が 1 つ以上現れる小さなパッケージ。統合テストで分類結果を検証する。
- `Tests/Fixtures/EdgeCases` — if/switch 式、result builder、`throws`、actor、`defaultIsolation(MainActor)` など、書き換え後もコンパイルできなければならない構文の集まり。

swiftly などで入れたツールチェーンと Xcode の `Testing.framework` のバージョンが合わない場合は、`--swift /usr/bin/swift`（統合テストでは `STE_SWIFT=/usr/bin/swift`）で Xcode のツールチェーンを指定してください。

### 既知の制限

- プロジェクトを作業ディレクトリにコピーして解析するため、相対パスのローカル依存（`.package(path: "../Foo")`）は解決できない。
- `swift test` は `.build` をロックするため、ミュータントは逐次実行される。
