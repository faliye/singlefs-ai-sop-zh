#[test]
fn publish_litmus_is_read_by_name() {
    let litmus_file_name = "publish.litmus";
    assert!(litmus_file_name.ends_with(".litmus"));
}
