# swift-test-effectiveness

[English](README.md) | 日本語

Swift プロジェクトのテストスイートの effectiveness（故障を検出する力）を調べ、フィードバックするツールです。

結果は 1 つのスコアではなく宣言単位で示します。宣言ごとに、テストの何が欠けているか（実行されていない、実行されているが検証されていない、など）と、何をすべきかを報告します。

現在は、メソッドごとに次の 3 つを報告します。

- どのテストがそのメソッドを直接参照しているか。コンパイラのインデックスから調べます。
- どのテストも実行しないメソッド。カバレッジで見つけます。
- 実行されているが検証されていないメソッド。極端ミューテーションで見つけます。

極端ミューテーションでは、各メソッドの本体を戻り値型にとって最も単純な振る舞い（空の本体、`nil`、`true`/`false` …）に置き換え、それでもテストが全て通るものを **pseudo-tested** と報告します。

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

## なぜ必要か

カバレッジが示すのはコードが *実行された* ことだけで、間違っていたらどれかのテストが落ちるかどうかは分かりません。テストが故障を検出するには、故障箇所が実行され、故障がプログラムの状態を汚染し、その汚染がアサーションまで届く必要があります。戻り値を一切アサートしないテストは、カバレッジ 100% でも何も検出しません。

このツールは、この連鎖の別々の部分を確かめる手法を組み合わせ、宣言ごとにテストがどの部分を欠いているかを報告します。**集計スコアは出しません**。モデルとこの設計の理由は [基本概念](docs/ja/concepts.md) を参照してください。

## レポートの読み方

宣言は、テストに何が欠けているかでグループ分けされ、それぞれに次にやるべきことが付きます。現在のグループ：

| グループ | 欠けているもの | 検出手段 | 対処 |
|---|---|---|---|
| `not-covered` | どのテストもメソッドを実行しない | [カバレッジ](docs/ja/methods/coverage.md) | テストを書く |
| `pseudo-tested` | テストは実行するが、何をしているかを誰も確かめていない | [極端ミューテーション](docs/ja/methods/extreme-mutation.md) | 振る舞いを確かめるアサーションを足す |
| `partially-tested` | 振る舞いの一部しか確かめていない | [極端ミューテーション](docs/ja/methods/extreme-mutation.md) | フィードバックに書かれたケースを足す |
| `tested` | 見つからなかった | — | なし |
| *Not analyzed* | 解析できない（理由を表示） | — | — |

各メソッドには [referenced](docs/ja/methods/static-references.md) 列も付きます。テストがそのメソッドを直接参照しているかどうかを示す列です。対処が変わる場合は、レポートに注記を付けます。

- `pseudo-tested` で、どのテストも直接呼んでいないメソッド：どこか別の場所にアサーションを足すのではなく、そのメソッド自身のテストが必要です。
- `not-covered` だが、テストからは参照されているメソッド：スキップされたテスト、モックの注入、別の型へのディスパッチのどれかを示しています。

モックを注入したテストは、本物の実装を参照したことになりません。protocol 経由の呼び出しは、同じテスト（または XCTestCase や suite）が名前を出している具体型の実装にだけ数えます。

## 動作要件

- macOS 26 以降
- `--since` を使う場合のみ git リポジトリ
- Swift 6.2 以降（Xcode 26 以降）。動作確認は Swift 6.4（Xcode 27）で行っています。
- 選択中の Xcode の macOS SDK に合った Swift ツールチェーン。swift.org や swiftly で入れたツールチェーンがその SDK より古いと、パッケージのマニフェストをコンパイルできません。`swift build` が `unknown argument: '-target-arch-variant'` を出してコンパイラがクラッシュします。この場合は Xcode のツールチェーンを使ってください（`xcrun swift`、または `xcode-select` が Xcode を指していれば `/usr/bin/swift`）。

解析に使う `swift`（`--swift`）は対象プロジェクトのビルドとテストにも使い、インデックスもそのツールチェーンの `libIndexStore.dylib` で読みます。そのため、同じ条件が当てはまります。

