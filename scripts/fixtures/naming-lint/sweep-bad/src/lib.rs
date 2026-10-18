//! 样本：名字全写对，外加每一种豁免的边界。文档注释里的 let i = 0 与 cnt 不算。
use std::fmt;

/* 块注释里的 let tmp = 0 也不算 */
/*
 * 多行块注释里的 fn f(x: u8) 也不算
 */
pub const MAXIMUM_EXTENT_COUNT: usize = 16;

pub struct BlockAddress {
    pub lba_offset_in_blocks: u64,
}

pub enum Durability {
    Synced,
    Buffered,
}

impl PartialEq for BlockAddress {
    fn ne(&self, other: &Self) -> bool {
        let closing_brace_character = '}';
        let quote_character = '\'';
        let _ = (closing_brace_character, quote_character);
        self.lba_offset_in_blocks != other.lba_offset_in_blocks
    }
    fn eq(&self, other: &Self) -> bool {
        self.lba_offset_in_blocks == other.lba_offset_in_blocks
    }
}

impl PartialOrd for BlockAddress {
    fn lt(&self, other: &Self) -> bool {
        let opening_brace_character = '{';
        let _ = opening_brace_character;
        self.lba_offset_in_blocks < other.lba_offset_in_blocks
    }
    fn partial_cmp(&self, other: &Self) -> Option<std::cmp::Ordering> {
        self.lba_offset_in_blocks.partial_cmp(&other.lba_offset_in_blocks)
    }
}

impl fmt::Display for BlockAddress {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "{}", self.lba_offset_in_blocks)
    }
}

pub struct Wrapper<Element> {
    pub inner_value: Element,
}

impl<Element> fmt::Debug
    for Wrapper<Element>
where
    Element: fmt::Debug,
{
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "{:?}", self.inner_value)
    }
}

pub struct ExtentIterator<'journal> {
    remaining_extents: &'journal [u64],
}

impl<'journal> Iterator for ExtentIterator<'journal> {
    type Item = u64;
    fn next(&mut self) -> Option<u64> {
        let (first_extent, rest_of_extents) = self.remaining_extents.split_first()?;
        self.remaining_extents = rest_of_extents;
        Some(*first_extent)
    }
}

pub fn describe_durability(durability: &Durability) -> &'static str {
    match durability {
        Durability::Synced => "let tmp = 0",
        Durability::Buffered => r#"text with "let cnt = 1" inside"#,
    }
}

pub fn convert_to_u64_and_turn_off(value_as_u32: u32, opt_in_flag_is_set: bool) -> u64 {
    let widened_value = u64::from(value_as_u32);
    if opt_in_flag_is_set { widened_value } else { 0 }
}

pub fn value_is_a_power_of_two(value: u64) -> bool {
    value.is_power_of_two()
}

pub fn doubled_values(values: &[u64]) -> Vec<u64> {
    values.iter().map(|each_value| each_value * 2).collect()
}

extern "C" {
    fn strlen(s: *const u8) -> usize;
}

pub fn external_format_seed() -> u8 {
    let crc_seed = 7; // naming-lint:external 字段名照外部格式的规范原样写
    crc_seed
}
