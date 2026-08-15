# 意思決定記録（ADR）

この文書は、PixiEdenの要件を実現するために採用した方針と、検討した不採用案を記録する。受入条件は[US/AC](user-stories.ja.md)、システム境界は[UC](use-cases.ja.md)、目的とスコープは[PRD](prd.ja.md)を参照する。

## ADR-001

PixiEden専用のPixi環境を別管理する

**Status**: Accepted

### Context

利用者は既存のPixi、`PIXI_HOME`、Pixi Global環境を持つ可能性がある。NFS modeでは高I/OなPixi dataをmachine-localへ置く必要もある。

### Decision

Pixi binary、`PIXI_HOME`、cache、Global環境をPixiEden専用の管理領域に配置し、既存のPixi環境から分離する。

### Rejected alternatives

- システム全体へ共有インストールする案: 管理者権限と全ユーザーへの影響が必要で、非特権ホストに適さない。
- 既存の`PIXI_HOME`へ統合する案: 利用者の環境を上書きする境界を安全に検証できない。

**Related**: [US-101](user-stories.ja.md#us-101)

## ADR-002

Bash/zsh hookの追加を利用者の明示操作に限定する

**Status**: Accepted

### Context

shell起動時の自動有効化は便利だが、PixiEdenが既存のshell設定を無断で編集すると利用者の設定を壊す可能性がある。

### Decision

`pixied hook bash`または`pixied hook zsh`はruntime hookをsourceするshell codeを出力するだけとし、設定ファイルへの追加は利用者が行う。生成runtime hookは両shellでsourceでき、対話時のdirenv hookだけ対象shellに合わせる。

### Rejected alternatives

- shell設定ファイルを自動編集する案: 既存設定の破壊や意図しない起動処理の追加を避けられない。
- Bash/zsh以外のshellまで同時に自動設定する案: 対象shellごとの検証範囲が広がり、現在の公開契約を超える。

**Related**: [US-102](user-stories.ja.md#us-102)、[US-103](user-stories.ja.md#us-103)

## ADR-003

NFS同期を固定allowlistとaccount authoritativeな一方向同期に限定する

**Status**: Accepted

### Context

NFS modeではaccount homeとmachine-local homeの間で必要なshell設定を同期するが、home全体にはcredentialや利用者固有の設定が含まれる。

### Decision

同期対象を`.bashrc`、`.bash_profile`、`.profile`、`.bash_logout`、`.zshrc`、`.zprofile`、`.zlogin`、`.zlogout`に限定し、account homeを正として存在しないlocal fileのみをaccountからコピーする。local fileが存在する場合は上書きせず、localとaccountで異なる場合は警告のみとする。

### Rejected alternatives

- home全体を`rsync`する案: credentialや所有範囲外の設定まで変更し、削除・上書きの境界を検証できない。
- 常に片側を正としてコピーする案: 反対側の変更を黙って失うため。

**Related**: [US-106](user-stories.ja.md#us-106)

## ADR-004

session managerを任意とし、hookの自動起動を条件付きにする

**Status**: Accepted

### Context

利用者には通常の対話Bashだけで十分な場合と、切断後に再接続できるZellijセッションが必要な場合がある。また、非対話commandをZellijへattachさせてはならない。

### Decision

session managerは`none`または`zellij`から選択できるようにする。`pixied run <command>`は常に直接実行し、`pixied shell`と対話TTYからのhookだけがセッション接続の対象になる。

### Rejected alternatives

- 常にZellijへ接続する案: 非対話commandやZellijを必要としない利用者の実行経路を奪う。
- hookを常にshellへ進める案: CI、非対話shell、既存のZellij内で不要なセッションを起動する。

**Related**: [US-103](user-stories.ja.md#us-103)、[US-104](user-stories.ja.md#us-104)、[US-105](user-stories.ja.md#us-105)

## ADR-005

child commandを待機してから終了処理を行う

**Status**: Accepted

### Context

NFS同期のpush可否はchild commandの終了statusに依存する。childを直接`exec`すると、そのstatusを回収して後処理を実行できない。

### Decision

child commandをforegroundで待機し、終了statusを保持してから同期のfinish処理とstatus返却を行う。

### Rejected alternatives

- childを直接`exec`する案: 終了statusを回収できず、正常終了時だけpushする契約を守れない。

**Related**: [US-104](user-stories.ja.md#us-104)、[US-106](user-stories.ja.md#us-106)

## ADR-006

stateと所有情報を基準にuninstallする

**Status**: Accepted

### Context

複数のmachineが共有resourceを参照する可能性があり、同じpathに利用者が作成した資源が存在する可能性もある。

### Decision

current machineのstate、canonical path、owner、hashを検証し、PixiEdenが所有する資源だけをquarantine経由で整理する。他machineのstateが残る共有resourceは保持する。

### Rejected alternatives

- 既定path配下を無条件に削除する案: 利用者の既存環境や他machineのresourceを破壊する。
- 共有resourceをcurrent machineのuninstallで必ず削除する案: 他machineのruntimeを壊す。

**Related**: [US-107](user-stories.ja.md#us-107)

## ADR-007

プロジェクト環境の連携ファイルをPixiEdenが生成する

**Status**: Accepted

### Context

グローバルPixi環境だけでは、プロジェクトごとの依存関係をdirenv、DevContainer、Dockerで同じように再現できない。手書き設定は環境差分と初期設定の負担を生む。

### Decision

`pixied generate <devcontainer|dockerfile|direnv>`と`pixied generate direnv --print-envrc`を提供する。`direnv`は、runtime hookまたは`pixied shell`/`pixied run`で`pixied`がPATH上にある場合はそのcommandを、それ以外では生成時のCLI絶対pathを使って専用Pixi runtimeからプロジェクトのshell hookを取得する。`--print-envrc`はactivation codeだけをstdoutへ出力し、ファイルは書き込まない。同期やsession起動は行わず、コンテナ向け形式はホストの`.pixi`を除外してプロジェクト全体を取り込んでからinstallし、プロジェクト定義から再現可能なコンテナ定義を生成する。既存の`.envrc`がある場合は末尾に挿入(生成済みブロックは重複なく置換)し、それ以外の形式は明示確認なしに上書きしない。

### Rejected alternatives

- グローバルPixi環境へプロジェクト依存関係を常時追加する案: プロジェクト間の依存関係が混ざり、既存環境を変更する。
- ホストの`pixi`や`PIXI_HOME`を直接使う案: PixiEdenの専用環境とプロジェクト環境の境界を検証できない。

**Related**: [US-108](user-stories.ja.md#us-108)

## ADR-008

Release tagをスクリプトでPIXIED_VERSIONと一致させる

**Status**: Accepted

### Context

手動で`git tag v<version>`を作ると、`bin/pixied`の`PIXIED_VERSION`とタグ名が一致しない状態が作れる。バージョン更新を忘れて同じバージョンで再タグすると、既存タグを移動して過去のrelease archiveと矛盾する。

### Decision

`scripts/tag-release.sh`だけがrelease tagを作成する。タグ名は`bin/pixied`の`PIXIED_VERSION`から導出し、annotated tagとしてHEADに作成する。既存タグがlocalまたはoriginに存在する場合と、tracked fileに未commitの変更がある場合は失敗し、`bin/pixied`のバージョン更新を促す。pushは`--push`指定時のみ行う。

### Rejected alternatives

- 別管理の`VERSION`ファイルを導入する案: バージョン情報が複数箇所に分かれ、更新漏れで同一バージョンの再リリースが起きる。
- ドキュメントへの注意書きだけで防ぐ案: 手動手順に依存し、バージョン更新忘れや既存タグの上書きを検出できない。
