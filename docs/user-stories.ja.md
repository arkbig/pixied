# ユーザーストーリーと受入条件（US/AC）

この文書は、[UC](use-cases.ja.md)の各ゴールを利用者価値の単位へ分解し、実装を確認できる受入条件（AC）を定義する。設計上の採用理由や不採用案は各ストーリーから[ADR](adr.ja.md)へリンクする。

## US-101

### PixiEden環境をインストールする

### User Story

非特権の開発者として、ローカルLinux、WSL2、NFSホストのどこでも専用のPixiEden環境を使いたい。

**関連UC**: [UC-01](use-cases.ja.md#uc-01)

**関連ADR**: [ADR-001](adr.ja.md#adr-001)

### Acceptance Criteria

1. **Given**対応するLinux環境と利用者の権限がある
   **When**`pixied install`を実行する
   **Then**専用Pixi binary、direnv、選択したsession manager、runtime hook、launcher、stateが準備される。
2. **Given**利用者が既存のPixi環境を持っている
   **When**PixiEdenをインストールする
   **Then**既存のPixi binary、`PIXI_HOME`、Pixi Global環境は参照または上書きされない。
3. **Given**PixiEdenがインストール済みである
   **When**同じ設定でinstallを再実行する
   **Then**検証済みstateを使って環境を維持または修復できる。

## US-102

### Bash/zsh起動時のhookを設定する

### User Story

開発者として、`pixied hook bash`または`pixied hook zsh`の出力を自分のshell設定へ追加し、次回以降のshell起動で専用環境を使いたい。

**関連UC**: [UC-02](use-cases.ja.md#uc-02)

**関連ADR**: [ADR-002](adr.ja.md#adr-002)

### Acceptance Criteria

1. **Given**PixiEdenのruntime hookが生成済みである
   **When**`pixied hook bash`または`pixied hook zsh`を実行する
   **Then**runtime hookをsourceするshell codeだけがstdoutへ出力される。
2. **Given**利用者がhookの出力をshell設定へ追加している
   **When**新しいBash、zsh、またはSSHセッションを開始する
   **Then**runtime hookが評価される。
3. **Given**利用者が既存のshell設定を管理している
   **When**hookを生成または評価する
   **Then**PixiEdenはshell設定ファイルを自動編集しない。

## US-103

### 起動時に専用環境を有効化する

### User Story

開発者として、Bashを起動した時点で専用のhomeとtoolを使い、条件を満たす場合は開発セッションへ自動接続したい。

**関連UC**: [UC-03](use-cases.ja.md#uc-03)

**関連ADR**: [ADR-002](adr.ja.md#adr-002)、[ADR-004](adr.ja.md#adr-004)

### Acceptance Criteria

1. **Given**有効なstateとruntime artifactがある
   **When**shell設定からhookを評価する
   **Then**専用の`HOME`、`PIXI_HOME`、`PATH`がshellへ設定される。
2. **Given**shellが対話TTY上にあり、CI環境ではなく、既にZellij内でもない
   **When**session managerが`zellij`でhookを評価する
   **Then**UC-05が自動起動される。
3. **Given**stateまたはruntime artifactを検証できない
   **When**hookを評価する
   **Then**親shellの環境を変更せず、installが必要であることを示して終了する。

## US-104

### 専用環境でcommandを実行する

### User Story

開発者またはCIとして、`pixied run <command>`を実行し、専用環境でのcommand結果をそのまま受け取りたい。

**関連UC**: [UC-04](use-cases.ja.md#uc-04)

**関連ADR**: [ADR-004](adr.ja.md#adr-004)、[ADR-005](adr.ja.md#adr-005)

### Acceptance Criteria

1. **Given**PixiEdenがインストール済みである
   **When**`pixied run <command>`を実行する
   **Then**Zellijへattachせず、専用runtimeでcommandを一度だけ実行する。
2. **Given**呼び出し元にTTYがない
   **When**`pixied run <command>`を実行する
   **Then**commandを実行できる。
3. **Given**commandが成功、失敗、またはsignal終了する
   **When**commandが終了する
   **Then**対応する終了statusが呼び出し元へ返される。

## US-105

### 開発セッションを開始または再開する

### User Story

開発者として、`pixied shell`で専用の対話環境を開始し、同じmachine上でZellijを選択した場合は残っている作業セッションへ再接続したい。

**関連UC**: [UC-05](use-cases.ja.md#uc-05)

**関連ADR**: [ADR-004](adr.ja.md#adr-004)

### Acceptance Criteria

1. **Given**利用者が対話TTY上にいて、session managerが`none`である
   **When**`pixied shell`を実行する
   **Then**専用runtimeの対話Bashが起動する。
2. **Given**session managerが`zellij`で既存セッションがある
   **When**`pixied shell`を実行する
   **Then**既存のmachine-id付きセッションへ接続する。
3. **Given**session managerが`zellij`で既存セッションがない
   **When**`pixied shell`を実行する
   **Then**初回セッションを作成して接続する。

## US-106

### NFSホームで開発する

### User Story

NFSホームを使う開発者として、必要なshell設定だけをmachine-local homeと同期し、他のファイルを変更せずに開発したい。

**関連UC**: [UC-06](use-cases.ja.md#uc-06)

**関連ADR**: [ADR-003](adr.ja.md#adr-003)

### Acceptance Criteria

1. **Given**利用者が`nfs` modeと有効なmachine-local homeを選択している
   **When**installを実行する
   **Then**runtimeのlocal homeとPixi dataがmachine-local領域に配置される。
2. **Given**NFS modeでUC-04またはUC-05を開始する
   **When**runtimeを開始する
   **Then**`.bashrc`、`.bash_profile`、`.profile`、`.bash_logout`、`.zshrc`、`.zprofile`、`.zlogin`、`.zlogout`だけがpullされる。
3. **Given**child commandまたはsessionがstatus `0`で終了する
   **When**runtimeを終了する
   **Then**allowlistの変更だけがaccount homeへpushされる。
4. **Given**account側とlocal側の双方に異なる変更がある
   **When**同期を実行する
   **Then**片側を黙って上書きせず、利用者が確認できる状態を保つ。

## US-107

### PixiEden環境をアンインストールする

### User Story

環境を廃止する利用者として、PixiEdenが管理した資源だけを削除し、既存のPixi環境や他のmachineの共有資源へ影響を与えたくない。

**関連UC**: [UC-07](use-cases.ja.md#uc-07)

**関連ADR**: [ADR-006](adr.ja.md#adr-006)

### Acceptance Criteria

1. **Given**current machineのPixiEden stateがある
   **When**`pixied uninstall`を実行する
   **Then**state、path、owner、hashを検証してから管理対象を整理する。
2. **Given**共有resourceを他のmachine stateが参照している
   **When**current machineをuninstallする
   **Then**共有resourceを保持する。
3. **Given**利用者が作成した既存のPixi環境、共有resource、local home本体がある
   **When**uninstallを実行する
   **Then**それらを削除しない。
4. **Given**uninstallが中断または一部完了している
   **When**uninstallを再実行する
   **Then**管理対象外へ範囲を広げず、残ったstateと所有情報に基づいて処理を続行できる。

## US-108

### プロジェクトPixi環境を生成する

### User Story

開発者として、PixiEdenの専用runtimeを土台に、プロジェクトへ移動したときだけプロジェクトのPixi環境を有効化したい。また、同じ環境をDevContainerやDockerでも利用したい。

**関連UC**: [UC-08](use-cases.ja.md#uc-08)

**関連ADR**: [ADR-007](adr.ja.md#adr-007)

### Acceptance Criteria

1. **Given**PixiEdenの専用グローバル環境とPixiプロジェクトがある
   **When**`pixied generate direnv`をプロジェクトrootで実行する
   **Then**既存ファイルを無断で上書きせず、専用Pixi runtimeからshell hookを取得してプロジェクトPixi環境を有効化する`.envrc`を生成できる。`pixied`がPATHにある場合は`pixied generate direnv --print-envrc`を使い、ない場合は生成時のCLI絶対pathを使う。hookの評価でNFS同期やsession起動は行わない。
2. **Given**生成済み`.envrc`がある
   **When**利用者がプロジェクトディレクトリへ移動する
   **Then**プロジェクトのPixi環境が有効になり、プロジェクト外では有効にならない。
3. **Given**Pixiプロジェクトがある
   **When**`pixied generate devcontainer`または`pixied generate dockerfile`を実行する
   **Then**プロジェクト定義から再現可能なコンテナ定義を生成できる。`generate devcontainer`は`pixi.toml`または`pyproject.toml`のいずれでも動作し、`generate dockerfile`は`pixi.toml`を必須とする（pyproject.tomlのみは非対応）。
4. **Given**対象の生成ファイルが既に存在する
   **When**`pixied generate`を実行する
   **Then**`generate devcontainer`/`generate dockerfile`は既定で上書きせずエラーで終了し、`--force`で上書き（直前のファイルを`<name>.bak`へ1世代backup）する。`generate direnv`は既存`.envrc`へ重複なくブロックを挿入し、`--force`を無視する。
5. **Given**生成されたコンテナ定義を利用する
   **When**DevContainerまたはDockerでプロジェクトを起動する
   **Then**グローバルPixiの前提とプロジェクトPixiの依存関係が分離され、ホストのPixi環境を変更しない。
