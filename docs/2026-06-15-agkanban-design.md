# agkanban 設計ドキュメント (v0)

- 日付: 2026-06-15
- ステータス: 設計確定 / 実装プラン待ち
- 著者: ysk411 + Claude Code

## 1. 目的

Claude Code / Codex などのマルチエージェント協調のための、**agmsg と組み合わせて真価を発揮する kanban 型タスク状態管理スキル**を作る。

- agmsg = 伝達層（揮発するメッセージ）
- agkanban = 状態層（永続するボード）

両者は責務を分離しつつ、**識別空間（team/agent）だけを共有**することで「カードを動かす＝関係者にメッセージが自動で流れる」を成立させる。

## 2. 設計判断（確定事項）

| # | 論点 | 決定 | 理由 |
|---|---|---|---|
| 1 | agmsg との結合 | **イベント駆動結合** | カードの列遷移が agmsg メッセージを自動発火。「ボードが動くと会話が流れる」 |
| 2 | ボードのスコープ | **team 単位**（1 team = 1 board） | agmsg のメッセージスコープと一致し、assignee = agmsg 宛先名 が自然に成立 |
| 3 | ストレージ | **独立 DB `board.db`**（agmsg の messages.db は不可侵） | agmsg をフォークせず疎結合を保つ。DB 直編集禁止方針を尊重 |
| 4 | 配置 | **`~/.agents/skills/agkanban/`**（= `~/.claude/skills/agkanban`、symlink で同一実体） | agmsg と兄弟配置。相対パス参照が両名前空間から安定解決 |
| 5 | delivery（気づき） | **agmsg 相乗り + on-demand pull**（独自 monitor/hook は作らない） | push 通知は agmsg の turn/monitor/hook が運ぶ。状態は永続なので pull で取りこぼさない |

## 3. アーキテクチャ

```
                 共有される識別空間 (team / agent)
                 ┌───────────────────────────────┐
   agkanban ─────┤  whoami.sh で借用              ├───── agmsg
  (状態/永続)    └───────────────────────────────┘   (伝達/揮発)
       │                                                  │
   board.db (cards, card_events)                    messages.db
       │                                                  ▲
       └── 列遷移イベント ──→ events.sh ──→ send.sh ───────┘
                                          (AGMSG_SEND_CMD で差替可)
```

### 3.1 識別の借用

agkanban は自前で join しない。各操作の冒頭で agmsg の識別解決を呼ぶ。
ただし agmsg の場所は**堅牢に探索**する（開発時は `~/dev/agkanban` にいて agmsg が兄弟にいないため）:

```
agmsg 探索順（lib/agmsg.sh）:
  1. $AGMSG_HOME（env 明示）
  2. <agkanban>/../agmsg          # 本番: ~/.agents/skills/agmsg と兄弟
  3. ~/.agents/skills/agmsg
  4. ~/.claude/skills/agmsg       # symlink 実体は 3 と同じだが念のため
  → いずれも無ければフォールバックモード（§3.5）
```

発見した agmsg に対して `scripts/whoami.sh "$(pwd)" <type>` を呼んで識別解決する。

- 単一 team が解決される場合: それを操作対象とする
- 複数 team の場合: `--team <name>` を必須にする（曖昧さを排除）
- 未 join / agmsg 不在の場合: §3.5 フォールバックへ

カードの `assignee` / `reviewer` / `creator` は **agmsg の agent 名**であり、そのまま agmsg メッセージの宛先になる。

### 3.2 データモデル（board.db, WAL）

```sql
CREATE TABLE cards (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,  -- 表示は card-<id>
  team       TEXT NOT NULL,                      -- agmsg の team と一致
  title      TEXT NOT NULL,
  col        TEXT NOT NULL DEFAULT 'todo',       -- todo|doing|review|done
  assignee   TEXT,                               -- agmsg agent 名（doing 通知先）
  reviewer   TEXT,                               -- review 通知先
  creator    TEXT,                               -- 起票者（done 通知先）
  blocked_by INTEGER,                            -- 依存カードの id（任意）
  body       TEXT,                               -- 詳細・受け入れ条件
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE card_events (                        -- 監査ログ
  id       INTEGER PRIMARY KEY AUTOINCREMENT,
  card_id  INTEGER NOT NULL,
  team     TEXT NOT NULL,
  actor    TEXT,                                  -- 操作したエージェント
  from_col TEXT,
  to_col   TEXT,
  at       TEXT NOT NULL
);

CREATE INDEX idx_cards_team_col ON cards(team, col);
CREATE INDEX idx_cards_assignee ON cards(team, assignee);
```

