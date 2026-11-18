use dem::types::{FrameData, NetMessage};
use std::collections::BTreeMap;
fn main() {
    let d = dem::open_demo(std::env::args().nth(1).unwrap()).unwrap();
    let mut c: BTreeMap<String, usize> = BTreeMap::new();
    for e in &d.directory.entries { for f in &e.frames {
        let FrameData::NetworkMessage(nm) = &f.frame_data else { continue };
        let Some(m) = nm.1.messages.get_parsed_messages() else { *c.entry("UNPARSED".into()).or_default() += 1; continue };
        for x in m { let k = match x { NetMessage::EngineMessage(e) => format!("{:?}", e).split('(').next().unwrap().to_string(), NetMessage::UserMessage(u) => format!("user:{}", String::from_utf8_lossy(&u.name.0).trim_end_matches('\0')) }; *c.entry(k).or_default() += 1; }
    }}
    for (k, v) in c { println!("{v:6} {k}"); }
}
