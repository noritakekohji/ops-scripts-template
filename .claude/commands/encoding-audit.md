---
description: ".ps1 の UTF-8 BOM 欠落 と .sh の CRLF 混入を全件検査"
allowed-tools: Bash
---

リポジトリ全体のエンコーディング規約を機械的にチェックしてください。development-rules.md
の要件に従い、以下のいずれかが見つかったら違反として一覧化します。

1. **`.ps1` / `.psm1` で UTF-8 BOM が無いもの**（CP932 環境で文字化けする）
2. **`.sh` で CRLF を含むもの**（Linux でシバン行が壊れる、Shift-JIS LF-eating が起きる）
3. **`.bat` で LF のみのもの**（cmd.exe が CRLF を期待）

検査スクリプト例:

```bash
python <<'EOF'
import os
ps_missing_bom = []
sh_with_crlf = []
bat_with_lf_only = []
for root, _, files in os.walk('.'):
    if '.git' in root.split(os.sep): continue
    for fn in files:
        p = os.path.join(root, fn)
        with open(p, 'rb') as f:
            data = f.read()
        if fn.endswith(('.ps1', '.psm1')) and data[:3] != b'\xef\xbb\xbf':
            ps_missing_bom.append(p)
        elif fn.endswith('.sh') and b'\r\n' in data:
            sh_with_crlf.append(p)
        elif fn.endswith('.bat') and b'\r\n' not in data and b'\n' in data:
            bat_with_lf_only.append(p)
for label, lst in [('PS missing BOM', ps_missing_bom),
                    ('SH with CRLF',   sh_with_crlf),
                    ('BAT with LF only', bat_with_lf_only)]:
    print(f'== {label} ({len(lst)}) ==')
    for p in lst: print(' ', p)
EOF
```

結果を 3 グループに分けて報告し、各違反について自動修正の許可を求めてください。修正は
それぞれ:

- PS BOM 不足 → 先頭に `\xef\xbb\xbf` を付与
- SH CRLF → `\r\n` を `\n` に置換
- BAT LF のみ → `\n` を `\r\n` に置換
