# swift-test-effectiveness

[English](README.md) | 日本語

Swift プロジェクトのテストスイートの effectiveness（故障を検出する力）を調べ、フィードバックするツールです。

結果は 1 つのスコアではなく宣言単位で示します。宣言ごとに、テストの何が欠けているか（実行されていない、実行されているが検証されていない、など）と、何をすべきかを報告します。

現在は、どのテストも実行しないメソッドをカバレッジで、実行されているが検証されていないメソッドを極端ミューテーションで見つけます。極端ミューテーションでは、各メソッドの本体を戻り値型にとって最も単純な振る舞い（空の本体、`nil`、`true`/`false` …）に置き換え、それでもテストが全て通るものを **pseudo-tested** と報告します。

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

## 使い方

### Swift Package

```bash
swift run swift-test-effectiveness /path/to/package
```

プロジェクトを `<package>/.build/test-effectiveness` にコピーしてそこで解析するので、元のソースは変更しません。最初に、変更していないコードでテストスイートが通る必要があります（ベースライン）。通らなければ解析を中止します。パイプラインは [ARCHITECTURE.ja.md](ARCHITECTURE.ja.md#パイプライン) を参照してください。

### 主なオプション

| オプション | 説明 |
|---|---|
| `--since <rev>` | `<rev>` 以降に変更された行と重なる宣言だけを解析する（PR 用） |
| `--target <name>` | 指定ターゲットのみ（複数可） |
| `--test-filter <pattern>` | `swift test --filter` に渡す |
| `--exclude <substring>` | パスに文字列を含むファイルを除外（複数可） |
| `--swift <path>` | 使用する `swift` 実行ファイル |
| `--dry-run` | ビルドも実行もせず、解析対象の一覧だけを表示する |
| `--format text\|markdown\|json` | レポート形式（markdown は PR コメント向け） |
| `-o, --output <file>` | レポートをファイルに書き出す |
| `--fail-on-pseudo-tested` | pseudo-tested メソッドがあれば終了コード 1 |

特定の手法向けのオプション：

| オプション | 手法 | 説明 |
|---|---|---|
| `--no-coverage` | カバレッジ | カバレッジを取得せず、後段の手法を全宣言に対して実行する |
| `--throw-mutants` | 極端ミューテーション | 型指定なしの `throws` メソッドに `throw` するミュータントを追加 |
| `--timeout-factor`, `--minimum-timeout` | 極端ミューテーション | ミュータントごとのテスト実行のタイムアウト（ベースライン時間 × 係数、下限秒数） |

終了コード：`0` 成功、`1` `--fail-on-pseudo-tested` に該当、`2` ビルド失敗やベースライン失敗など。

### Xcode プロジェクトなど（カスタムモード）

`--source-dir`、`--build-command`、`--test-command` を指定すると、任意のビルドシステムで動きます。コマンドはコピーしたプロジェクト内で `/bin/sh -c` で実行されます。

```bash
swift run swift-test-effectiveness /path/to/App \
  --source-dir App \
  --build-command "xcodebuild build-for-testing -scheme App -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.2'" \
  --test-command  "xcodebuild test-without-building -scheme App -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.2'"
```

テストコマンドはミュータントごとに実行され、アクティブなミュータントは `STE_MUTANT` と `TEST_RUNNER_STE_MUTANT` の両方で渡されます（`xcodebuild test` は `TEST_RUNNER_` 付きの環境変数をテストプロセスに転送します）。

カスタムモードではカバレッジを取得しないため、テストから実行されないメソッドは `not-covered` ではなく `pseudo-tested` として報告されます。

### CI での例

```bash
swift run swift-test-effectiveness . --since origin/main --format markdown -o effectiveness.md
```

生成された Markdown を PR コメントに貼ると、変更された宣言についてだけ、テストに何が欠けているかと直し方が表示されます。

### 既知の制限

- プロジェクトを作業ディレクトリにコピーして解析するため、相対パスのローカル依存（`.package(path: "../Foo")`）は解決できない。
- `swift test` は `.build` をロックするため、テストの実行（ミュータントごとに 1 回）を並列化できない。

## ドキュメント

- [基本概念](docs/ja/concepts.md)：テストの effectiveness とは何か、PIE モデル、「テストが欠けている」の意味、referenced / executed / verified の 3 列、スコアを出さない理由
- 現在実装している手法
  - [カバレッジ](docs/ja/methods/coverage.md)：executed 列を埋める
  - [極端ミューテーション](docs/ja/methods/extreme-mutation.md)：verified 列を埋める
- [ARCHITECTURE.ja.md](ARCHITECTURE.ja.md)：パイプライン、各手法の実装、手法の追加方法

referenced 列（宣言を直接呼ぶテストがあるか）はまだ実装していません。

## 開発

```bash
swift test
```

`Tests/Fixtures` のフィクスチャに対する統合テスト（遅い）：

```bash
STE_INTEGRATION=1 swift test --filter IntegrationTests
```

swiftly などで入れたツールチェーンと Xcode の `Testing.framework` のバージョンが合わない場合は、`--swift /usr/bin/swift`（統合テストでは `STE_SWIFT=/usr/bin/swift`）で Xcode のツールチェーンを指定してください。
