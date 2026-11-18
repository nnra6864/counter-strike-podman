use dem::types::{EngineMessage, FrameData, NetMessage};
fn main() {
    let d = dem::open_demo(std::env::args().nth(1).unwrap()).unwrap();
    let mut last = -10f32; let mut start = 0f32; let mut n = 0;
    for e in &d.directory.entries { for f in &e.frames {
        let FrameData::NetworkMessage(nm) = &f.frame_data else { continue };
        let Some(m) = nm.1.messages.get_parsed_messages() else { continue };
        for x in m { match x {
            NetMessage::EngineMessage(e) => match e.as_ref() {
                EngineMessage::SvcVoiceData(v) if !v.data.is_empty() => {
                    if f.time - last > 0.6 { if n > 0 { println!("  spurt {n}: {start:.2}..{last:.2} ({:.1}s)", last - start); } n += 1; start = f.time; }
                    last = f.time;
                }
                EngineMessage::SvcUpdateUserInfo(u) => println!("{:.2} userinfo slot {} {}", f.time, u.index, String::from_utf8_lossy(&u.user_info.0).split("\\name\\").nth(1).unwrap_or("(empty)").split('\\').next().unwrap()),
                _ => {}
            },
            NetMessage::UserMessage(u) if String::from_utf8_lossy(&u.name.0).starts_with("TeamInfo") => println!("{:.2} TeamInfo ent {} {}", f.time, u.data[0], String::from_utf8_lossy(&u.data[1..]).trim_end_matches('\0')),
            _ => {}
        }}
    }}
    println!("  spurt {n}: {start:.2}..{last:.2} ({:.1}s)", last - start);
}
