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
| 2 | SwiftSyntax で宣言を発見し、各層がそれをどう解析するか（または対象外の理由）を決める。本体がログ出力だけの宣言もここで対象外にする（`AridDetection.swift`）。`--since` 指定時は、変更行と重なる宣言だけを残す | 共通 | `MethodDiscovery.swift`, `MutationOperators.swift`, `SwitchCases.swift`, `AridDetection.swift`, `GitDiff.swift` |
| 3 | プロジェクトを `<package>/.build/test-effectiveness/project` にコピーし、必要な層のためにコピーを準備する | 共通 | `Analyzer.swift`, `SchemataRewriter.swift` |
| 4 | **1 回だけ** ビルドする（`swift build --build-tests --enable-code-coverage --enable-index-store`、またはカスタムのビルドコマンド） | 共通 | `Analyzer.swift` |
| 5 | 静的参照層：ビルドが書き出したインデックスを読み、referenced 列を埋める | 層 | `References.swift` |
| 6 | 変更前の振る舞いでテストを実行する（ベースライン）。失敗したら中止する | 共通 | `Analyzer.swift` |
| 7 | カバレッジ層：ベースラインのカバレッジを読み、executed 列を埋める | 層 | `Coverage.swift` |
| 8 | 極端ミューテーション層：実行されたメソッドのミュータントごとに、そのミュータントを有効にしてテストを実行し、verified 列を埋める | 層 | `Analyzer.swift`, `DirectTestLauncher.swift`, `ProcessRunner.swift` |
| 9 | 列を宣言ごとの指摘にまとめ、レポートを生成する | 共通 | `Models.swift`（`Classifier`）, `Reporter.swift` |

`--dry-run` はステージ 2（`Analyzer.plan()`）で止まります。

作業ディレクトリの詳細：

- コピーは消して作り直すのではなく、その場で更新する（`WorkspaceCopy.swift`）。変わっていないファイルには触れないので、ビルドシステムからは同じファイルに見え、そのファイルのための再ビルドは起きない。サイズと更新時刻がプロジェクト側と同じファイルは変わっていないとみなす（コピーは更新時刻を保つ）。ミュータントスキーマを書き込むファイルは、内容が新しいスキーマと同じなら変わっていないとみなす。
- ビルドがコピーの中に書き出したものは、実行をまたいで残る。依存パッケージのチェックアウトを含む `.build` や、`xcodebuild` に指定した DerivedData のディレクトリがこれにあたる。作業ディレクトリの `copied-files.json` に前回コピーしたファイルの一覧を持ち、一覧にあってプロジェクトからなくなったファイルはコピーから削除し、一覧にないファイルはビルドが書いたものとして残す。一覧がないとき（古いバージョンが作ったコピーや、コピーの途中で失敗した実行のあと）は、先に `.build` 以外をすべて削除する。
- コピーしないもの：プロジェクト直下の `.git`、`.swiftpm`、`DerivedData`、`xcuserdata` と、場所を問わず `.build`（プロジェクト内のパッケージや worktree のものも含む）。
- ビルド、ベースライン、各テスト実行のログは `.build/test-effectiveness/logs` に書き出す。

## 層

### 静的参照

ビルドはインデックスストアを `<bin path>/index/store` に書き出します。`--index-store-path` を指定すると、そちらを使います。

