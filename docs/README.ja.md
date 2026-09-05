# PixiEden開発ドキュメント

開発者向けの入口である。要件と設計の文書は、責任範囲を分けた次の4階層で管理する。

```text
PRD（目的・背景）
  -> UC（システム境界・全体フロー）
    -> US/AC（価値の縦切り・検証条件）
      <-> ADR（採用理由・不採用案）
```

| 層 | 文書 | 責任範囲 |
| --- | --- | --- |
| PRD | [prd.ja.md](prd.ja.md) | 目的、背景、対象利用者、スコープ、成功定義 |
| UC | [use-cases.ja.md](use-cases.ja.md) | アクター、システム境界、主要ゴール、通常フロー |
| US/AC | [user-stories.ja.md](user-stories.ja.md) | ユーザー価値、UCとの紐付け、受入条件 |
| ADR | [adr.ja.md](adr.ja.md) | 意思決定の理由、代替案、不採用理由、トレードオフ |

## 読み方

1. プロダクトの目的と対象範囲は[PRD](prd.ja.md)から確認する。
2. システムが誰に何を提供するかは[UC](use-cases.ja.md)で確認する。
3. 各UCをどの価値として実装・検証するかは[US/AC](user-stories.ja.md)で確認する。
4. なぜその方式を選び、何を不採用にしたかは[ADR](adr.ja.md)で確認する。

## IDルール

- `UC-xx`: ユースケースの識別子
- `US-xxx`: ユーザーストーリーと受入条件の識別子
- `ADR-xxx`: 意思決定記録の識別子

USは必ず関連UCのIDを持ち、設計判断が関係する場合は関連ADRのIDを持つ。受入条件の実装上の正はテストコードとし、この文書は要求から検証への追跡に使う。

## 実装の正

state形式、runtime hook、unit、関数単位の入出力、詳細な失敗分岐は、対応する`bin/`、`lib/`の実装と`tests/`を正とする。PRD、UC、US/AC、ADRには、実装詳細を重複して記載しない。

## 開発の進め方

`bin/pixied`と`lib/*.sh`を変更した場合は、次で構文と静的解析を確認する。

```bash
bash -n bin/pixied lib/*.sh install-local.sh install.sh
shellcheck -x bin/pixied lib/*.sh install-local.sh install.sh
```

Bats統合テストは次で実行する。`generate`はDockerが必要なため分離している。

```bash
tests/run.sh
tests/run.sh generate
tests/run.sh all
```

契約テストとして`CLI contract is stable`で`help`、`install --help`、`uninstall --help`、`generate --help`の要点を固定している。HELP文言を変更した場合はこのテストも更新する。

## HELPと警告文の分担

利用者向けの操作説明は文書ではなくHELPと警告文を正とする。

- 全体像は`pixied help`、各コマンドのoptionは`pixied <command> --help`で確認する。
- `install`と`install-local.sh`と`install.sh`は同じinstall optionを受け付ける。
- `uninstall --help`で`--yes`と`--force`の分担を確認する。`--force`は実行中runtimeと常駐sessionの拒否を警告へ降格するだけで、最終確認は`--yes`とは独立である。
- `generate --help`で形式ごとの`--force`と`--print-envrc`の扱いを確認する。
- 実行時の判断材料(設定確認、非local警告、同期警告、lease警告、所有検証エラー)は標準エラー出力の警告文とエラー文で案内する。

トップレベルの`README.ja.md`は初見の使用者向けに最小限とし、解決順序や所有境界などの詳細はここに記載する。

## 初期版のNFS境界

`nfs`modeの`PIXIED_LOCAL_HOME`は、PixiEdenのinstall前に環境側で作成済みでなければならない。installはdirectoryの存在、owner、書込み権限、account homeとの分離、local filesystem条件を検証するが、directoryや親directoryを作成しない。既定候補の`/local/$USER`も同様に事前準備が必要である。

local homeの作成状態はNFS同期の有無とは別である。`nfs`modeでは、account homeとlocal homeの間でhome直下の`.bashrc`、`.bash_profile`、`.profile`、`.bash_logout`、`.zshrc`、`.zprofile`、`.zlogin`、`.zlogout`だけをallowlistに従って同期する。初期版にはlocal home作成用のサブコマンドを設けない。将来chezmoiを導入する場合のdotfiles所有権、NFS同期の廃止・代替・併用は、初期版とは別の設計判断と移行計画で扱う。

## 環境変数の分類

利用者向けの設定としてサポートする環境変数は次のとおりである。

|分類|環境変数|用途|
|---|---|---|
|install設定|`PIXIED_HOME_MODE`、`PIXIED_LOCAL_HOME`、`PIXIED_SESSION_MANAGER`|CLI optionと同じinstall設定を環境変数から指定する。|
|runtime設定|`PIXIED_AUTO_ATTACH`|`shell`/`hook`の`--auto-attach`と同じ自動attach設定を環境変数から指定する。`auto`または`none`だけを受け付ける。|
|advanced設定|`PIXIED_MACHINE_ID`|machine stateの識別子を明示する。安全なpath segmentでなければ停止する。|
|Pixi version設定|`PIXIED_PIXI_VERSION`、`PIXIED_PIXI_SHA256`|Pixi versionの選択とasset checksumの明示を行う。|
|release設定|`PIXIED_RELEASE_URL`|remote installerが取得するrelease archiveのURLを変更する。|

