# PixiEden開発ドキュメント

要件と設計の文書は、責任範囲を分けた次の4階層で管理する。

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

## 初期版のNFS境界

`nfs`modeの`PIXIED_LOCAL_HOME`は、PixiEdenのinstall前に環境側で作成済みでなければならない。installはdirectoryの存在、owner、書込み権限、account homeとの分離、local filesystem条件を検証するが、directoryや親directoryを作成しない。既定候補の`/local/$USER`も同様に事前準備が必要である。

local homeの作成状態はNFS同期の有無とは別である。`nfs`modeでは、account homeとlocal homeの間でhome直下の`.bashrc`、`.bash_profile`、`.profile`、`.bash_logout`、`.zshrc`、`.zprofile`、`.zlogin`、`.zlogout`だけをallowlistに従って同期する。初期版にはlocal home作成用のサブコマンドを設けない。将来chezmoiを導入する場合のdotfiles所有権、NFS同期の廃止・代替・併用は、初期版とは別の設計判断と移行計画で扱う。

## 環境変数の分類

利用者向けの設定としてサポートする環境変数は次のとおりである。

|分類|環境変数|用途|
|---|---|---|
|install設定|`PIXIED_HOME_MODE`、`PIXIED_LOCAL_HOME`、`PIXIED_SESSION_MANAGER`、`PIXIED_USE_SUDO`|CLI optionと同じinstall設定を環境変数から指定する。|
|advanced設定|`PIXIED_MACHINE_ID`|machine stateの識別子を明示する。安全なpath segmentでなければ停止する。|
|Pixi version設定|`PIXIED_PIXI_VERSION`、`PIXIED_PIXI_SHA256`|Pixi versionの選択とasset checksumの明示を行う。|
|release設定|`PIXIED_RELEASE_URL`|remote installerが取得するrelease archiveのURLを変更する。|

READMEに示す`PIXIED_DATA_DIR`、`PIXIED_CONFIG_DIR`、`PIXIED_STATE_DIR`、`PIXIED_COMMAND_BIN`は、解決済みpathを説明するための名前であり、利用者が設定する入力overrideではない。`PIXIED_PIXI_HOME`と`PIXIED_SYSTEMD_USER_DIR`も実装上のpath overrideだが、初期版の利用者向け設定として公開しない。特に`PIXIED_PIXI_HOME`を既存Pixi環境へ向けると所有境界を変えるため、専用pathの解決を使う。

`PIXI_CACHE_DIR`と`PIXI_NO_PATH_UPDATE=1`はPixiEdenが専用runtimeを実行するために内部設定する変数であり、利用者が設定するものではない。`PIXIED_INSTALL_ASSUME_YES`、`PIXIED_SYSTEMD_USER_AVAILABLE`、`PIXIED_WSL`、`PIXIED_WSL_CONF_PATH`、`PIXIED_PIXI_BINARY_SOURCE`、`PIXIED_PIXI_ASSET_PATH`、`PIXIED_PIXI_LATEST_TAG`、fake command用の変数はtest/development injectionであり、利用者向けの互換性を保証しない。`PIXIED_PIXI_BINARY_SOURCE`で明示digestを省略した場合のhash照合は、source binaryの真正性ではなく一時ファイルへのcopy完全性だけを確認する。

## 実装責務とデータ境界

実装の責務は次のpathに分かれている。関数単位の入出力とstate parserの詳細は対応する実装とtestsを正とする。

|path|責務|
|---|---|
|`bin/pixied`|CLI dispatch、libraryの読み込み、install/start/uninstallの実行順序。|
|`lib/paths.sh`|account home、local home、XDG path、machine-id、専用`PIXI_HOME`の解決と検証。|
|`lib/options.sh`|CLI、公開環境変数、state、自動検出、既定値の優先順位と確認。|
|`lib/state.sh`|許可keyだけを扱うstate parser、path・値・hashの検証、lock、atomic write。|
|`lib/pixi.sh`|専用Pixi binaryの取得・checksum検証、専用`PIXI_HOME`でのPixi実行、Global executableの検証。|
|`lib/hook.sh`|Bash/zshからsourceできるruntime hookと、hookをsourceするshell codeの生成。|
|`lib/sync.sh`|NFS modeの8ファイルallowlist、baseline、3-way判定、conflict artifact、clean exit後のpush。|
|`lib/session.sh`、`lib/systemd.sh`|child command、Zellij、systemd user unit、linger、WSL設定変更、direct attach fallback。|
|`lib/uninstall.sh`|state・path・owner・hashの検証、共有resourceの保持、quarantineを使うuninstallと復旧。|
|`lib/generate.sh`|project rootとPixi定義の検証、direnv・DevContainer・Dockerfileの生成。|

installはaccount home、home mode、local home、XDG pathを副作用の前に解決する。`nfs`modeではPixi dataとcacheをlocal home側の専用`PIXI_HOME`へ置き、`local`modeでは専用data directory配下へ置く。すべてのPixi呼び出しは専用binaryを絶対pathで実行し、runtime内で専用`PIXI_HOME`、`PIXI_CACHE_DIR`、`PIXI_NO_PATH_UPDATE=1`を設定する。利用者の通常のPixi、通常の`PIXI_HOME`、通常のPATHはこの境界の外にある。

machine stateは`PIXIED_STATE_DIR/machines/<machine-id>/state`に保存する。stateをshell codeとしてsourceせず、既知のkey、値の型、canonical path、owner、hashを検証してから更新・実行・削除する。既存資源をstateなしまたはhash不一致のまま引き継がず、未管理の既存Pixi pathへのGlobal provisionも行わない。`PIXIED_LOCAL_HOME`とその親directoryはPixiEdenの削除対象外であり、他machineのstateが参照する共有resourceも保持する。