`ReferenceColumn` は、このストアを [IndexStoreDB](https://github.com/swiftlang/indexstore-db) で開きます。

- `libIndexStore.dylib` は、`swift` 実行ファイルのツールチェーンから読み込みます。
- データベースは `.build/test-effectiveness/index-db` に置き、実行をまたいで残します。IndexStoreDB は、ストアの中で変わったユニットだけを読み直します。開けなかったデータベースは削除して作り直します。

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

カスタムモードでは、ベースラインのテストコマンドがプロファイルを書き出します（`xcodebuild -enableCodeCoverage YES`）。`CoverageArtifacts` は、`--coverage-profdata` の下からベースラインより古くない最新の `.profdata` を、`--coverage-binary` の下から Mach-O ファイルすべて（`.dSYM` バンドルの中は除く）を選びます。カバレッジデータのないバイナリが 1 つでもあると複数バイナリをまとめた export は失敗するので、バイナリごとに `xcrun llvm-cov export` を実行してマップをマージします。関数は、どれかのバイナリで実行されていれば実行済みとみなします。

### 極端ミューテーション

ミュータントごとに、環境変数 `STE_MUTANT=<id>` を付けてテストをタイムアウト付きで実行します。Swift パッケージでは直接起動したテストバンドル（[直接起動](#直接起動) を参照）か `swift test --skip-build`、それ以外ではカスタムのテストコマンドです。タイムアウト（`RunTimeout.swift`）は、その実行にかかる見込みの時間から決めます。全テストではベースラインの所要時間、選んだスコープでは `scopesFailingAlone` が各スコープを単独で流して測った時間の合計（全テストのタイムアウトは超えません）に `--timeout-factor` を掛け、`--minimum-timeout` 秒を下限とします。オプションを指定しないときの下限は 30 秒で、テストバンドルを直接起動するときは 5 秒です。実行ごとの固定コストが小さく、失敗する実行も通る実行と同じ速さで終わるのは、直接起動のときだけだからです。ミュータント実行時のプロファイルデータは別の場所に書き出すので、ベースラインのカバレッジを上書きしません。

#### 直接起動

`DirectTestLauncher.swift`。`swift test --skip-build` は、テストを始める前にパッケージを読み込んでビルドを計画するので 1 回あたり約 1 秒かかり、`.build` もロックします。そこでベースラインより後の実行では、`swift test` が最後にしていることだけを行います。ビルドの bin パスにあるテストバンドル（テストターゲットごとの `<target>.xctest`。古いビルドシステムでは `<Package>PackageTests.xctest`）ごとに、XCTest 用に `xctest <bundle>` を、Swift Testing 用に `swiftpm-testing-helper --test-bundle-path <binary> … --testing-library swift-testing` を起動します。

- プロセスには、プラットフォームの `XCTest.framework` と `Testing.framework` を読み込めるよう `DYLD_FRAMEWORK_PATH` と `DYLD_LIBRARY_PATH` を渡します。`/bin/sh` は保護されたバイナリで `DYLD_*` を落とすので、`ProcessRunner` はこれらのコマンドをシェルを通さずに起動します（`withoutShell`、`posix_spawn_file_actions_addchdir_np`）。
- `xctest` には `SWIFT_TESTING_ENABLED=0` を渡します。渡さないと、バンドルの Swift Testing のテストも実行します。
- テスト選択は、型のセレクタを `-XCTest <Module>.<Type>,…` に、Swift Testing 用には `--filter` に変換し、選ばれたモジュールのバンドルだけを起動します。Swift Testing は一致するテストがないと 69 で終了しますが、これは失敗として扱いません。
- 1 回の実行は、最初に失敗したプロセスで打ち切ります。タイムアウトは、その実行のプロセスすべての合計に対するものです。
- `verify` は、ミューテーションなしで全テストを 1 回流し、ベースラインの出力と比べます（`TestOutput.executedTests`：開始した XCTest のテストケース数と、Swift Testing が報告するテスト数の合計）。実行が通り、同じ数のテストを実行したときだけ直接起動を使います。起動のしかたが誤っていると、すべてのミュータントが検出されたように見えたり（バンドルを読み込めない）、生き残ったように見えたり（テストが 1 つも流れない）するためです。テストを 1 つも実行しなかったパスは以後起動しないので、片方のライブラリのテストしかないバンドルは 1 回の実行につき 1 プロセスで済みます。

ベースラインは `swift test` のままです。カバレッジデータのマージも `swift test` が行うためです。`--test-filter`（XCTest に正規表現を適用するにはテストの一覧が必要）や `--no-direct-launch` を指定したとき、またはチェックに通らなかったときは、すべての実行を `swift test` 経由で流します。

#### 並列実行

`Analyzer.runMutants` がミュータントを `--jobs` 個のワーカーで流します（`DispatchQueue.concurrentPerform`）。各ワーカーは `Mutex` で守った共有のインデックスから次のミュータントを取り、結果は元の位置に戻すので、レポートは実行順に左右されません。`CommandTemplate` は `{job}` をワーカーの番号に、`{result-bundle}` を `<作業ディレクトリ>/results/<ログ名>.xcresult` に置き換えます。このパスは実行前に削除し、ベースラインのもの以外は実行後にも削除します。エラーが起きたら、ワーカーはそれ以上ミュータントを取りません。Swift パッケージでは、`swift test` 経由の実行は `.build` をロックするため常に 1 つずつ流し、直接起動したテストバンドルはワーカーを使います。

#### テスト選択

`TestSelection.swift`。テストスコープはインデックスから得ます。静的参照の層がインデックスを読むとき、`ReferenceColumn` がすべてのスコープを `TestSelector` として列挙します（モジュールはインデックスから、型名や関数名は `TestScopeFinder` から取ります）。

どのスコープがメソッドを実行するかは、実際に記録します。`scopesFailingAlone`（後述）の各実行に `STE_REACHED` で `<作業ディレクトリ>/reached` のファイルを渡すと、その実行が通ったメソッドをミュータントスキーマがファイルに追記します（[Mutant schemata](#mutant-schemata) を参照）。`selectableTests` はこのファイルから、メソッドごとにそれを実行したスコープ（`RecordedReach.scopes`）を作ります。何も記録されなかったときは、インデックスで代用します（`ReferenceAnalysis.reachingTests`。インデックスの読み取りの中で飛び抜けて重い処理なので、このときにだけ計算します）。`ReferenceColumn` は各テストスコープからの呼び出しを本番コードの中まで辿り（`ReferenceResolver.referencedSymbols(scope:throughProductionCode:)`。動的な呼び出しはスコープに限った RTA で同じように解決します）、メソッドごとに、そこに届くスコープを返します。

ミュータントはまずこのスコープに対して流します（直接起動したテストバンドルでは `-XCTest` と `--filter`、そうでなければ `swift test --filter`、カスタムモードでは `{only-testing}` を `-only-testing:` に展開）。すり抜けたミュータントを全テストでも流すかどうかは、`RecordedReach.coversSuite` で決まります。

- メソッドを一度も呼ばないテストは、ミュータントがあってもなくても同じコードを実行します。そのため、テストスイートのすべてのテストが記録済みのスコープに属していれば、メソッドを実行したスコープをすり抜けたミュータントは全テストもすり抜けるので、流し直しません。スコープはインデックスとテストのソースから求めるので、テストを取りこぼす可能性があります。そこで、すべてのスコープを選ぶことができて単独で通り、合計でベースラインと同じ数のテストを実行した（`TestOutput.executedTests`）ときに限ります。`--rerun-survivors` を指定すると、これにかかわらず全テストを流します。
- それ以外の場合と、インデックスから求めたスコープを使う場合は、必ず全テストを流すので、結果は全テストを流した場合と同じです。報告する所要時間は両方の合計です。

ミュータントを流す前に、`selectableTests` がすべてのセレクタをミューテーションなしで 1 回流し、選ぶと失敗するモジュールを外します。選択の失敗（`xcodebuild` が知らないターゲットなど）は、ミュータントが検出されたように見えてしまうためです。

続いて `scopesFailingAlone` が、残ったセレクタをそれぞれ単独で、ミューテーションなしで `--jobs` のワーカーで流します（スコープごとに 1 回。スコープが 1 つだけなら、前のチェックで単独で流しているので省きます）。単独で失敗するスコープは、先に流れるテストに依存しているか、ほかのテストと状態を共有しているので、単独で選ぶとミュータントが検出されたように見えてしまいます。そのようなスコープは選びうる集合から外すので、それしか届かないミュータントは全テストを流します。また `AnalysisReport.testsFailingAlone` に入れ、`Reporter` が宣言ごとの結果とは別の、テストについてのセクションとして出力します（テスト選択が無効でチェックを行わなかったときは `nil`）。これはテスト選択の制限ではなく、テストについての指摘です。実行順に依存するテストは、それ自体が壊れやすいからです。

記録されるのは、各スコープを単独で流したときに通ったメソッドです。全テストで流した場合と食い違いうるのは次の 2 つで、これが全テストを省くことの限界です。ほかのテストが先に流れたときにだけメソッドを実行するスコープ。そして、メソッド自体は呼ばないのに、ミュータントのせいで先のテストが残した状態によって失敗するテスト。どちらも互いに依存するテストで、そのようなテストスイートのために `--rerun-survivors` があります。

インデックスから求めたスコープがメソッドを実行するテストを漏れなく含むのは、インデックスから呼び出しが見える範囲に限られます。インデックスが解決できない呼び出し（保存して後で呼ぶクロージャ、フレームワークからのコールバックなど）があると選ぶテストが減りますが、それで増えるのは全テストを流す回数だけで、結果は変わりません。

#### Mutant schemata

ミュータントごとにビルドし直すと遅いので、全ミュータントを 1 つのバイナリに埋め込み、実行時に環境変数で切り替えます（Untch, Offutt & Harrold 1993, *Mutation Analysis Using Mutant Schemata*）。

```swift
// 元のコード
func add(_ a: Int, _ b: Int) -> Int {
    a + b
}

// mutant schema
func add(_ a: Int, _ b: Int) -> Int { switch __steActiveMutant { case 1: return 0; case 2: return 1; case -2: __steReached(1); default: break };
    return a + b
}

// result builder の場合
var body: some View { if __steMutantIs(7) { EmptyView() } else {
    Text("Hello")
} }

// result builder 外の `some View` の場合
func badge() -> some View { func __steOriginal() -> some View {
    return Circle().frame(width: 8)
}; return __steMutantIs(8) ? ViewBuilder.buildEither(first: EmptyView()) : ViewBuilder.buildEither(second: __steOriginal()) }
```

書き換えで守るべき不変条件：

- **行番号が元のソースと一致する。** 挿入はすべて既存の行の中で行う。そのため、カバレッジ（llvm-cov の関数リージョンは本体の `{` から始まる）をそのまま元の宣言に対応付けられ、コンパイルエラーの行番号も元のソースと同じになる。挿入は列を右にずらすだけなので、1 行に複数の関数が始まる場合の `CoverageMap.wasExecuted` の対応付けはこれを前提にしている。コピーを書き換える層を他に足す場合も、この不変条件を守る必要がある。
- **単一式の本体には明示的な `return` を補う。** `if`/`switch` 式も同様だが、内部に `return` 文を含む場合は文として扱う。
- **opaque 型を返す本体はローカル関数に入れる。** `some View` を返すメソッドでは、すべての `return` が同じ具象型でなければならないので、元の本体の前でミュータントが `return` することはできない。そこで本体をローカル関数 `__steOriginal` に移す。元の `return` はその中に閉じ、メソッドの `return` は 1 つになる。`buildEither` は view builder の `if`/`else` が変換される先なので、型は result builder のスキーマと同じになる。ローカル関数にはメソッドの `async` と `throws` をそのまま付ける。本体に `return` がなければ `@ViewBuilder` にする。`ViewModifier.body(content:)` のような要件では、属性を書かなくても本体が view builder になり、明示的な `return` があるとそれが無効になる。`return` のない本体は、どちらの場合も builder として有効である。同じ理由で、明示的に `return` する `var body` や `@ViewBuilder` の本体も、builder の中でしかコンパイルできない `if`/`else` のスキーマではなく、このスキーマにする。
- **スイッチはファイル単位。** `__steActiveMutant` は各ファイルの末尾に `nonisolated fileprivate let` として生成し、`getenv` で読む。ビルド設定やプロジェクトファイルを変更する必要がなく、`defaultIsolation(MainActor.self)` のモジュールでも動く。
- **スイッチは記録も兼ねる。** 環境変数に `STE_REACHED=<ファイル>` があると、どのミュータントも有効にならず、スイッチの値は `-2` になる。各メソッドの `case -2`（`some View` では `__steMutantIs`）が、そのメソッドの最初のミュータントの ID を渡して `__steReached` を呼び、メソッドが最初に実行されたときに ID を 1 行としてファイルに追記する。書き出し済みかどうかは、ファイルごとに持つミュータント ID 1 つにつき 1 バイトの領域で覚える。書き込みは `O_APPEND` で開いたディスクリプタへの `write(2)` 1 回なので、1 回の実行の複数のプロセスやスレッドが同じファイルを共有でき、クラッシュしても記録は失われない。`STE_REACHED` がなければ、追加した case のコストはない。

これにより、ミュータントを入れられない宣言が生じます（[対象外](docs/ja/methods/extreme-mutation.md#対象外) を参照）。

- `@inlinable`、`@_transparent`、`@_alwaysEmitIntoClient` の本体からは `fileprivate` の宣言を参照できない。
- `main.swift` ではトップレベルコードが順に実行されるため、スイッチの初期化前にメソッドが呼ばれうる。
- `rethrows` の関数が返す `some View`。ローカル関数は throw する引数を自分では持たないので、`rethrows` にできない。

カスタムモードでは、アクティブなミュータントを `STE_MUTANT` と `TEST_RUNNER_STE_MUTANT` の両方で渡します。`xcodebuild test` は `TEST_RUNNER_` 付きの環境変数をテストプロセスに転送するためです。`STE_REACHED` も同じように渡します。

#### case のミュータント

`--case-mutants` を指定すると、`MethodDiscovery` が `SwitchCases.discover` を呼び、本体の末尾にある switch の case を求めます（`DiscoveredMethod.cases`）。対象になる switch と case は [switch の case](docs/ja/methods/extreme-mutation.md#switch-の-case) を参照してください。戻り値型に最も単純な値がないメソッドは、`.mutate([])` として残します。メソッド自身のミュータントはなく、case のミュータントだけを持ちます。

`Analyzer.run()` は、メソッドの case のミュータントに、メソッド自身のミュータントの次の ID を割り当てます。`SchemataRewriter` はそれを各 case の先頭（ラベルのコロンの直後）に入れます。

```swift
// switch 文：各 case の先頭に、ミュータントの switch を置く
func isBusy(_ state: LoadState) -> Bool { switch __steActiveMutant { case 1: return true; case 2: return false; case -2: __steReached(1); default: break };
    switch state {
    case .loading: switch __steActiveMutant { case 3: return false; case -2: __steReached(3); default: break };
        return true
    default: switch __steActiveMutant { case 4: return true; case -2: __steReached(4); default: break };
        return false
    }
}

// switch 式：各 case の式を `if` 式で包む
func title(for state: LoadState) -> String { switch __steActiveMutant { case 5: return ""; case 6: return "A"; case -2: __steReached(5); default: break };
    return switch state {
    case .idle: if __steMutantIs(7) { "" } else if __steActiveMutant == 8 { "A" } else { "Idle" }
    case .loading: if __steMutantIs(9) { "" } else if __steActiveMutant == 10 { "A" } else { "Loading" }
    }
}

// 最も単純な値がない戻り値型：各 case が別の case と同じことをする
func tint(for state: LoadState) -> Tint {
    switch state {
    case .idle: if __steMutantIs(11) { fallthrough }; return .gray
    case .failed: if __steMutantIs(12) { return .gray }; return .red
    }
}
```

- **switch 式は式のままにする。** case の式の前に文を置くと switch は文になり、すべての case に `return` が必要になる。しかし `return` は、戻らない関数の呼び出しの前には書けない（`return unreachable()` はコンパイルできず、どの呼び出しが戻らないかはコンパイラにしか分からない）。そこで、ミュータントは case の式を包む `if` 式の分岐にする。case が何に評価されるか（値、`throw`、戻らない呼び出し）にかかわらず、最後の分岐の中でも元と同じように有効である。最初の条件の `__steMutantIs` が case の実行を記録する。
- **`fallthrough` は case の中に直接置く。** `__steActiveMutant` の switch の中に置くと、その switch の次の case に落ちてしまう。そのため `otherCase` のミュータントは `if __steMutantIs(id) { … }` の形にする。別の case の文はラベルと同じ行に挿入するので、行番号は変わらない。switch 式では fallthrough できないので、相手の case からは必ず式を借りる。
- **各 case は実行されたことを記録する。** メソッドと同じ方法で、その case の最初のミュータントの ID で記録する。そのため `RecordedReach.scopes` には case を実行するテストスコープも入り、case のミュータントはそれらに対して流す。

case のミュータントは、本体全体のミュータントの後に、`runMutants` の 2 巡目として流します。どのメソッドの case を流すかは、1 巡目の結果で決まります。`CaseResult` が case ごとの結果を持ち、`Classifier.classify(_:cases:)` がメソッドの結果と合わせて分類します。

## テスト

- ユニットテストは、宣言の発見、ミューテーション演算子、書き換え、分類、レポートを対象にする。
- `Tests/Fixtures/SampleProject` は各指摘が 1 つ以上現れる小さなパッケージ。統合テストで各メソッドの指摘を検証する。
- `Tests/Fixtures/ReferencedProject` は referenced 列のためのパッケージ。protocol やスーパークラス経由の呼び出し、モックの注入、デフォルト実装、XCTestCase の `setUp()`、別のメソッド経由でしか実行されないメソッドを含む。
- `Tests/Fixtures/HangingProject` は、ループが終わらなくなるミュータントを持つパッケージ。統合テストで、選んだテストの短いタイムアウトのあとにタイムアウトとして報告されることを確認する。
- `Tests/Fixtures/SwitchProject` は、ロジックが switch になっているメソッドを集めたパッケージ。どれも本体全体のミュータントでは `tested` になるか、解析対象外になる。統合テストで、`--case-mutants` がどの case を報告するかを検証する。
- `Tests/Fixtures/EdgeCases` は、if/switch 式、result builder、result builder 外の `some View`、`throws`、actor、`defaultIsolation(MainActor)` など、書き換え後もコンパイルできなければならない構文の集まり。書き換え処理を変更するときはここにケースを足す。

## 手法を追加するとき

各手法は [docs/ja/concepts.md](docs/ja/concepts.md#3-つの列referenced--executed--verified) の列のどれかを埋めます。追加するときは次のようにします。

- `docs/methods/<name>.md`（と `docs/ja/methods/<name>.md`）に、何をするか、背景、結果、限界を書く。README の一覧にも加える。
- 実装方法は [層](#層) の下に節を足して書く。
- 結果は独立した列として持つ。他の列と合成してスコアにしない。
- コストに応じてパイプライン上の位置を決め、安い層が高い層の実行対象を絞り込むようにする。前段の列が不明なときにどう振る舞うかも決める。
