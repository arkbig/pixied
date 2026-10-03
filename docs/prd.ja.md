# PixiEdenプロダクト要求仕様（PRD）

## 目的

PixiEdenは、共有または低速なhomeを使う非特権ユーザーでも、Pixiベースの開発runtimeを安全に利用できるようにする。

利用者の既存Pixi環境を変更せず、PixiEden専用のruntimeを用意することで、ローカルLinux、WSL2、NFSホストで同じ設定からruntimeを再構築できるようにする。

## 背景と課題

- NFSなどの共有home上でPixiのデータを扱うと、高いI/O負荷によって開発環境が遅くなったり不安定になったりする。
- SSHやWSL2など接続方法が変わっても、同じプロジェクト定義と専用runtime設定を利用したい。
- ターミナルの切断や再起動後も、同じmachine上の前回の作業セッションへ戻りたい。
- 非特権ホストでは、システム全体へのインストールや管理者権限を前提にできない。

## 対象利用者と環境

- ローカルLinuxまたはWSL2を使う開発者
- homeがNFSなどの共有ストレージ上にある非特権の開発者
- Pixi環境を専用領域で管理し、既存のPixi環境を保護したい利用者
- Bashを対話shellとして利用する利用者

## スコープ

### 対象

- 利用者単位の専用Pixi binary、`PIXI_HOME`、direnvの提供
- グローバルPixi環境を土台にしたプロジェクトPixi環境の自動有効化
- DevContainerまたはDockerでプロジェクトPixi環境を構築する生成物の提供
- `local`と`nfs`のhome mode
- Bash/zsh起動時のruntime hook
- 専用環境での対話shellとcommandの実行
- NFS modeでの限定的なshell設定同期
- PixiEdenが所有する資源の安全なuninstall
- `pixied generate`によるプロジェクト向け設定・Dockerfileの生成

### 対象外

- システム全体へのPixi、開発ツールの導入
- Bash以外のshell hook
- 既存のPixi、`PIXI_HOME`、Pixi Global環境、shell設定の自動変更
- home全体、credential、`.config`全体、Pixi cache、machine-local payload、短時間lock、実行中session、leaseの同期
- 明示確認なしの`/etc/wsl.conf`変更やPixiEdenによる`wsl --shutdown`

## 成功定義と指標

以下は、実行時の利用統計ではなく、要件を満たしたかを確認するための目標指標とする。

- 対応するLinux環境で、利用者の権限だけで専用runtimeをインストールして利用できる。
- Bashまたはzsh hookの評価後、専用の`HOME`、`PIXI_HOME`、`PATH`が有効になり、既存Pixi環境を参照しない。
- `pixied run <command>`をTTYの有無にかかわらず実行でき、commandの終了statusを返す。
- NFS modeの同期対象が8つのshell設定ファイルに限定され、起動時に`account→local`の一方向`reconcile`だけが行われる。
- `pixied generate direnv`で、プロジェクトディレクトリに入ったときだけPixiEdenの専用Pixi上のプロジェクト環境を有効化できる。生成された`.envrc`は`pixied generate direnv --print-envrc`を評価し、runtime hookまたは`pixied shell`/`pixied run`のPATHを使い、それ以外では生成時のCLI絶対pathを使う。hookの評価だけではNFS同期やsession起動を行わない。
- `pixied generate devcontainer`または`dockerfile`で、同じプロジェクトPixi環境をコンテナ内に構築できる。DevContainerは`Dockerfile`、`devcontainer.json`、`compose.yaml`、`compose.override.yaml`、`.gitignore`、`postCreateCommand.sh`を生成し、Pixi binaryを`ghcr.io/prefix-dev/pixi`から`mcr.microsoft.com/devcontainers/base:noble`へコピーして`PIXI_HOME=/opt/pixi`とdetached environmentを設定する。`devcontainer.json`は`Dockerfile`直接参照ではなく`compose.yaml`形式とし、`compose.override.yaml`も受け付ける。workspaceはhost bind mount、`.pixi`は`${localEnv:USER}-${localWorkspaceFolderBasename}-pixi`のnamed volumeで分離し、`Dockerfile`でも`VOLUME /workspace/.pixi`を宣言する。`compose.override.yaml`は生成時点ではよくあるマウント追加や環境変数・ポート等の設定例をコメントアウトした状態で提供し、各ユーザーローカルでの調整に使う。生成される`.gitignore`は`.env`と`compose.override.yaml`をバージョン管理外とする。projectのinstallとshell hookはworkspace mount後の`postCreateCommand.sh`で行い、shell hookのmanifestは`pixi.toml`を優先し、なければ`pyproject.toml`を使う。プロジェクト固有の追加処理は任意の`postCreateCommand.local.sh`に書ける。DevContainer生成では`.env`やentrypointを使わず、既定では生成済みファイルを上書きせずエラーで終了し、`--force`で上書き（`<name>.bak`へ1世代backup）する。Dockerfile生成ではdefinitionとして`pixi.toml`を優先し、なければ`pyproject.toml`を使い、lockfileはoptionalとする。生成成果物の雛形は`lib/templates/`に個別ファイルとして置き、必要に応じて変数展開したものを生成する。
- `pixied uninstall`を再実行しても、PixiEdenが所有しない資源や利用者の既存環境を削除しない。