- カード ID は DB 全体で一意な整数。表示・メッセージ参照は `card-<id>`（例: `card-12`）。逆参照は `card-` を剥がして解決
- 列は v0 固定の 4 値（todo / doing / review / done）

### 3.3 イベント → agmsg 自動発火（核心）

列遷移時に `events.sh` が宣言的マッピング表を引いて `send.sh` を呼ぶ。`from_agent` は操作した本人（whoami で解決）。

| 遷移 | 送信先 | メッセージ本文（例） |
|---|---|---|
| `* → doing` | `assignee` | `[agkanban] card-12 着手依頼: <title>` |
| `* → review` | `reviewer`（無ければ `creator`） | `[agkanban] card-12 review待ち: <title>` |
| `* → done` | `creator`（+ `assignee` が別なら両方） | `[agkanban] card-12 完了: <title>` |
| `blocked_by 解消`（依存先が done） | 待ちカードの `assignee` | `[agkanban] card-09 のブロック解除` |

- メッセージ本文には必ず `card-<id>` を含める → agmsg 側からカードを一意に逆参照できる
- 送信先が未設定（例: assignee 無しで doing へ）の場合は送信をスキップし、その旨を stderr に警告
- 自分自身宛になる場合は送信しない（ノイズ抑制）

### 3.4 delivery（気づき）

- **push**: agkanban は独自の監視を持たない。発火した agmsg メッセージは agmsg の既存 delivery（turn/monitor/hook）が運ぶ
- **pull**: 状態は永続するため、エージェントは必要時に引く
  - `agkanban mine`（= 引数なしの既定） — 自分が assignee で `doing`/`review` にあるカードを列挙（agmsg の turn モードのボード版。メッセージ配信より堅牢）
  - `agkanban board` — team のボード全体

### 3.5 競合・整合性・フォールバック

- **claim 競合**: 原子的な条件付き UPDATE で 1 人だけ成功させる
  ```sql
  UPDATE cards SET assignee=:me, col='doing', updated_at=:now
   WHERE id=:id AND team=:team AND (assignee IS NULL OR assignee=:me);
  ```
  直後に `changes()` を確認。0 なら「既に他者が claim 済み」を返す
- **状態の正**: board.db が唯一の正。agmsg メッセージは揮発する合図にすぎない
- **agmsg 不在 / 未 join 時**: 識別解決や send.sh 呼び出しが失敗しても、**ボードの状態遷移は実行する**。通知だけスキップして警告を出す（kanban は単体でも動く）

## 4. コマンドインターフェース

`/agkanban` スキルから呼ぶ。agmsg と同じく「スクリプト経由のみ・DB 直叩き禁止」。

```
/agkanban                          # 引数なし = mine と同じ（自分の担当カード）
/agkanban mine                     # 自分が担当の doing/review カード（= 引数なしと同一挙動）
/agkanban add "<title>" [--assignee X] [--reviewer Y] [--body "..."]
/agkanban move <id> <column>       # ← ここで自動 agmsg 発火
/agkanban claim <id>               # assignee=自分 にして doing へ（原子的）
/agkanban show <id>                # カード詳細 + イベント履歴
/agkanban block <id> --by <id2>    # 依存設定
/agkanban board                    # team のボード全体（列ごとの一覧）
```

**引数なしの既定動作は `mine`**（agmsg の「引数なし = inbox を見る」と同じ思想 — 「自分に何が来ているか」をまず見せる）。team のボード全体は明示的に `board` を使う。

複数 team に所属する場合、各コマンドは `--team <name>` を受け付ける。

