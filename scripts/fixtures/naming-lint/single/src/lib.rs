pub fn scale_all(values: &mut [u64], factor: u64) {
    for i in 0..values.len() {
        values[i] *= factor;
    }
}

pub fn first_or_default<T: Copy + Default>(items: &[T]) -> T {
    items.first().copied().unwrap_or_default()
}

pub fn longer_text<'a>(left_text: &'a str, right_text: &'a str) -> &'a str {
    if left_text.len() > right_text.len() { left_text } else { right_text }
}

pub fn doubled(values: &[u64]) -> Vec<u64> {
    values.iter().map(|x| x * 2).collect()
}

pub fn add_one(n: u64) -> u64 {
    n + 1
}

pub struct Point {
    pub x_offset: u64,
}

pub enum Choice {
    A,
    Second,
}

pub fn describe(result: Result<u64, String>) -> u64 {
    match result {
        Ok(value) => value,
        Err(e) => u64::try_from(e.len()).unwrap_or(0),
    }
}

pub fn elapsed_ticks() -> u64 {
    let t0 = 5;
    t0
}

pub const N: usize = 4;

pub mod m {}

use std::collections::HashMap as M;

macro_rules! triple {
    ($x:expr) => {
        $x * 3
    };
}

pub fn search() -> u64 {
    'a: loop {
        break 'a 1;
    }
}

pub fn weight_for_side_a() -> u8 {
    1
}
