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

- 利用者単位の専用Pixi binary、`PIXI_HOME`、direnv、任意のZellijの提供
- グローバルPixi環境を土台にしたプロジェクトPixi環境の自動有効化
- DevContainerまたはDockerでプロジェクトPixi環境を構築する生成物の提供
- `local`と`nfs`のhome mode
- Bash/zsh起動時のruntime hook
- 専用環境での対話shell、Zellijセッション、commandの実行
- NFS modeでの限定的なshell設定同期
- PixiEdenが所有する資源の安全なuninstall
- `pixied generate`によるプロジェクト向け設定・Dockerfileの生成

### 対象外

- システム全体へのPixi、開発ツールの導入
- Bash以外のshell hook
- 既存のPixi、`PIXI_HOME`、Pixi Global環境、shell設定の自動変更
- home全体、credential、`.config`全体、Pixi cache、machine stateの同期
- 明示確認なしの`/etc/wsl.conf`変更やPixiEdenによる`wsl --shutdown`

## 成功定義と指標

以下は、実行時の利用統計ではなく、要件を満たしたかを確認するための目標指標とする。

- 対応するLinux環境で、利用者の権限だけで専用runtimeをインストールして利用できる。
- Bashまたはzsh hookの評価後、専用の`HOME`、`PIXI_HOME`、`PATH`が有効になり、既存Pixi環境を参照しない。
- `pixied run <command>`をTTYやZellijの有無にかかわらず実行でき、commandの終了statusを返す。
- NFS modeの同期対象が8つのshell設定ファイルに限定され、起動前pullと正常終了後pushが行われる。
- Zellijを選択した場合、`pixied shell`で既存セッションへ再接続するか、初回セッションを作成できる。
- `pixied generate direnv`で、プロジェクトディレクトリに入ったときだけPixiEdenの専用Pixi上のプロジェクト環境を有効化できる。生成された`.envrc`は`pixied generate direnv --print-envrc`を評価し、runtime hookまたは`pixied shell`/`pixied run`のPATHを使い、それ以外では生成時のCLI絶対pathを使う。hookの評価だけではNFS同期やsession起動を行わない。
- `pixied generate devcontainer`または`dockerfile`で、同じプロジェクトPixi環境をコンテナ内に構築できる。既定では`generate devcontainer`/`generate dockerfile`は既存ファイルを上書きせずエラーで終了し、`--force`で上書き（`<name>.bak`へ1世代backup）する。また`generate dockerfile`は`pixi.toml`を必須とし、pyproject.tomlのみは非対応とする。
- `pixied uninstall`を再実行しても、PixiEdenが所有しない資源や利用者の既存環境を削除しない。

## 再現範囲

machine間で共有または再現されるのは、PixiEdenの設定、固定されたPixi version、プロジェクトの`pixi.toml`または`pyproject.toml`、生成した`.envrc`・DevContainer・Dockerfile、およびNFS modeで許可した8つのshell設定ファイルである。Pixiのcache、解決済みバイナリ、machine-localな`PIXI_HOME`、Zellijの実行中session、machineごとのstateは共有せず、各machineで再構築する。

したがってPixiEdenが保証するのは「同じ定義から専用runtimeとプロジェクト環境を再構築できること」であり、別machineへZellijの画面や未同期の作業状態を移動することではない。Zellijの再接続は同じmachine上でsessionが残っている場合に限る。

## 動作モードと権限

|home mode|session manager|専用runtime|プロジェクトPixi|Zellij永続化|必要な条件・権限|
|---|---|---|---|---|---|
|`local`|`none`|通常home上の専用領域で利用|direnv、DevContainer、Dockerfileを利用可能|なし|昇格権限不要。|
|`local`|`zellij`|通常home上の専用領域で利用|direnv、DevContainer、Dockerfileを利用可能|同じmachineのsessionへ再接続|runtime内から専用sessionへ直接attach。昇格権限不要。|
|`nfs`|`none`|machine-local homeと専用`PIXI_HOME`で利用|direnv、DevContainer、Dockerfileを利用可能|なし|local homeの作成・書込み権限が必要。昇格権限不要。|
|`nfs`|`zellij`|machine-local homeと専用`PIXI_HOME`で利用|direnv、DevContainer、Dockerfileを利用可能|同じmachineのsessionへ再接続|local homeの書込み権限が必要。runtime内から専用sessionへ直接attach。昇格権限不要。|

`zellij`ではPixiEden runtime内から`zellij attach --create pixied`を直接実行する。親shellの環境を継承するため、`SSH_AUTH_SOCK`なども利用できる。`none`では専用interactive Bashを起動し、Zellijを起動しない。

## トレーサビリティ

目的とスコープは[ユースケース（UC）](use-cases.ja.md)でシステム境界と主要フローに分解する。各UCの価値と検証条件は[ユーザーストーリーと受入条件（US/AC）](user-stories.ja.md)で管理し、選択理由と不採用案は[意思決定記録（ADR）](adr.ja.md)から参照する。
