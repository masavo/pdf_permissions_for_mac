# pdf_permissions_for_mac

macOS Folder Actionsで、フォルダに新しく追加されたPDFへパスワードと権限制限を設定します。元PDFを同名で置換するため、最初はコピーしたPDFで試してください。

既定では印刷・コピー・注釈を許可し、ページ構成変更・フォーム入力・その他の編集を禁止します。閲覧パスワードを空にすると、開くときのパスワード入力は不要です。

## クイックスタート（envchain）

macOS、Homebrew、qpdf 11.7以降が必要です。envchainを使う場合はenvchainも必要です。

```sh
git clone https://github.com/masavo/pdf_permissions_for_mac.git
cd pdf_permissions_for_mac
mkdir -p "$HOME/Documents/PDF待ち"
./setup.sh --folder "$HOME/Documents/PDF待ち" --install-deps
```

セットアップは不足しているqpdf/envchainをHomebrewでインストールし、オーナーパスワードと任意の閲覧パスワードを非表示で入力させ、設定確認とFolder Actionの登録まで行います。System Eventsの操作許可やKeychainのアクセス許可が表示されたら、内容を確認して許可してください。

`./setup.sh` だけを端末で実行すると、監視フォルダのパスを尋ねます。対象フォルダは先に作成してください。ファイル名を限定する場合は `--prefix "対象_"` を追加します。prefix未指定では、そのフォルダに追加されるすべてのPDFが対象です。既存PDFを一括処理することはありません。

既定の秘密情報保存先はmacOS Keychain（名前空間 `pdf-permissions`）です。envchainモードは `.env` を作成・読み込みません。秘密情報を含まない設定はGit除外された `.settings` に保存します。複数のプロジェクトで別のパスワードを使う場合は `--namespace 別の名前` を指定してください。

[envchain公式資料](https://github.com/sorah/envchain)に沿って、パスワード登録には `--set --noecho`、処理時には名前空間を指定したコマンド実行を利用します。

## オプション

```sh
./setup.sh --help
# 登録済みのKeychain情報を再利用
./setup.sh --folder "$HOME/Documents/PDF待ち" --skip-secrets
# 設定・インストールのみ。監視を有効にしない
./setup.sh --folder "$HOME/Documents/PDF待ち" --no-register
```

`--install-deps` を指定しなければ依存ツールは自動インストールしません。不足時は導入コマンドを表示して終了します。Homebrew自体は自動インストールしません。

`--skip-secrets` は既存の秘密情報を再利用します。指定しないenvchainセットアップは入力した値でその名前空間のパスワードを更新します。登録の確認に失敗した場合は、監視を有効にしません。セットアップの再実行はFolder Actionを重複登録しません。

## .envを使用する場合

```sh
./setup.sh --backend dotenv --folder "$HOME/Documents/PDF待ち"
```

新規セットアップではパスワードを非表示で入力し、権限600の `.env` を作成します。既存の `.env` は上書きせず、設定を検証します。Gitでは `.env` とそのバックアップ名を除外しますが、`git add -f` で強制追加しないでください。

`.env.example` は手動設定用のひな形です。オーナーパスワードは空のまま利用できません。既存 `.env` の非秘密設定より、セットアップが作成した `.settings` が優先されます。

## 設定と手動実行

```sh
./secure_pdf.sh --check-config
./secure_pdf.sh /absolute/path/to/sample.pdf
```

`.settings` の設定例は `settings.example` にあります。

| 設定 | 内容 |
| --- | --- |
| `SECRET_BACKEND` | `envchain` / `dotenv` / `environment`。`auto` は既存利用向け |
| `ENVCHAIN_NAMESPACE` | envchainの名前空間。英数字・ハイフン・ドット・下線 |
| `TARGET_PREFIX` | ファイル名の前方一致。空なら全PDF |
| `PERMISSION_POLICY` | `print_copy_annotate` / `strict` / `custom` |
| `QPDF_PERMISSION_ARGS` | custom用の権限フラグ。印刷・抽出・注釈・フォーム等の許可設定のみ |
| `QPDF_BIN` / `ENVCHAIN_BIN` | 必要ならツールの絶対パス。Homebrewの標準配置は自動検出 |
| `LOG_FILE` | 既定はプロジェクト内の `secure_pdf.log` |
| `STABILITY_CHECKS` | サイズが同じことを確認する回数。既定3 |
| `STABILITY_INTERVAL_SECONDS` | 確認間隔。既定1秒 |
| `STABILITY_TIMEOUT_SECONDS` | 安定待機のタイムアウト。既定120秒 |

外部から環境変数を渡す場合は `SECRET_BACKEND=environment` を指定します。このモードも `.env` を読みません。`auto` は環境にオーナーパスワードがあればそれを使い、なければ既存 `.env` を読みます。setupで選択したenvchainモードが `.env` にフォールバックすることはありません。

## 運用上の注意

- PDF権限はPDFリーダーが尊重する設定です。すべてのアプリによる編集・コピーを防ぐ仕組みではありません。
- オーナーパスワードには十分に長い固有の値を使ってください。閲覧パスワードと同じ値や設定例のプレースホルダーは拒否します。
- パスワードをコマンド引数や一時ファイルへ渡さず、qpdfの標準入力へ渡します。改行を含むパスワード・PDFパスは使用できません。
- qpdfのエラー・警告では原本を置換せず、非ゼロ終了を返します。診断は `LOG_FILE` に記録します。ログにはPDFのパスが含まれるため公開しないでください。
- シンボリックリンクの入力は拒否します。一時出力は権限600で作成し、同じPDFの並行処理と処理中の入力差し替えを検知します。成功後のPDFも権限600です。
- サイズの安定はコピー完了を保証しません。長いコピー中断・同サイズ書き換え・異常終了後のロック残存では再実行が必要になる場合があります。
- `.settings` と `.env` は信頼するローカルのシェル設定として読み込みます。第三者から受け取った設定ファイルを実行しないでください。監視先・プロジェクト・ログのディレクトリは本人が管理するものを使ってください。
- Keychainがロックされている場合やアクセスが拒否された場合、処理は失敗することがあります。無人運用前にTerminalで設定確認とFolder Actionの発火を試してください。
- 入力に閲覧パスワードが設定されたPDFの再処理は、入力用パスワードの指定を実装していないため失敗する場合があります。

## Folder Actionの管理

インストール済みスクリプトは `~/Library/Scripts/Folder Action Scripts/PDF自動権限付与.scpt` です。プロジェクトを移動した場合はsetupを再実行してください。

`install_folder_action.sh --attach /absolute/path/to/folder` は対象フォルダへの登録に加え、Folder Actions全体を有効にします。ほかの登録もある場合は状態を確認してください。停止・解除はFinderの「フォルダアクション設定」で行えます。解除してもKeychainのパスワードや `.env` は削除しません。

Folder Action自体の呼び出しエラーは `~/Library/Logs/PDF自動権限付与-folder-action.log` に記録します。

## テストと公開前チェック

個人のPDFや隣接プロジェクトを必要としないテストです。Python 3とqpdfが必要です。setupとAppleScriptのテストはmacOSで実行してください。通常のテストは実際のKeychainや監視登録を変更しません。

```sh
python3 -m unittest discover -s tests -v
python3 scripts/check_public_files.py
```

公開前チェックはGitの公開候補から秘密設定、PDF、ログ、コンパイル済みスクリプト、ローカル検証記録、代表的なトークン・秘密鍵・個人の絶対パスを検出します。パターン検査なので、あらゆる秘密情報を検出する保証はありません。公開候補の差分も確認してください。