READMEに示す`PIXIED_DATA_DIR`、`PIXIED_CONFIG_DIR`、`PIXIED_STATE_DIR`、`PIXIED_COMMAND_BIN`は、解決済みpathを説明するための名前であり、利用者が設定する入力overrideではない。`PIXIED_PIXI_HOME`も実装上のpath overrideだが、初期版の利用者向け設定として公開しない。特に`PIXIED_PIXI_HOME`を既存Pixi環境へ向けると所有境界を変えるため、専用pathの解決を使う。

`PIXI_CACHE_DIR`と`PIXI_NO_PATH_UPDATE=1`はPixiEdenが専用runtimeを実行するために内部設定する変数であり、利用者が設定するものではない。`PIXIED_INSTALL_ASSUME_YES`、`PIXIED_PIXI_BINARY_SOURCE`、`PIXIED_PIXI_ASSET_PATH`、`PIXIED_PIXI_LATEST_TAG`、fake command用の変数はtest/development injectionであり、利用者向けの互換性を保証しない。`PIXIED_PIXI_BINARY_SOURCE`で明示digestを省略した場合のhash照合は、source binaryの真正性ではなく一時ファイルへのcopy完全性だけを確認する。

## 実装責務とデータ境界

実装の責務は次のpathに分かれている。関数単位の入出力とstate parserの詳細は対応する実装とtestsを正とする。

|path|責務|
|---|---|
|`bin/pixied`|CLI dispatch、libraryの読み込み、install/start/uninstallの実行順序。|
|`lib/paths.sh`|account home、local home、XDG path、machine-id、専用`PIXI_HOME`の解決と検証。|
|`lib/options.sh`|CLI、公開環境変数、state、自動検出、既定値の優先順位と確認。|
|`lib/state.sh`|許可keyだけを扱うstate parser、path・値・hashの検証、短時間lock、atomic write。|
|`lib/lease.sh`|実行中runtimeのlease取得・解放、staleなleaseの自動除去、他runtime生存の判定。|
|`lib/pixi.sh`|専用Pixi binaryの取得・checksum検証、専用`PIXI_HOME`でのPixi実行、Global executableの検証。|
|`lib/hook.sh`|Bash/zshからsourceできるruntime hookと、hookをsourceするshell codeの生成。|
|`lib/sync.sh`|NFS modeの8ファイルallowlist、`account→local`の一方向`reconcile`。|
|`lib/session.sh`|child command、Zellij session、runtime内のdirect attach。|
|`lib/uninstall.sh`|state・path・owner・hashの検証、共有resourceの保持、quarantineを使うuninstallと復旧。|
|`lib/generate.sh`|project rootとPixi定義の検証、direnv・DevContainer・Dockerfileの生成。|

installはaccount home、home mode、local home、XDG pathを副作用の前に解決する。`nfs`modeではPixi data、config、cache、lockをlocal home側へ置き、`local`modeでは専用data directory配下へ置く。state registryとaccount側launcherだけは共有し、launcherはcurrent machineのstateからlocal payloadへdispatchする。すべてのPixi呼び出しは専用binaryを絶対pathで実行し、runtime内で専用`PIXI_HOME`、`PIXI_CACHE_DIR`、`PIXI_NO_PATH_UPDATE=1`を設定する。

machine stateは共有registry内の`PIXIED_STATE_DIR/machines/<machine-id>/state`に保存し、短時間lockは`nfs`ではmachine state directory内、`local`ではstate root内に保存する。実行中runtimeの生存は`leases/`配下のlease fileで表す。stateをshell codeとしてsourceせず、既知のkey、値の型、canonical path、owner、hashを検証してから更新・実行・削除する。`PIXIED_LOCAL_HOME`とその親directoryはPixiEdenの削除対象外であり、他machineのstateが参照する共有resourceも保持する。

runtime hookはstateとartifactを検証して環境変数とPATHを設定し、対話shellで専用direnv hookを評価するだけである。`pixied shell`または`pixied run`がchild commandまたはsessionを待機し、runtime開始時に`account→local`の一方向`reconcile`だけを行う。

## テストとrelease検証

`tests/run.sh`のBats統合テストはfake Pixi、Zellij、downloadを使い、hostの既存環境を変更せずに通常経路と失敗経路を検証する。

実環境の検証は`tests/e2e/run-multipass.sh`へ集約する。使い捨てUbuntu VMへrelease archiveをinstallし、実Pixi、実direnv、実Zellij、PTY、同一machine上のsession再接続を検証する。

## Release archiveの作成と公開

配布物の入力は`install-local.sh`、`bin/`、`lib/`、README、`docs/`であり、`scripts/package-release.sh`が`pixied.tar.gz`へまとめる。remote入口の`install.sh`はRelease archiveを取得し、archive内の`install-local.sh`へ処理を委譲する。

```bash
tests/run.sh
scripts/package-release.sh
tar -tzf dist/pixied.tar.gz
scripts/tag-release.sh
git push origin v0.1.0
```

タグ名は`bin/pixied`の`PIXIED_VERSION`から`v<version>`として導出する。`v*`タグへのpushで[release workflow](../.github/workflows/release.yml)がarchiveを作成し、GitHub Releaseへ`pixied.tar.gz`を公開する。
