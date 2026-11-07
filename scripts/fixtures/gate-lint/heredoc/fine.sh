#!/usr/bin/env bash
# 样本：该绿的。用 heredoc 生成「故意写坏的样本」是正当写法，
# 按代码读会把样本内容当成真实拒绝。
make_sample() {
  cat > "$1/sample.sh" <<'SAMPLE'
#!/usr/bin/env bash
check() {
  bad "这个样本故意没有出路"
}
die "样本里的 die 也只带一句话"
SAMPLE
}
make_sample /tmp/x