## 5. ディレクトリ構成

開発リポジトリ（= リポジトリ root がそのままスキル本体）として作り、GitHub へ push する。
install するとこの内容が `~/.agents/skills/agkanban/` に展開される。

```
~/dev/agkanban/                  # git repo → github.com/lucianlamp/agkanban
├── SKILL.md                     # スキル本体（frontmatter + 識別解決 → サブコマンド分岐）
├── README.md                    # ワンライナー install（§9）+ 使い方
├── LICENSE
├── .gitignore                   # db/ は実行時生成物として無視
├── scripts/
│   ├── lib/
│   │   ├── storage.sh           # board.db パス解決（env AGKANBAN_STORAGE_PATH > 既定 <skill>/db）
│   │   ├── agmsg.sh             # agmsg 探索（§3.1）・whoami 解決・send ラッパ（AGMSG_SEND_CMD seam）
│   │   └── events.sh            # 遷移→通知マッピング
│   ├── init-db.sh
│   ├── add.sh
│   ├── move.sh
│   ├── claim.sh
│   ├── mine.sh
│   ├── show.sh
│   ├── board.sh
│   └── block.sh
├── docs/
│   └── 2026-06-15-agkanban-design.md
└── tests/
    └── test_transitions.sh
```

- `db/board.db` は実行時に `init-db.sh` が生成する（リポジトリには含めない＝`.gitignore`）
- 開発（`~/dev/agkanban`）と本番（`~/.agents/skills/agkanban`）でパスが異なるが、agmsg 探索（§3.1）と storage パス解決（env 優先）により両方で動く

## 6. テスト方針

- **状態遷移の単体テスト**: 一時 DB（`AGKANBAN_STORAGE_PATH=$(mktemp -d)`）に対し add → move → claim → block を実行し、`cards` と `card_events` の結果を assert
- **claim 競合**: 同一カードへの 2 連続 claim で 1 回目成功・2 回目失敗を確認
- **agmsg 発火の検証**: `AGMSG_SEND_CMD` を記録用スクリプト（引数をファイルに追記）へ差し替え、各遷移で正しい宛先・本文（`card-<id>` を含む）が渡るかを assert
- **フォールバック**: agmsg を見つけられない状況をシミュレートし、状態遷移は成功・通知はスキップ（警告のみ）を確認

## 7. スコープ外（YAGNI）

v0 では以下を作らない。必要になったら別 spec で追加する。

- Web UI / ダッシュボード（pull コマンドの CLI 表示で足りる）
- priority / due date / label / estimate などのフィールド（v0 は最小フィールドのみ）
- team を跨ぐボード、グローバルボード
- agkanban 独自の monitor / リアルタイム push
- PR 自動化・ACP 連携・worktree 統合

## 8. 配布とインストール

開発は `~/dev/agkanban`（git repo）で行い、`github.com/lucianlamp/agkanban` へ push する。
リポジトリは整備後に public にする（それまで private、install 検証は §3.1 のローカル経路で可能）。

README に載せるワンライナー install（**skills.sh 主 + gh cli 代替**）:

```bash
# 主: skills.sh（~/.agents/skills に自動配置・更新追跡可）
npx --yes skills add lucianlamp/agkanban -g -y

# 代替: gh cli（preview 機能。--scope user で ~/.claude/skills = ~/.agents/skills へ）
gh skill install lucianlamp/agkanban --agent claude-code --scope user
```

- 両方式の共通要件は「正しい frontmatter（`name` / `description`）を持つ root の `SKILL.md`」。単一スキルなのでリポジトリ root に置けば両対応できる
- install 後の配置は `~/.agents/skills/agkanban/`（agmsg と兄弟）。§3.1 の探索順 2/3 にヒットする
- 前提: agmsg（`~/.agents/skills/agmsg`）が install 済みであること。未 install なら agkanban はフォールバックモード（通知なし）で動く。README に「agmsg と併用して真価を発揮する」と明記する

## 9. 未解決の論点

なし（主要決定はすべて確定）。実装中に判明した細部は実装プラン側で扱う。