runtime hookはstateとartifactを検証して環境変数とPATHを設定し、対話shellで専用direnv hookを評価するだけである。hookの評価でnetwork、Pixi Global変更、systemd変更、NFS同期全体を実行しない。`pixied shell`または`pixied run`がchild commandまたはsessionを待機し、NFS modeのpullと、status `0`で終わった場合だけpushを行う。signal、失敗、conflict、lock/hash失敗時はpushしない。

## テストとrelease検証

`tests/run.sh`のBats統合テストはfake Pixi、Zellij、systemd、loginctl、sudo、downloadを使い、hostの既存環境を変更せずに通常経路と失敗経路を検証する。4つのhome/session mode、再install、hook、shell/run、uninstall、生成物、checksum、所有境界はこのsuiteのcommand logと一時pathで確認する。

実環境の責務は`tests/e2e/run-multipass.sh`へ集約する。runnerは`package-release.sh`が作成したarchiveを使って使い捨てUbuntu VMへinstallし、実Pixi、実direnv、実Zellij、systemd user unit、linger、PTY、reboot後の復旧を検証する。runnerが作成したVMだけを削除し、既存VMやhostのpathは変更しない。現在のrunnerが対象とするlocal homeとZellij経路に加え、NFSとWSLのsystemd設定変更は別E2E項目として結果と未実施理由を記録する。

release archiveの入力は`install-local.sh`、`bin/`、`lib/`、両言語のREADME、`docs/`だけであり、`scripts/package-release.sh`がarchive root `pixied/`へまとめる。remote入口の`install.sh`はrelease archiveを取得してarchive内の`install-local.sh`へ委譲する。Pixi assetの固定checksum、公式Release checksum、`PIXIED_PIXI_SHA256` overrideのauthorityは`lib/pixi.sh`である。

## Release

配布物の入力は`install-local.sh`、`bin/`、`lib/`、README、`docs/`であり、[scripts/package-release.sh](../scripts/package-release.sh)が`pixied.tar.gz`へまとめる。remote入口の[install.sh](../install.sh)はRelease archiveを取得し、archive内の`install-local.sh`へ処理を委譲する。

Release E2Eはcheckout全体を直接installせず、package scriptが作成したarchiveを使って検証する。Pixi本体のasset checksumは`lib/pixi.sh`の固定digestまたは公式Release checksumを使い、各経路の確認は`tests/`を参照する。

## Release archiveの作成

開発checkoutから配布用archiveを作成する場合は、次を実行する。archiveには配備に必要な`install-local.sh`、`bin/`、`lib/`、README、`docs/`だけが含まれる。

```bash
scripts/package-release.sh
```

出力先を指定する場合は、archive pathを引数に渡す。

```bash
scripts/package-release.sh /tmp/pixied.tar.gz
```

## GitHub ActionsによるRelease公開

オンラインインストールの入口である[install.sh](../install.sh)は、GitHub Releasesの`latest`にある`pixied.tar.gz`を取得する。Release assetは、バージョンタグをpushしたときに[release workflow](../.github/workflows/release.yml)が自動生成・公開する。

Releaseを作成する前に、作業ツリーの変更をcommitし、対象commitをReleaseに含める。次のコマンドで統合テストとarchive作成を確認する。

```bash
tests/run.sh
scripts/package-release.sh
tar -tzf dist/pixied.tar.gz
```

検証が成功したら、`scripts/tag-release.sh`でタグを作成する。タグ名は`bin/pixied`の`PIXIED_VERSION`から自動的に`v<version>`として導出されるため、手動でタグ名を指定しない。

```bash
scripts/tag-release.sh
git push origin v0.1.0
```

タグを同時にpushする場合は、`--push`オプションでタグ作成後に自動pushできる。

```bash
scripts/tag-release.sh --push
```

タグを作成せずに検証だけ行う場合は、`--dry-run`を使う。

```bash
scripts/tag-release.sh --dry-run
```

`scripts/tag-release.sh`は次の場合に失敗し、タグを作成しない。

- tracked fileに未commitの変更がある場合。commitしてから再実行する。
- 導出したタグがlocalまたはoriginに既に存在する場合。`bin/pixied`の`PIXIED_VERSION`を更新してから再実行する。

バージョン更新を忘れて同じバージョンで再タグしようとしても、既存タグが検出されて失敗するため、既存Releaseを上書きしない。

`v*`タグへのpushを受けると、workflowは次の処理を行う。

- `scripts/package-release.sh`で`dist/pixied.tar.gz`を作成する。
- タグと同名のGitHub Releaseがなければ、generated notes付きで作成する。
- `pixied.tar.gz`をRelease assetとしてuploadする。既存assetは更新する。

GitHub Actionsの完了後、GitHub Releaseに`pixied.tar.gz`が存在することを確認する。公開URLは次の形式であり、`install.sh`がこのURLの`latest`を取得する。

```text
https://github.com/arkbig/pixied/releases/latest/download/pixied.tar.gz
```

workflowが失敗する場合は、Actionsの実行ログで`package-release.sh`の失敗、Releaseへの書込み権限、タグ名が`v`で始まっているかを確認する。workflowは`contents: write`権限を要求するため、リポジトリまたはOrganizationのActions設定でworkflowの書込みが禁止されている場合は設定を見直す。
