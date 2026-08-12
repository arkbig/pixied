# PixiEden

| 🌐Language: | [English](./README.md) ｜ **日本語** |
| ---------- | ------------------------------------ |

PixiEdenは[Pixi](https://github.com/prefix-dev/pixi/)ベースの開発環境構築ツールです。コマンド名は`pixied`。

PixiEdenは、WSL2などのローカル環境から、ホームディレクトリがNFS共有されている非特権（root権限なし）サーバーまで、同じ定義から再構築できるPixi開発runtimeを提供します。
Pixi, direnv, Zellijを組み合わせ、I/O負荷の高いネットワークホームを避けてデータをマシンローカルストレージへ逃がす構成を採用します。これにより、管理者権限がないリモート環境でも日常的なシェル操作の遅延を解消し、快適な開発体験を実現します。

対象となる環境は次の2つです。

- ローカル環境（WSL2を含む）
- ホームディレクトリがNFS等の共有ストレージ上にある非特権ホスト

## こんな用途に向いています

- ノートPC、WSL、リモートLinuxで同じ設定から環境を再構築したい
- 導入するツールをリストで管理したい
- `$HOME`がNFSで、開発ツールの動作が遅い・壊れやすい
- 同じmachineで再接続や再起動後も残ったZellij sessionへ戻りたい

## 主要機能

- グローバルの開発runtimeを構築
  - SSHで接続する非特権ユーザー＆NFS共有ホームディレクトリでも環境を構築可能
  - 自動的にruntimeに入り、同じmachineに残ったZellij sessionを復元
- プロジェクトごとのPixi環境を構築
  - グローバルPixi環境の上にプロジェクトPixi環境を重ねて利用可能
  - DevContainerまたはDocker用の定義を生成可能

## クリックスタート

最新Releaseからインストール:

```bash
curl -fsSL https://raw.githubusercontent.com/arkbig/pixied/main/install.sh | bash
```

このremote installerはGitHub Releasesの`pixied.tar.gz`を一時展開し、archive内の`install-local.sh`を実行します。Releaseの取得先を変更する場合は`PIXIED_RELEASE_URL`を指定できます。

クローン済みリポジトリからインストール:

```bash
./install-local.sh
```

インストール時にPixiEdenはシェル設定を自動編集しません。インストーラーが表示したCLIのフルパスを使い、Bashの場合は次の3行を`~/.bashrc`の一番先頭へ、zshの場合は`hook zsh`に置き換えて`~/.zshrc`の一番先頭へ追加してください（非対話時にも処理する場所）。XDGの既定値では`${XDG_BIN_HOME:-$HOME/.local/bin}/pixied`です。

```bash
if command -v "${XDG_BIN_HOME:-$HOME/.local/bin}/pixied" >/dev/null 2>&1; then
    eval "$(${XDG_BIN_HOME:-$HOME/.local/bin}/pixied hook bash)"
fi
```

zshでは、同じブロックを`~/.zshrc`へ追加し、`hook bash`を`hook zsh`に置き換えます。

新しいターミナルまたはSSHセッションを開くと、必要に応じてローカルホームへ切り替え、Pixi Globalを有効化します。Zellijを有効にした場合は、systemd user managerが利用できればmachine-id付きunitが管理する永続Zellijセッションへ接続し、利用できなければdirect attachへfallbackします。

## インストール設定

設定は、CLI引数、サポート対象の環境変数、現在のmachineの保存済みstate、自動検出、固定された既定値の順に解決します。

- Home モード: `df -l`でローカルファイルシステムと確認できれば`local`、それ以外は`nfs`。
- ローカルホーム: `nfs`モードで実行時に使う、事前に作成済みのmachine-localパス。
- セッションマネージャのインストール: 既定値は`zellij`。`none`を選ぶとZellij、systemd user service、linger設定をスキップします。systemd user managerを利用できない環境ではdirect attachへfallbackします。
- sudoの使用: WSLのsystemd設定やlinger設定でsudoが必要になる場合があります。PixiEdenは変更内容を表示してから明示確認を行い、拒否された場合はsudoを実行しません。これらは設定選択ではなく、実際の変更前の確認です。

PixiEdenは、非ローカルな専用Pixi homeを使い続ける場合、sudoを伴うWSL・linger変更を行う場合、管理対象をuninstallする場合に確認を求めることがあります。`--yes`はこれらの確認だけを省略し、path、owner、hash、machine-idの検証は省略しません。

セッションマネージャを無効にした場合、環境導入後は通常のシェルを起動します。自動接続とターミナル作業の永続化が必要になったら、次で再インストールしてください。

```bash
pixied install --session-manager zellij
```

設定を事前に指定し、確認を省略する場合は次のように実行します。

```bash
./install-local.sh \
  --home-mode nfs \
  --local-home /scratch/$USER \
  --session-manager none \
  --use-sudo no \
  --yes
```

環境変数で指定する場合は`PIXIED_HOME_MODE`、`PIXIED_LOCAL_HOME`、`PIXIED_SESSION_MANAGER`、`PIXIED_USE_SUDO`を使います。`PIXIED_SESSION_MANAGER`には`zellij`または`none`を指定します。`--yes`を付けると確認を省略できます。

Pixiのバージョンを指定する場合は`PIXIED_PIXI_VERSION`を使います。未指定時はPixiEdenが固定したバージョンを使い、組み込みdigestで検証します。versionを指定した場合や`latest`を指定した場合は、ユーザーが選択したReleaseを使い、同じReleaseから取得した公式checksumでダウンロード内容の破損・取り違えを検知します。チェックサムを明示的に固定したい場合は`PIXIED_PIXI_SHA256`で上書きできます。

複数machineでstateの識別子を明示する高度な設定には`PIXIED_MACHINE_ID`を使います。machineごとに一意で、pathの一部として安全な値を指定してください。省略すると`/etc/machine-id`、またはPixiEdenのfallback検出値を使います。

## コマンド

```text
pixied                       shellサブコマンドへのエイリアス
pixied shell                 NFS同期（必要時）を行い、セッションへ接続
pixied run <command...>      NFS同期（必要時）を行い、専用環境でcommandを実行
pixied hook <bash|zsh>       シェル初期化コードを出力
pixied install [...]         環境をインストールまたは修復
pixied uninstall             検証済みのPixiEden管理対象を整理
pixied generate direnv       プロジェクトPixi環境用の.envrcを生成
pixied generate devcontainer DevContainer用の定義を生成
pixied generate dockerfile   Dockerfileを生成
pixied help                  ヘルプ表示
pixied version               バージョン表示
```

プロジェクトrootで次を実行すると、グローバルPixiEden環境を土台にプロジェクトPixi環境を使うためのファイルを生成できます。生成先に既存ファイルがある場合は、明示確認なしに上書きしません。

```bash
pixied generate direnv
pixied generate devcontainer
pixied generate dockerfile
```

`direnv`の生成物はプロジェクトディレクトリに入ったときだけプロジェクトPixi環境を有効化します。DevContainerとDockerfileの生成物は、プロジェクトの`pixi.toml`または`pyproject.toml`を基にコンテナ内へプロジェクトPixi環境を構築します。

## 再現される範囲

machine間で再現されるのは、PixiEdenの設定、固定Pixi version、プロジェクト定義、生成したプロジェクト連携ファイルです。NFS modeでは4つのshell設定ファイルもallowlistに従って同期されます。Pixi cache、解決済みバイナリ、machine-localな`PIXI_HOME`、実行中のZellij session、machineごとのstateはmachine間で共有されません。Zellijの再接続は、同じmachine上にsessionが残っている場合だけ行われます。

## 動作モードと権限

|home mode|session manager|保証される機能|必要な条件・権限|
|---|---|---|---|
|`local`|`none`|通常home上の専用runtime、direnv、プロジェクトPixi、DevContainer/Docker生成|systemd不要、sudo不要|
|`local`|`zellij`|上記に加え、同じmachine上のZellij sessionへ再接続|systemd user managerと`loginctl`があれば永続unit・lingerを利用。lingerやWSL設定変更にsudoが必要な場合は明示確認。利用できなければdirect attach|
|`nfs`|`none`|machine-local home上の専用runtime、4ファイル同期、direnv、プロジェクトPixi、DevContainer/Docker生成|事前に作成したlocal homeのowner・書込み権限・local filesystem条件。systemd不要、sudo不要|
|`nfs`|`zellij`|上記に加え、同じmachine上のZellij sessionへ再接続|local homeの書込み権限。systemd user managerと`loginctl`があれば永続unit・lingerを利用。利用できなければdirect attach。WSL設定やlinger変更にsudoが必要な場合は明示確認|

`none`ではZellij、systemd、`loginctl`、lingerを検出・変更・起動しません。`zellij`でもsystemdが利用できない場合はdirect attachへfallbackします。別machineへZellijの画面や未同期の作業状態を移動する機能は提供しません。

`nfs`modeで使う`PIXIED_LOCAL_HOME`は、install前に環境側で作成してください。指定pathは既存directoryであり、current userがownerで書込み可能、account homeと分離され、canonical pathとして検証できるlocal filesystem上にある必要があります。既定候補の`/local/$USER`もPixiEdenは自動作成しません。`install`はlocal homeを検証するだけで、local home作成用のサブコマンドも提供しません。

local homeを事前に作成してもNFS同期は無効になりません。`nfs`modeではhome直下の`.bashrc`、`.bash_profile`、`.profile`、`.bash_logout`だけをaccount homeとlocal homeの間で同期します。

NFSモードの同期対象はhome直下の`.bashrc`、`.bash_profile`、`.profile`、`.bash_logout`だけです。`pixied shell`または`pixied run`の起動前にallowlistをpullし、child commandまたはsessionがstatus 0で終了した場合だけpushします。account側とlocal側の双方が異なる変更を持つ場合は上書きせず、`PIXIED_STATE_DIR`配下に衝突artifactを保存して停止します。

### 同期エラーからの復旧

衝突が発生すると、`$PIXIED_STATE_DIR/conflicts/<artifact>/`に次の情報を永続保存します。

- `account/`: account home側のコピー
- `local/`: local home側のコピー
- `meta/metadata`: 対象item、両側のhashまたは`missing`、baselineの値

内容を確認して採用する側を決め、allowlist対象のaccount側とlocal側を同じ内容にそろえてから`pixied shell`または`pixied run`を再実行してください。両側が一致すると、同期処理がbaselineを再生成します。artifactは自動削除されないため、復旧確認後に必要な期間保管してから手動で整理します。

baselineが壊れている場合は、`pixied`の実行中プロセスがないことを確認し、該当する`sync-baseline`を同じdirectory内へ退避してください。そのうえでallowlist対象の両側を同じ内容にそろえて`pixied shell`または`pixied run`を実行すると、baselineが未初期化の状態から再生成されます。両側が異なるまま実行すると、通常どおりconflictとして停止します。

lockが残っている場合も、自動削除は行いません。該当する`pixied`プロセスが停止していることを確認した後、空のlock directoryだけを次のように削除してください。

```bash
rmdir -- "$PIXIED_STATE_DIR/.lock"
```

実行中のprocessがある状態でlockを削除したり、lockに対して`rm -rf`を実行したりしないでください。

## 動作要件

- `bash`、`curl`または`wget`、`tar`を利用できるUbuntuまたは互換`Linux`。
- WSL2でセッションマネージャを有効にした場合はsystemdが有効であること。無効な場合、PixiEdenは`/etc/wsl.conf`への変更案を表示し、明示確認とsudo許可があれば`[boot] systemd=true`をmergeします。同じrunではsessionを起動せず、手動で`wsl --shutdown`を実行してから`pixied install`を再実行してください。
- セッションマネージャを有効にした場合、systemd user managerと`loginctl`が利用できればmachine-id付きuser unitとlingerを準備します。利用できない場合は診断を表示してdirect attachへfallbackします。セッションマネージャを無効にする場合はこれらを検出・変更・起動しません。

## アンインストール

次を実行します。

```bash
pixied uninstall
```

セッションマネージャを有効にしていた場合、PixiEdenが作成したsystemdユーザーサービスと、PixiEdenが有効化したlinger設定を表示し、無効化前に確認します。`--yes`で確認を自動承認できます。

uninstallは、current stateに記録された専用`PIXI_HOME`を管理境界にします。PixiEdenが新規作成した未共有の専用`PIXI_HOME`は、path、owner、stateを検証した後にdirectory単位で整理できます。既存pathまたは他machineと共有するpathでは、stateに記録されhashが一致する実行ファイルだけを整理し、共有Pixiのmetadata、manifest、`envs/`などは残る場合があります。PixiEdenはpackage単位の所有判定を行わず、現在のinstallが追加したGlobal packageだけを削除することも保証しません。

対象のZellij sessionが残っている場合、systemd経由でもdirect attachでも削除を中止します。sessionを終了またはdetachしてから`pixied uninstall`を再実行してください。session一覧を取得できない場合も安全側に中止します。

最後に、`~/.bashrc`からPixiEdenのhookブロックを手動で削除してください。途中で中断した場合も、ランチャーまたは配備済みCLIが残っていれば`pixied uninstall`を再実行できます。

## パスと XDG 対応

ここに示す`PIXIED_*`名は解決済みpathを説明するための名前であり、installの入力overrideとしてはサポートしません。文書化されたpathの場所を変更する場合は対応するXDG環境変数を使ってください。

- `PIXIED_DATA_DIR`（データ、CLI、Pixi binary）: `${XDG_DATA_HOME:-$HOME/.local/share}/pixied`
- `PIXIED_CONFIG_DIR`（設定、生成runtime hook）: `${XDG_CONFIG_HOME:-$HOME/.config}/pixied`
- `PIXIED_STATE_DIR`（状態、machineごとの設定、同期baseline、衝突情報）: `${XDG_STATE_HOME:-$HOME/.local/state}/pixied`
- CLI ランチャー: `${XDG_BIN_HOME:-$HOME/.local/bin}/pixied`
- マシンローカルツールとPixi Globalデータ: `$PIXIED_LOCAL_HOME`

## ドキュメント案内

[開発者向けドキュメント](docs/README.ja.md)
