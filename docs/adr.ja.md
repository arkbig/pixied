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

child commandを待機して終了statusを返す

**Status**: Accepted

### Context

終了statusは呼び出し元へ返す必要がある。childを直接`exec`すると、そのstatusを回収したあとに後処理を実行できない。

### Decision

child commandをforegroundで待機し、終了statusを保持してからstatus返却を行う。NFS同期はruntime開始時の`account→local`の一方向`reconcile`だけであり、終了statusに応じた追加の同期は行わない。

### Rejected alternatives

- childを直接`exec`する案: 終了statusを回収したあとに後処理を実行できず、status返却の契約を守れない。

**Related**: [US-104](user-stories.ja.md#us-104)、[US-106](user-stories.ja.md#us-106)、[ADR-011](#adr-011)

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

`pixied generate <devcontainer|dockerfile|direnv>`と`pixied generate direnv --print-envrc`を提供する。`direnv`は、生成時のCLI絶対pathまたは`pixied`がPATH上にある場合はそのcommandを使って専用Pixi runtimeからプロジェクトのshell hookを取得する。`--print-envrc`はactivation codeだけをstdoutへ出力し、ファイルは書き込まない。同期やsession起動は行わず、プロジェクト定義から再現可能なコンテナ定義を生成する。既存ファイルは明示確認なしに上書きしない。

### Rejected alternatives

- グローバルPixi環境へプロジェクト依存関係を常時追加する案: プロジェクト間の依存関係が混ざり、既存環境を変更する。
- ホストの`pixi`や`PIXI_HOME`を直接使う案: PixiEdenの専用環境とプロジェクト環境の境界を検証できない。

**Related**: [US-108](user-stories.ja.md#us-108)、[ADR-011](#adr-011)

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

## ADR-009

アクティブruntimeのidentityは検証済みstate fileをsource of truthとする

**Status**: Accepted

### Context

専用環境を有効化したruntime shellから`pixied install`/`pixied uninstall`を実行するとき、NFS modeでは`$HOME`がmachine-local homeへremapされる。このため`$HOME`や環境変数`PIXIED_STATE_FILE`、`PIXIED_MACHINE_STATE_DIR`からidentityを再計算すると、実際のdeploymentと一致しない別machine/別homeの設定を当てがう事故が起きる。

### Decision

アクティブruntime（runtime hookが`PIXIED_RUNTIME_HOOK_ACTIVE=1`と絶対正規化pathの`PIXIED_RUNTIME_STATE_FILE`を両方設定した状態）の管理操作では、runtimeがsourceした検証済みstate fileをidentityのsource of truthとする。`$HOME`、`PIXIED_STATE_FILE`、`PIXIED_MACHINE_STATE_DIR`からはidentityを再計算しない。state fileが不在または検証不能な場合は管理操作を拒否し、identity変更optionやreinstallでのsession manager変更、`zellij`のアクティブruntimeからのuninstallを却下する。install/uninstallはstateを更新するだけで現在のsession環境は変えず、`exit`後再起動または再attachしたruntimeにのみ反映する。

### Rejected alternatives

- `$HOME`と環境変数からidentityを再計算する案: NFS modeで`$HOME`がremapされるため、誤ったidentityを当てがう。
- アクティブruntimeの検出を単一の環境変数のみで判定する案: 片方だけの設定（hook漏れや変数の残存）で誤検出し、検証されていないstateをsource of truthとして扱う。
- アクティブruntimeでもidentity変更optionを許可する案: 実行中sessionが保持する環境とstateが一致しなくなり、再attach時に不整合が残る。

## ADR-010

NFSのstate registryとruntime payloadを分離する

**Status**: Accepted

### Context

account homeはmachine間で共有される一方、Pixiのdata、config、cache、短時間lock、lease、Zellij sessionはmachineごとに独立して扱う必要がある。同じlocal home文字列がhostごとに異なるlocal filesystemを指す場合、path文字列の一致だけでは共有resourceと判定できない。

### Decision

NFSでは`state_dir`とaccount側の`command_bin/pixied`だけを共有領域に置く。state fileは`machines/<machine-id>/state`へ分離し、data/config/専用`PIXI_HOME`と短時間lockとleaseは`PIXIED_LOCAL_HOME`側へ配置する。共有launcherはcurrent machineのstateを読み、そのstateのlocal payloadへdispatchする。peer stateから`local_home`は継承しない。

### Rejected alternatives

- account homeのdata/configを共有し続ける案: machine間のruntime payloadとlockが同じ実体になり、独立性を保証できない。
- stateとpayloadを同じ共有directoryに置く案: lock競合とlocal filesystemの性能問題をruntimeから分離できない。
- peerの`local_home`を既定値として継承する案: 別hostのlocal filesystemを誤って参照する。

**Related**: [ADR-011](#adr-011)

## ADR-011

leaseでruntime生存を分離し`--force`を警告降格に限定する

**Status**: Accepted

### Context

短時間`lock`はinstall/uninstallのstate書込みとruntime開始時の`reconcile`だけが保持し、実行中runtimeは`lock`を保持しない。実行中runtimeの有無を`lock`残存で判定すると、staleな`lock`と実行中runtimeを区別できない。

### Decision

実行中runtimeの生存は`leases/`配下のlease fileで表し、短時間`lock`から分離する。`shell`/`run`は開始時にleaseを取得し、終了時に解放する。`install`/`uninstall`は`lease`を`sweep`し、staleなleaseは警告付きで自動除去する。他runtimeの生存中leaseがある場合、`install`は警告して継続し、`uninstall`は拒否する。`uninstall --force`は生存中leaseと常駐sessionの拒否を警告へ降格するだけで、`--yes`とは独立に最終確認を求める。

### Rejected alternatives

- 長時間`lock`でruntimeを排他する案: 複数runtimeの共存を妨げ、staleな`lock`の手動除去が必要になる。
- `uninstall --force`で確認も省略する案: 実行中runtimeが使うfileを削除する危険な操作から利用者を守れない。

**Related**: [US-107](user-stories.ja.md#us-107)、[ADR-005](#adr-005)、[ADR-007](#adr-007)、[ADR-010](#adr-010)
