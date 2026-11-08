# アーキテクチャ

[English](ARCHITECTURE.md) | 日本語

swift-test-effectiveness がどう作られているかを説明します。ツールが何を報告し、なぜそうするのかは [docs/ja/concepts.md](docs/ja/concepts.md) と [docs/ja/methods/](docs/ja/methods/) を参照してください。

## ターゲット

| ターゲット | 役割 |
|---|---|
| `swift-test-effectiveness` | コマンドラインインターフェース（swift-argument-parser）。オプションを `AnalysisConfiguration` に変換し、レポートを出力する |
| `TestEffectivenessCore` | 解析本体。ライブラリの product としては公開しない（依存する `indexstore-db` を revision で固定しており、SwiftPM ではバージョン指定で依存されるパッケージにこれを含められないため） |
| `TestEffectivenessCoreTests` | ユニットテストと、`Tests/Fixtures` に対する統合テスト |

## パイプライン

解析全体は `Analyzer.run()` が進めます。元のプロジェクトは変更せず、すべてコピーの中で行います。

パイプラインは、共通のステージと、その間に並ぶ手法の層でできています。層は安いものから高いものの順に並べ、各層が次の層の実行対象を絞り込みます（[漏斗としての手法](docs/ja/concepts.md#漏斗としての手法) を参照）。

| # | ステージ | 種類 | ファイル |
|---|---|---|---|
| 1 | ソースファイルを列挙する。`swift package describe` のテスト以外のターゲット、またはカスタムモードでは `--source-dir`。`--exclude` を適用する | 共通 | `Analyzer.swift` |
| 2 | SwiftSyntax で宣言を発見し、各層がそれをどう解析するか（または対象外の理由）を決める。本体がログ出力だけの宣言もここで対象外にする（`AridDetection.swift`）。`--since` 指定時は、変更行と重なる宣言だけを残す | 共通 | `MethodDiscovery.swift`, `MutationOperators.swift`, `AridDetection.swift`, `GitDiff.swift` |
| 3 | プロジェクトを `<package>/.build/test-effectiveness/project` にコピーし、必要な層のためにコピーを準備する | 共通 | `Analyzer.swift`, `SchemataRewriter.swift` |
| 4 | **1 回だけ** ビルドする（`swift build --build-tests --enable-code-coverage --enable-index-store`、またはカスタムのビルドコマンド） | 共通 | `Analyzer.swift` |
| 5 | 静的参照層：ビルドが書き出したインデックスを読み、referenced 列を埋める | 層 | `References.swift` |
| 6 | 変更前の振る舞いでテストを実行する（ベースライン）。失敗したら中止する | 共通 | `Analyzer.swift` |
| 7 | カバレッジ層：ベースラインのカバレッジを読み、executed 列を埋める | 層 | `Coverage.swift` |
| 8 | 極端ミューテーション層：実行されたメソッドのミュータントごとに、そのミュータントを有効にしてテストを実行し、verified 列を埋める | 層 | `Analyzer.swift`, `ProcessRunner.swift` |
| 9 | 列を宣言ごとの指摘にまとめ、レポートを生成する | 共通 | `Models.swift`（`Classifier`）, `Reporter.swift` |

`--dry-run` はステージ 2（`Analyzer.plan()`）で止まります。

作業ディレクトリの詳細：

- コピー側の `.build` は実行をまたいで残すので、2 回目以降はインクリメンタルにビルドされ、依存パッケージのチェックアウトも再利用される。`.git`、`.swiftpm`、`DerivedData`、`xcuserdata` はコピーしない。
- ビルド、ベースライン、各テスト実行のログは `.build/test-effectiveness/logs` に書き出す。

## 層

### 静的参照

ビルドはインデックスストアを `<bin path>/index/store` に書き出します。`--index-store-path` を指定すると、そちらを使います。

`ReferenceColumn` は、このストアを [IndexStoreDB](https://github.com/swiftlang/indexstore-db) で開きます。

- `libIndexStore.dylib` は、`swift` 実行ファイルのツールチェーンから読み込みます。
- データベースは `.build/test-effectiveness/index-db` に置き、実行のたびに作り直します。

処理の流れ：

- **テストファイルとスコープを見つける。** テストファイルは、プロジェクト内のファイルのうち、`XCTest` か `Testing` を import していて本番ソースではないものです。`TestScopeFinder` は、その中のテスト宣言を SwiftSyntax でスコープにまとめます。
- **スコープごとに参照を集める。** `ReferenceResolver` は、スコープごとに、参照しているメンバーと、名前が出ている具体型を集めます。テストターゲットのコードへの呼び出しは辿り、本番コードへの呼び出しは辿りません。
- **動的な呼び出しを解決する。** 動的な呼び出し（`dynamic` ロール）は、`overrideOf` の関係を使って、名前が出ている型ごとの実装に解決します。
  - スーパークラスは `baseOf` で辿ります。
  - extension は `extendedBy` で、拡張している型に対応付けます。
  - どの準拠型が protocol extension のデフォルト実装を使っているかは、暗黙の `overrideOf` から分かります。
- **メソッドと対応付ける。** メソッドとインデックスは、宣言の先頭から本体の `{` までの行にある定義で対応付けます。computed property の場合は、プロパティとその getter です。

この層が失敗しても解析は止まりません。インデックスがなければ列は unknown になります。また、この層は後段の層の対象を絞りません。どのテストからも参照されていないメソッドでも、実行され、検証されていることがあるためです。

### カバレッジ

ベースラインを `--enable-code-coverage` 付きで実行し、出力された `llvm-cov export` の JSON を `CoverageMap` に読み込みます。各関数は、本体の開き括弧 `{` の位置で宣言に対応付けます。カバレッジがない、または読めない場合は列が不明になり、後段の層は全宣言に対して実行されます。列は宣言ごとに保持し（`MethodResult.executed`）、`ExecutionStatus.resolve` がミュータントの結果と合わせて決めます。殺されたミュータントがあれば、カバレッジより優先します。

### 極端ミューテーション

ミュータントごとに、`STE_MUTANT=<id> swift test --skip-build`（またはカスタムのテストコマンド）をタイムアウト付きで実行します。タイムアウトはベースラインの所要時間 × `--timeout-factor`（下限 `--minimum-timeout` 秒）です。ミュータント実行時のプロファイルデータは別ファイルに書き出すので、ベースラインのカバレッジを上書きしません。

#### Mutant schemata

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

書き換えで守るべき不変条件：

- **行番号が元のソースと一致する。** 挿入はすべて既存の行の中で行う。そのため、カバレッジ（llvm-cov の関数リージョンは本体の `{` から始まる）をそのまま元の宣言に対応付けられ、コンパイルエラーの行番号も元のソースと同じになる。挿入は列を右にずらすだけなので、1 行に複数の関数が始まる場合の `CoverageMap.wasExecuted` の対応付けはこれを前提にしている。コピーを書き換える層を他に足す場合も、この不変条件を守る必要がある。
- **単一式の本体には明示的な `return` を補う。** `if`/`switch` 式も同様だが、内部に `return` 文を含む場合は文として扱う。
- **スイッチはファイル単位。** `__steActiveMutant` は各ファイルの末尾に `nonisolated fileprivate let` として生成し、`getenv` で読む。ビルド設定やプロジェクトファイルを変更する必要がなく、`defaultIsolation(MainActor.self)` のモジュールでも動く。

これにより、ミュータントを入れられない宣言が生じます（[対象外](docs/ja/methods/extreme-mutation.md#対象外) を参照）。

- `@inlinable`、`@_transparent`、`@_alwaysEmitIntoClient` の本体からは `fileprivate` の宣言を参照できない。
- `main.swift` ではトップレベルコードが順に実行されるため、スイッチの初期化前にメソッドが呼ばれうる。
- result builder 外の `some View` は、挿入した分岐の両側で同じ具象型が必要になる。

カスタムモードでは、アクティブなミュータントを `STE_MUTANT` と `TEST_RUNNER_STE_MUTANT` の両方で渡します。`xcodebuild test` は `TEST_RUNNER_` 付きの環境変数をテストプロセスに転送するためです。

## テスト

- ユニットテストは、宣言の発見、ミューテーション演算子、書き換え、分類、レポートを対象にする。
- `Tests/Fixtures/SampleProject` は各指摘が 1 つ以上現れる小さなパッケージ。統合テストで各メソッドの指摘を検証する。
- `Tests/Fixtures/ReferencedProject` は referenced 列のためのパッケージ。protocol やスーパークラス経由の呼び出し、モックの注入、デフォルト実装、XCTestCase の `setUp()`、別のメソッド経由でしか実行されないメソッドを含む。
- `Tests/Fixtures/EdgeCases` は、if/switch 式、result builder、`throws`、actor、`defaultIsolation(MainActor)` など、書き換え後もコンパイルできなければならない構文の集まり。書き換え処理を変更するときはここにケースを足す。

## 手法を追加するとき

各手法は [docs/ja/concepts.md](docs/ja/concepts.md#3-つの列referenced--executed--verified) の列のどれかを埋めます。追加するときは次のようにします。

- `docs/methods/<name>.md`（と `docs/ja/methods/<name>.md`）に、何をするか、背景、結果、限界を書く。README の一覧にも加える。
- 実装方法は [層](#層) の下に節を足して書く。
- 結果は独立した列として持つ。他の列と合成してスコアにしない。
- コストに応じてパイプライン上の位置を決め、安い層が高い層の実行対象を絞り込むようにする。前段の列が不明なときにどう振る舞うかも決める。
