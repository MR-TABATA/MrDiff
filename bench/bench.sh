#!/bin/sh
# mrdiff とシステムの diff を、4 通りの「違い方」で比べる。
#
#     sh bench/bench.sh            # 100 万行 × 2
#     LINES=200000 sh bench/bench.sh
#
# 4 通りに分けるのは、**この種の diff が「サイズ」ではなく「違い方」で速さが変わる**
# ため。1 つの数字で「速い / 遅い」とは言えない。
set -e
cd "$(dirname "$0")/.."

LINES=${LINES:-1000000}
DIR=${DIR:-./bench/data}
mkdir -p "$DIR"

echo "== 1) 材料を作る（$LINES 行 × 2）"
python3 - "$DIR" "$LINES" <<'PY'
import sys, pathlib
d, N = pathlib.Path(sys.argv[1]), int(sys.argv[2])

def line(i, status=200):
    return (f"2026-09-10 09:{i//60%60:02d}:{i%60:02d} INFO  GET /path/{i%997} "
            f"status={status} latency={i%97}ms bytes={i*7%100000}")

def w(name, lines):
    p = d / name
    p.write_text("\n".join(lines) + "\n")
    print(f"   {name:16s} {p.stat().st_size//1_000_000} MB")

base = [line(i) for i in range(N)]
w("a.log", base)

# ① 先頭に 1 行入った ── 以降が全部 1 行ずれる。人が見れば「1 行足しただけ」
w("shift.log", ["2026-09-10 08:59:59 INFO  boot"] + base[:-1])

# ② 3 行だけ違う ── 離れた位置に点在させる（先頭・中間・末尾）
few = list(base)
for i in (12345, N//2, N-2):
    few[i] = few[i].replace("status=200", "status=500")
w("few.log", few)

# ③ 10 行に 1 行違う ── 違いが散らばっている
dense = [line(i, 500) if i % 10 == 0 else line(i) for i in range(N)]
w("dense.log", dense)

# ④ 全行が違う ── 合流点が 1 つも無い、いちばん重い形
w("all.log", [line(i, 500) + " x" for i in range(N)])
PY

echo
echo "== 2) mrdiff を release で組む"
swift build -c release >/dev/null
MRDIFF=./.build/release/mrdiff

# 比較相手。GNU diffutils が入っていれば、それも測る
SYS_DIFF=/usr/bin/diff
GNU_DIFF=""
for c in /opt/homebrew/opt/diffutils/bin/diff "$(command -v gdiff 2>/dev/null)"; do
  [ -x "$c" ] && GNU_DIFF="$c" && break
done

echo
echo "   比較相手: $SYS_DIFF ── $($SYS_DIFF --version 2>&1 | head -1)"
[ -n "$GNU_DIFF" ] && echo "             $GNU_DIFF ── $($GNU_DIFF --version 2>&1 | head -1)"

run() {
  # 1 回目はページキャッシュが冷たいので捨て、2 回目を採る
  "$@" >/dev/null 2>&1 || true
  # **`|| true` を外さないこと。**diff は「違いがある」と終了コード 1 を返すので、
  # set -e の下だとここで副シェルごと落ちて、列が空のまま表になる（一度やった）。
  out=$(/usr/bin/time -l "$@" 2>&1 >/dev/null) || true
  t=$(echo "$out" | awk '/real/{print $1}')
  m=$(echo "$out" | awk '/maximum resident/{print $1}')
  printf "%7s 秒 %5d MB" "$t" $((m / 1000000))
}

echo
echo "== 3) 測る（出力は捨てる。時間は 2 回目・メモリは最大常駐）"
echo
printf "%-22s %-20s %-20s %s\n" "違い方" "mrdiff" "$(basename $SYS_DIFF)(Apple)" "GNU diff"
for case in "shift.log:先頭に 1 行入った" "few.log:3 行だけ違う" \
            "dense.log:10 行に 1 行違う" "all.log:全行が違う"; do
  f=${case%%:*}; label=${case#*:}
  printf "%-22s " "$label"
  printf "%-20s " "$(run $MRDIFF --color=never $DIR/a.log $DIR/$f)"
  printf "%-20s " "$(run $SYS_DIFF $DIR/a.log $DIR/$f)"
  [ -n "$GNU_DIFF" ] && run $GNU_DIFF $DIR/a.log $DIR/$f
  echo
done

echo
echo "== 4) 判定だけ（表示を外すと、比較そのものが何秒か分かる）"
printf "%-22s " "全行が違う --json"
run $MRDIFF --json $DIR/a.log $DIR/all.log
echo
echo
echo "   材料は $DIR/ に残してある。消すなら: rm -rf $DIR"
