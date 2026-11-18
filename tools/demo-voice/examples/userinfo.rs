use dem::types::{EngineMessage, FrameData, NetMessage};
fn main() {
    let d = dem::open_demo(std::env::args().nth(1).unwrap()).unwrap();
    for e in &d.directory.entries { for f in &e.frames {
        let FrameData::NetworkMessage(nm) = &f.frame_data else { continue };
        let Some(m) = nm.1.messages.get_parsed_messages() else { continue };
        for x in m { if let NetMessage::EngineMessage(e) = x { if let EngineMessage::SvcUpdateUserInfo(u) = e.as_ref() {
            println!("{:.2} slot {} id {} {}", f.time, u.index, u.id, String::from_utf8_lossy(&u.user_info.0));
        }}}
    }}
}
