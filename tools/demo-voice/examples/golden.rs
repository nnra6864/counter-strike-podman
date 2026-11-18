//! Golden dump for goldsrc-hltv-voice tests: every voice packet, userinfo and TeamInfo, in demo order.
//! One line each, tab separated:
//!   voice     <entry> <frame> <time> <slot> <len> <hex>
//!   userinfo  <entry> <frame> <time> <slot> <infostring>
//!   teaminfo  <entry> <frame> <time> <entindex> <team>
//!   voiceinit <entry> <frame> <time> <codec> <quality>
use dem::types::{EngineMessage, FrameData, NetMessage};
fn s(b: &[u8]) -> String { String::from_utf8_lossy(&b[..b.iter().position(|&c| c == 0).unwrap_or(b.len())]).into_owned() }
fn main() {
    let d = dem::open_demo(std::env::args().nth(1).unwrap()).unwrap();
    for (ei, e) in d.directory.entries.iter().enumerate() { for (fi, f) in e.frames.iter().enumerate() {
        let FrameData::NetworkMessage(nm) = &f.frame_data else { continue };
        let Some(m) = nm.1.messages.get_parsed_messages() else { println!("unparsed\t{ei}\t{fi}\t{:.6}", f.time); continue };
        for x in m { match x {
            NetMessage::EngineMessage(em) => match em.as_ref() {
                EngineMessage::SvcVoiceData(v) => println!("voice\t{ei}\t{fi}\t{:.6}\t{}\t{}\t{}", f.time, v.player_index, v.data.len(), v.data.iter().map(|b| format!("{b:02x}")).collect::<String>()),
                EngineMessage::SvcUpdateUserInfo(u) => println!("userinfo\t{ei}\t{fi}\t{:.6}\t{}\t{}", f.time, u.index, s(&u.user_info.0)),
                EngineMessage::SvcVoiceInit(v) => println!("voiceinit\t{ei}\t{fi}\t{:.6}\t{}\t{}", f.time, s(&v.codec_name), v.quality),
                _ => {}
            },
            NetMessage::UserMessage(u) if s(&u.name.0) == "TeamInfo" => println!("teaminfo\t{ei}\t{fi}\t{:.6}\t{}\t{}", f.time, u.data[0], s(&u.data[1..])),
            _ => {}
        }}
    }}
}
