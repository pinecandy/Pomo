# Pomo

<p align="center">
  <img src="Assets/PomoIcon.png" alt="Pomo app icon" width="144">
</p>

作業に終わりをつくるmacOS用フォーカスタイマー。

<p align="center">
  <img src="docs/images/pomo-running.png" alt="Pomoの集中画面" width="720">
</p>

目標時刻を決め、そこへ向かって集中する。時間を超えたら超過を確認し、自分で終了を決める。

時間切れで作業を強制終了するアプリではない。時間感覚と見積もりの精度を取り戻し、完了するタスクを増やすためのアプリ。

## できること

- タスク名と集中時間をその場で入力
- Enterで即開始
- 一時停止と再開
- 5分追加
- 予定時間を超えた後も自動継続
- 実際にかかった時間を記録
- 終了後に休憩を自動開始

## 使い方

1. Pomoへカーソルを置く
2. タスク名と集中時間を入力する
3. Enterまたは再生ボタンで開始する
4. 必要に応じて一時停止や5分追加を使う
5. 作業を終えるタイミングで停止ボタンを押す

休憩後は次の作業を自動開始せず、新しいタスクを決める状態へ戻る。

休憩時間、ウィンドウサイズ、ゲージ色、最前面表示は右クリックメニューから変更できる。

## UI

| 開始前 | 予定時間を超えた後 |
| --- | --- |
| <img src="docs/images/pomo-setup.png" alt="タスク名と集中時間の入力画面" width="480"> | <img src="docs/images/pomo-overtime.png" alt="超過時間の表示画面" width="480"> |

## データ

ネットワーク通信とアクセス解析は行わない。

- 設定: macOSの`UserDefaults`
- セッション履歴: `~/Library/Application Support/Pomo/sessions.jsonl`

セッション履歴にはタスク名、開始時刻、終了時刻、実績秒数、終了理由が入る。個人的なタスク名を含む可能性があるため、公開リポジトリへ追加しないこと。

現時点ではセッション開始時の見積もり時間を保存していない。見積もりと実績の比較は今後の構想。

## 起動

要件はmacOS 13以降とXcode Command Line Tools。現在は署名済みアプリを配布していないため、ソースから起動する。

```bash
git clone https://github.com/pinecandy/Pomo.git
cd Pomo
swift run Pomo
```

検証:

```bash
./scripts/check.sh
```

## ライセンス

[MIT License](LICENSE)

Copyright (c) 2026 pinecandy
