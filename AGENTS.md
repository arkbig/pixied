# 基本ルール（個別指示を優先）

## ドキュメント

- 順番入れ替えがしづらいのでドキュメント・コメントで見出しとしての順番は使わない。番号付き箇条書きは許可。

## shdoc関数ドキュメント

- bashスクリプトは関数にshdoc記法(`@description`, `@arg`, `@set`, `@stdout`, `@stderr`, `@exitcode`, `@see`等)のdocコメントを付ける。
- コメントは米英語で書く(`*.ja.md`のみ日本語)。
- `@internal`は使わない。
- 仮実装(スタブ)の関数は「Provisional implementation」と将来対応予定を明記する。
- `@file`行は付けない。

## bashスクリプトの確認

- `bash -n`で構文チェックする。
- `shellcheck`で静的解析する。
- `shfmt`でコード整形する。
