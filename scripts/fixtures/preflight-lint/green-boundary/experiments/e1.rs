//! 样本实验：内属性夹在文件头中间（第 2 行），声明写在它之后，文件头照样认
#![allow(dead_code)]
// admission: always 样本：每次调都有意义，它只在内存里算
// run-condition: none 样本：只在内存里算，不碰别的环境
fn main() {
    preflight(file!());
}
fn preflight(source: &str) { let _ = source; }
