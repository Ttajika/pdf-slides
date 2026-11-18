# PDFスライド

`pdf/` に置いた PDF を、ブラウザでスライドとして表示します。iPad で書いた手書き・ポインター・板書とページ送りを、PC へリアルタイムに配信できます。PC 側では録画もできます。

公開ページ：<https://ttajika.github.io/pdf-slides/>

## 使い方

1. PDF を `pdf/` に追加して push します。サブフォルダは 1 段まで使えます（例：`pdf/micro/01.pdf`）。
2. 一覧ページを開き、配信コードを決めます（既定は `1`）。
3. iPad で「配信（iPad）」を開き、🔑 からログインし、配信ボタンを押します。
4. PC で同じコードの「受信（PC）」を開きます。録画するときは「受信＋録画」を開きます。

URL を直接書くときは次のとおりです。

| 用途 | URL |
|---|---|
| ふつうに見る | `viewer.html?file=pdf/xxx.pdf`（`#5` で 5 ページ目から） |
| 配信（iPad） | `viewer.html?file=pdf/xxx.pdf&presenter=1&live=CODE` |
| 受信（PC） | `viewer.html?file=pdf/xxx.pdf&live=CODE` |
| 受信＋録画 | `viewer.html?file=pdf/xxx.pdf&live=CODE&rec=1` |

配信中に QR ボタンを押すと受信用の URL と QR コードが出ます。学生に見せることもできます。

## 操作

| 操作 | キー / 動作 |
|---|---|
| ページ送り | ← → / Space / 指で左右スワイプ |
| 手書き | ✏️ または D。Apple Pencil を当てると自動で手書きモードになる |
| ペン / 蛍光ペン / 消しゴム / ポインター | P / H / E / L |
| 取り消し | ⌘Z / Ctrl+Z |
| 板書（白紙のポップアップ、ページごと） | 「板書」または B。Esc で閉じる |
| 全画面（PC） | ⛶ または F |

Apple Pencil を使っているときは、指では書けず、スワイプでページを送ります。

書き込みはその端末のブラウザ（localStorage）にだけ保存されます。クラウドには保存されません。

## 仕組み

- 表示：PDF.js
- 配信：Supabase Realtime（Broadcast / Presence）。データベースには書き込みません。
- `js/slide-live.js` と `js/slide-sync.js` は `nuce-slides/2027` からコピーしたもので、PDF 用に次の手を加えています。
  - `slide-live.js`：受信用 URL に `?file=` を残す。線の太さを canvas の解像度に合わせる（`lineScale` / `boardLineScale`）。録画ファイル名に PDF 名を使う（`recName`）。
  - `slide-sync.js`：`syncData: false` のとき、ログインだけ使い、データは同期しない。
- 配信できるのは `js/slide-live.js` の `CONFIG.presenterIds` に入っている ID だけです。