## インストール

ソースからビルドし、`PATH` の通った場所にコピーします。

```bash
git clone https://github.com/elmetal/swift-test-effectiveness.git
cd swift-test-effectiveness
git checkout 0.0.1
swift build -c release
cp .build/release/swift-test-effectiveness /usr/local/bin/
```

インストールしたバージョンは `swift-test-effectiveness --version` で確認できます。

## 使い方

### Swift Package

```bash
swift-test-effectiveness /path/to/package
```

プロジェクトを `<package>/.build/test-effectiveness` にコピーしてそこで解析するので、元のソースは変更しません。最初に、変更していないコードでテストスイートが通る必要があります（ベースライン）。通らなければ解析を中止します。パイプラインは [ARCHITECTURE.ja.md](ARCHITECTURE.ja.md#パイプライン) を参照してください。

### 主なオプション

| オプション | 説明 |
|---|---|
| `--since <rev>` | `<rev>` 以降に変更された行と重なる宣言だけを解析する。行が削除された宣言と、まだ git に追加していない新しいファイルも含む（PR 用） |
| `--target <name>` | 指定ターゲットのみ（複数可） |
| `--test-filter <pattern>` | `swift test --filter` に渡す |
| `--exclude <substring>` | パスに文字列を含むファイルを除外（複数可） |
| `--swift <path>` | 使用する `swift` 実行ファイル |
| `--dry-run` | ビルドも実行もせず、解析対象の一覧だけを表示する |
| `--format text\|markdown\|json` | レポート形式（markdown は PR コメント向け。JSON は後述） |
| `-o, --output <file>` | レポートをファイルに書き出す |
| `--fail-on-pseudo-tested` | pseudo-tested メソッドがあれば終了コード 1 |

特定の手法向けのオプション：

| オプション | 手法 | 説明 |
|---|---|---|
| `--no-index` | 静的参照 | コンパイラのインデックスを書き出さず、読まない。referenced 列は unknown になる |
| `--index-store-path <path>` | 静的参照 | 読み込むインデックスストア（パッケージではビルドが書き出すものが既定。カスタムモードでは必須） |
| `--no-coverage` | カバレッジ | カバレッジを取得せず、後段の手法を全宣言に対して実行する |
| `--coverage-profdata <path>` | カバレッジ | カスタムモード：テストコマンドが書き出す `.profdata`、またはその最新のものを探すディレクトリ |
| `--coverage-binary <path>` | カバレッジ | カスタムモード：カバレッジ付きでビルドしたバイナリ、またはバイナリを探すディレクトリ（複数指定可） |
| `--throw-mutants` | 極端ミューテーション | 型指定なしの `throws` メソッドに `throw` するミュータントを追加 |
| `--no-arid` | 極端ミューテーション | 本体がログ出力だけの `Void` メソッドも解析する（既定では対象外。[対象外](docs/ja/methods/extreme-mutation.md#対象外) を参照） |
| `--arid-call <name>` | 極端ミューテーション | この関数の呼び出しもログ出力とみなす。例：`track`、`Analytics.shared.track`（複数可） |
| `--jobs <n>` | 極端ミューテーション | カスタムモード：同時に流すテストコマンドの数（[並列実行](#並列実行) を参照） |
| `--timeout-factor`, `--minimum-timeout` | 極端ミューテーション | ミュータントごとのテスト実行のタイムアウト（ベースライン時間 × 係数、下限秒数） |
| `--no-test-selection` | 極端ミューテーション | [メソッドに届くテストを先に流す](#テスト選択) のをやめ、ミュータントごとに常に全テストを流す |

終了コード：`0` 成功、`1` `--fail-on-pseudo-tested` に該当、`2` ビルド失敗やベースライン失敗など、`128 + シグナル番号` 中断（Ctrl-C なら `130`）。中断したときは、実行中のビルドやテストのコマンドも止めます。

JSON レポートの先頭には `schemaVersion` と `toolVersion` が入ります。`schemaVersion` はフィールドの削除・名前変更・意味の変更があったときに上がります。フィールドの追加では上がらないので、知らないキーは無視してください。

### Xcode プロジェクトなど（カスタムモード）

`--source-dir`、`--build-command`、`--test-command` を指定すると、任意のビルドシステムで動きます。コマンドはコピーしたプロジェクト内で `/bin/sh -c` で実行されます。

```bash
swift-test-effectiveness /path/to/App \
  --source-dir App \
  --build-command "xcodebuild build-for-testing -scheme App -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.2'" \
  --test-command  "xcodebuild test-without-building -scheme App -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.2'"
```

テストコマンドはミュータントごとに実行され、アクティブなミュータントは `STE_MUTANT` と `TEST_RUNNER_STE_MUTANT` の両方で渡されます（`xcodebuild test` は `TEST_RUNNER_` 付きの環境変数をテストプロセスに転送します）。

ほかの手法には、ビルドとテスト実行が書き出すファイルが必要です。DerivedData の場所を決めてビルドし（相対パスはコピー先のプロジェクトを基準に解決します）、それぞれのファイルを渡します。

```bash
swift-test-effectiveness /path/to/App \
  --source-dir App \
  --build-command "xcodebuild build-for-testing -scheme App -derivedDataPath build -enableCodeCoverage YES -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.2'" \
  --test-command  "xcodebuild test-without-building -scheme App -derivedDataPath build -enableCodeCoverage YES -collect-test-diagnostics never -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.2' {only-testing}" \
  --index-store-path build/Index.noindex/DataStore \
  --coverage-profdata build/Build/ProfileData \
  --coverage-binary build/Build/Products
```

- `--index-store-path`：referenced 列（[テストからの静的な参照](docs/ja/methods/static-references.md#インデックスが使えないとき) を参照）と [テスト選択](#テスト選択) に使います。
- `{only-testing}`：[テスト選択](#テスト選択) に使います。
- `-collect-test-diagnostics never`：ほとんどのミュータントはテストを失敗させます。xcodebuild は既定でそのたびに診断情報を集めるので、手元の計測では失敗する実行が 5 秒ではなく 39 秒かかりました。
- `-enableCodeCoverage YES`、`--coverage-profdata`、`--coverage-binary`：executed 列に使います。ベースラインの後、ベースラインが書き出した最新の `.profdata` を読み、`--coverage-binary` の下にある Mach-O バイナリそれぞれのカバレッジを `xcrun llvm-cov export` で取り出します。カバレッジデータのないバイナリは飛ばします。カバレッジがないと、どのテストも実行しないメソッドは `not-covered` ではなく `pseudo-tested` として報告され、そのミュータントも流れます。

### テスト選択

ミュータントごとにテストを流すので、テストが多いと解析に時間がかかります。そこでツールは、各ミュータントについてまずそのメソッドを実行しうるテストだけを流し、それをすり抜けたミュータントについてだけ全テストを流します。選んだテストで失敗するテストは全テストでも失敗するので、結果は毎回全テストを流した場合と同じで、変わるのは時間だけです。多くのミュータントは選んだテストで検出されます。

- 選ぶテストは、コンパイラのインデックス上でメソッドのシンボルに届くテストスコープ（XCTestCase のサブクラス、スイート、トップレベルの `@Test` 関数）です。テストヘルパーと本番コードの中の呼び出しも辿ります。どのテストも届かないメソッドと、すべてのテストが届くメソッドは、最初から全テストを流します。
- インデックスが必要です。SwiftPM では既定で有効です（`--test-filter` を指定した場合は無効）。カスタムモードでは、テストコマンドに `{only-testing}` があるときに有効になります。`{only-testing}` は `'-only-testing:<モジュール>/<型>'` と `'-only-testing:<モジュール>/<関数>()'` に置き換わります（全テストを流すときは空になります）。
- ミュータントを流す前に、選びうるテストすべてをミューテーションなしで 1 回流します。これが失敗した場合は、テストモジュールごとに試し、それでも失敗するモジュールは選びません（スキームに含まれないターゲット、モジュール名とターゲット名が違うターゲットなど）。ログは `selection-check*.log` です。
- 最後に、選んだテストで検出できたミュータントの数と、全テストを流し直したミュータントの数をログに出します。

### 並列実行

カスタムモードでは、`--jobs <n>` で最大 `n` 個のテストコマンドを同時に流します。各ミュータントは、空いたワーカーが順に受け持ちます。実行どうしがぶつからないよう、プレースホルダが 2 つあります。

- `{job}` はワーカーの番号（`1`〜`n`）に置き換わります。シミュレータは一度に 1 つのテストしか流せないので、ワーカーごとに別のシミュレータを使います（例：`STE-1`〜`STE-n` という名前のクローン）。
- `{result-bundle}` は、その実行用の新しい result bundle のパスに置き換わります。xcodebuild は既定の result bundle に実行開始の秒で名前を付けるので、同時に始まった実行どうしがぶつかります。既存のパスも受け付けません。

```bash
for n in 1 2 3 4; do xcrun simctl clone "iPhone 17" "STE-$n"; done

swift-test-effectiveness /path/to/App \
  --jobs 4 \
  --test-command "xcodebuild test-without-building -scheme App -derivedDataPath build -enableCodeCoverage YES -collect-test-diagnostics never -destination 'platform=iOS Simulator,name=STE-{job},OS=26.2' -resultBundlePath {result-bundle} {only-testing}" \
  …
```

ベースラインとテスト選択の事前チェックは、ワーカー 1 として単独で流します。result bundle は `<作業ディレクトリ>/results` に書き出し、ベースラインのものだけ残します。タイムアウトはほかの実行がない状態で測ったベースラインの時間をもとにするので、マシンの負荷が高いときは `--timeout-factor` を上げてください。

`--jobs` はカスタムモード専用です。`swift test` は `.build` をロックするため、実行を重ねられません。

### CI での例

```bash
swift-test-effectiveness . --since origin/main --format markdown -o effectiveness.md
```

生成された Markdown を PR コメントに貼ると、変更された宣言についてだけ、テストに何が欠けているかと直し方が表示されます。

### 既知の制限

- プロジェクトを作業ディレクトリにコピーして解析するため、相対パスのローカル依存（`.package(path: "../Foo")`）は解決できない。
- `swift test` は `.build` をロックするため、Swift パッケージではテストの実行（ミュータントごとに 1 回）を並列化できない。カスタムモードでは [`--jobs`](#並列実行) で並列化できる。
- テスト選択では、ほかのテストを先に流さないと通らないテスト（状態の共有、実行順への依存）が選んだテストの中で失敗し、ミュータントが検出されたように見えることがある。そのようなテストスイートでは `--no-test-selection` を使う。

## ドキュメント

- [基本概念](docs/ja/concepts.md)：テストの effectiveness とは何か、PIE モデル、「テストが欠けている」の意味、referenced / executed / verified の 3 列、スコアを出さない理由
- 現在実装している手法
  - [テストからの静的な参照](docs/ja/methods/static-references.md)：referenced 列を埋める
  - [カバレッジ](docs/ja/methods/coverage.md)：executed 列を埋める
  - [極端ミューテーション](docs/ja/methods/extreme-mutation.md)：verified 列を埋める
- [ARCHITECTURE.ja.md](ARCHITECTURE.ja.md)：パイプライン、各手法の実装、手法の追加方法

## 開発

```bash
swift test
swift run swift-test-effectiveness /path/to/package
```

`Tests/Fixtures` のフィクスチャに対する統合テスト（遅い）：

```bash
STE_INTEGRATION=1 swift test --filter IntegrationTests
```

swiftly などで入れたツールチェーンと Xcode の `Testing.framework` のバージョンが合わない場合は、`--swift /usr/bin/swift`（統合テストでは `STE_SWIFT=/usr/bin/swift`）で Xcode のツールチェーンを指定してください。
