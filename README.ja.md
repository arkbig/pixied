
# PixiEden

| 🌐Language: | [English](./README.md) ｜ **日本語** |
| ---------- | ------------------------------------ |

PixiEdenは[Pixi](https://github.com/prefix-dev/pixi/)ベースの開発環境構築ツールです。コマンド名は`pixied`。

PixiEdenは、WSL2などのローカル環境から、ホームディレクトリがNFS共有されている非特権(root権限なし)サーバーまで、同じ定義からPixi開発runtimeを再構築できます。
Pixiとdirenvを組み合わせ、I/O負荷の高いネットワークホームを避けてデータをマシンローカルストレージへ逃がします。

対象は次の2つです。

- ローカル環境(WSL2を含む)
- ホームディレクトリがNFS等の共有ストレージ上にある非特権ホスト

## こんな用途に向いています

- ノートPC、WSL、リモートLinuxで同じ設定から環境を再構築したい
- `$HOME`がNFSで、開発ツールの動作が遅い・壊れやすい

## 主要機能

- グローバルの開発runtimeを構築
  + 専用runtimeで対話Bashを開始
- プロジェクトごとのPixi環境を構築
  + グローバルPixi環境の上にプロジェクトPixi環境を重ねて利用可能
  + DevContainerまたはDocker用の定義を生成可能

## クリックスタート

最新Releaseからインストールする。

```bash
curl -fsSL https://raw.githubusercontent.com/arkbig/pixied/main/install.sh | bash
```

クローン済みリポジトリからインストールする。

```bash
./install-local.sh
```

PixiEdenはシェル設定を自動編集しません。インストーラーに表示される手順に従い、`~/.bashrc`の一番先頭へhookを追加する。zshでは`~/.zshrc`へ`hook zsh`で追加する。

```bash
if [ -x "${XDG_BIN_HOME:-$HOME/.local/bin}/pixied" ]; then
    eval "$(${XDG_BIN_HOME:-$HOME/.local/bin}/pixied hook bash)"
fi
```

新しいターミナルやSSHセッションを開くと専用runtimeが有効になる。`pixied shell`を実行すると、そのruntimeで対話Bashを開始する。

NFS共有ホームで使う場合は、マシンローカルなディレクトリを使う。未作成の選択パスなら表示し利用者が確認した後、PixiEdenが作成します。`--yes`、または`curl | bash`のようにstdin/stdoutがTTYでないインストールでは確認も作成も行わないため、事前に作成しておく必要があります。

`/scratch`は例であり、利用者が作成・所有できるマシンローカルなパスへ置き換える。公開Releaseからインストールする場合は次を実行する。

```bash
curl -fsSL https://raw.githubusercontent.com/arkbig/pixied/main/install.sh |
  bash -s -- --home-mode nfs --local-home "/scratch/$USER" --yes
```

公開Releaseから対話ウィザードを使う場合は、pipeで実行せず、インストーラーをダウンロードしてTTYから実行する。

```bash
curl -fsSL https://raw.githubusercontent.com/arkbig/pixied/main/install.sh \
  -o /tmp/pixied-install.sh
bash /tmp/pixied-install.sh --home-mode nfs
```

## NFS Releaseを更新する

NFS共有ホームでは、最初に一台で公開Releaseをインストールする。そのhostがarchiveを検証し、immutableなshared Releaseをpublishして`current`を選択し、自分のmachine-local payloadも更新する。

```bash
curl -fsSL https://raw.githubusercontent.com/arkbig/pixied/main/install.sh |
  bash -s -- --home-mode nfs --local-home "/scratch/$USER" --yes
```

別hostでは、そのhost専用のlocal homeを作成して`pixied install`を実行する。選択済みshared Releaseを使うため、同じarchiveをnetworkから再取得しない。

```bash
mkdir -p /scratch/$USER
pixied install --home-mode nfs --local-home "/scratch/$USER" --yes
```

そのhostで最初のinstallが済んだ後は、shared`current`が変わるたびに`pixied install`を実行する。`pixied version`はshared Releaseとこのhostのlocal payloadを表示する。不一致は情報表示だけであり、`pixied shell`と`pixied run`は検証済みのlocal payloadを使い続け、自動更新しない。hostを更新するには`pixied install`を実行する。

`pixied prune --keep 1`で確認後に古い検証済みReleaseを整理できる。non-interactiveに実行する場合は`--yes`を付ける。選択中の`current`、保持数分の履歴、liveなmanagement commandが使っているReleaseは常に保護される。`prune`はNFS modeだけで使え、host-local payloadやPixi homeは削除しない。

NFS hostを一台uninstallすると、そのhostのlocal payloadとmachine stateだけを削除し、validな別machineが残る間はshared dispatcherとRelease storeを保持する。最後のvalid machineをuninstallしたときだけshared distributionを整理する。

## コマンド

```text
pixied                       shellへのエイリアス
pixied shell                 対話Bashを開始
pixied run <command...>      専用環境でcommandを実行
pixied hook <bash|zsh>       シェル初期化コードを出力
pixied install               環境をインストールまたは修復
pixied uninstall             PixiEden管理対象を整理
pixied generate <format>     プロジェクト連携ファイルを生成
pixied prune [options]       古いshared NFS Releaseを整理
pixied help                  ヘルプを表示
pixied version               バージョン表示
```

詳細なoptionは`pixied --help`、`pixied <command> --help`で確認する。`install-local.sh --help`も`pixied install`と同じoptionを受け付ける。

プロジェクトrootで次を実行すると、プロジェクトPixi環境を使うためのファイルを生成できる。

```bash
pixied generate direnv
pixied generate devcontainer
pixied generate dockerfile
```

`direnv`はプロジェクトディレクトリに入ったときだけプロジェクトPixi環境を有効化する。DevContainerとDockerfileは、プロジェクトの`pixi.toml`を基にコンテナ内へ開発環境を構築する(ボリュームマウント前提)。

## NFS共有ホームでの注意

interactiveな`nfs`installでは、選択したlocal homeが未作成なら、明示確認後にPixiEdenがdeployment前に作成し、その後に存在、owner、書込み権限、account homeとの分離、local filesystem条件をvalidationする。`--yes`または`curl | bash`のようなnon-TTY installではpromptも作成も行わず、install前の作成が必要である。reinstallでは作成確認より前に保存済みidentityを検証する。

NFS modeではhome直下の8ファイル(`.bashrc`、`.bash_profile`、`.profile`、`.bash_logout`、`.zshrc`、`.zprofile`、`.zlogin`、`.zlogout`)だけをaccount homeとlocal homeの間で同期する。account homeを正として扱い、`pixied shell`または`pixied run`の起動時に`account→local`の一方向でlocal homeへコピーする。終了時にaccount homeへ書き戻さない。

## アンインストール

次を実行する。

```bash
pixied uninstall
```

## 動作要件

- `bash`、`curl`または`wget`、`tar`を利用できるUbuntuまたは互換`Linux`。

## ドキュメント案内

[開発者向けドキュメント](docs/README.ja.md)

## 類似ソフトウェア

- [Duetbox](https://github.com/arkbig/duetbox): Devbox(Nix)ベースの開発環境構築ツール。Pixiよりパッケージ数が多いです。
