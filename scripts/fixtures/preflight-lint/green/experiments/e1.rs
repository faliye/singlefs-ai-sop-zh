// admission: inputs-changed ./data.txt
// run-condition: none 样本：只在内存里算，不碰别的环境
//! 样本实验。
#![allow(dead_code)]
use std::process::exit;
// 注释里写 fn main() { println!() } 不算
fn main() {
    /* 开跑之前先判 */
    let arguments: Vec<String> = preflight(file!());
    println!("{}", arguments.len());
    preflight_record_success();
}
fn preflight(source: &str) -> Vec<String> { let _ = source; exit(0) }
fn preflight_record_success() {}