## 再現範囲

machine間で共有または再現されるのは、PixiEdenの設定、固定されたPixi version、プロジェクトの`pixi.toml`または`pyproject.toml`、`pixi.lock`、生成した`.envrc`・DevContainer・Dockerfile、NFSのstate registryとaccount側dispatcher、およびNFS modeで許可した8つのshell設定ファイルである。state file、runtime payload、短時間lock、lease、Pixiのcache、解決済みバイナリ、machine-localな`PIXI_HOME`は共有せず、各machineで再構築する。

したがってPixiEdenが保証するのは「同じ定義から専用runtimeとプロジェクト環境を再構築できること」であり、runtime外の未同期の作業状態をmachine間で移動することではない。

## 動作モードと権限

|home mode|専用runtime|プロジェクトPixi|必要な条件・権限|
|---|---|---|---|
|`local`|通常home上の専用領域で利用|direnv、DevContainer、Dockerfileを利用可能|昇格権限不要。|
|`nfs`|machine-local homeと専用`PIXI_HOME`で利用|direnv、DevContainer、Dockerfileを利用可能|local homeの作成・書込み権限が必要。昇格権限不要。|

## アクティブruntime内の管理操作（受入条件）

専用環境を有効化したshell（アクティブruntime）から`pixied install`/`pixied uninstall`を実行する場合にのみ適用する受入条件である。

- AC-1: アクティブruntimeでは**検証済みstate file**をidentityのsource of truthとし、identityを`$HOME`、`PIXIED_STATE_FILE`、`PIXIED_MACHINE_STATE_DIR`から再計算しない。
- AC-2: アクティブruntimeの検出は`PIXIED_RUNTIME_HOOK_ACTIVE=1`と絶対正規化pathである`PIXIED_RUNTIME_STATE_FILE`の両方を要し、いずれか一方だけではアクティブとみなさない。
- AC-3: state fileが不在または検証不能な場合、install/uninstallは`active runtime state is missing or unverifiable; PixiEden refuses to change identity from an active runtime; re-source the runtime from a valid deployment`を出力して失敗する。
- AC-4: アクティブruntime内でidentityを変更するoption（`--home-mode`、`--local-home`、`--machine-id`、`--pixi-home`）を指定すると、`active runtime rejects identity-changing option: --<option> '<指定値>' (verified state uses '<検証済み値>')`を出力して却下する。
- AC-5: install/uninstallは現在のruntime shellが保持する環境を変えずにstateを更新し、`exit`でruntime shellを抜けたあと新しいshellを開始したruntimeにのみ新しい設定を反映する。

## トレーサビリティ

目的とスコープは[ユースケース（UC）](use-cases.ja.md)でシステム境界と主要フローに分解する。各UCの価値と検証条件は[ユーザーストーリーと受入条件（US/AC）](user-stories.ja.md)で管理し、選択理由と不採用案は[意思決定記録（ADR）](adr.ja.md)から参照する。
