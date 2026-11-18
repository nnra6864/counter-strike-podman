//! Extracts voice chat from a GoldSrc (CS 1.6) HLTV demo into one .mka with a track per player.
//!
//!   demo-voice <demo.dem> [-o out.mka] [--tracks player|team|mix] [--order join|team] [--dump]
//!
//! Every svc_voicedata in the demo carries the sender's slot. Packets are grouped per player
//! (by SteamID, so a rejoin continues the same track), decoded, placed at their demo time and
//! muxed with ffmpeg. Tracks are named after the player.
//!
//! --order join  by when each player first joined (default, works for any server)
//! --order team  by the team each player started on: T, then CT, then the rest,
//!               by join time within a team (competitive)

mod steamvoice;

use dem::types::{EngineMessage, FrameData, NetMessage};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode};

pub const SAMPLE_RATE: u32 = 24000;

#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Debug)]
enum Team {
    T,
    Ct,
    Other,
}

impl Team {
    fn parse(s: &str) -> Team {
        match s.to_ascii_uppercase().as_str() {
            "TERRORIST" => Team::T,
            "CT" => Team::Ct,
            _ => Team::Other,
        }
    }
    fn label(self) -> &'static str {
        match self {
            Team::T => "T",
            Team::Ct => "CT",
            Team::Other => "Other",
        }
    }
}

struct Player {
    name: String,
    steamid: String,
    /// Demo time this player first showed up
    joined: f32,
    /// First real team (T or CT) this player was on
    start_team: Team,
    packets: Vec<(f32, Vec<u8>)>,
}

#[derive(Clone, Copy, PartialEq)]
enum Order {
    Join,
    Team,
}

#[derive(Clone, Copy, PartialEq)]
enum Tracks {
    Player,
    Team,
    Mix,
}

struct Args {
    demo: PathBuf,
    out: Option<PathBuf>,
    tracks: Tracks,
    order: Order,
    dump: bool,
}

fn usage() -> ExitCode {
    eprintln!("usage: demo-voice <demo.dem> [-o out.mka] [--tracks player|team|mix] [--order join|team] [--dump]");
    ExitCode::from(2)
}

fn parse_args() -> Option<Args> {
    let mut it = std::env::args().skip(1);
    let (mut demo, mut out, mut tracks, mut order, mut dump) = (None, None, Tracks::Player, Order::Join, false);
    while let Some(a) = it.next() {
        match a.as_str() {
            "-o" | "--output" => out = Some(PathBuf::from(it.next()?)),
            "--tracks" => {
                tracks = match it.next()?.as_str() {
                    "player" => Tracks::Player,
                    "team" => Tracks::Team,
                    "mix" => Tracks::Mix,
                    _ => return None,
                }
            }
            "--order" => {
                order = match it.next()?.as_str() {
                    "join" => Order::Join,
                    "team" => Order::Team,
                    _ => return None,
                }
            }
            "--dump" => dump = true,
            "-h" | "--help" => return None,
            _ if demo.is_none() => demo = Some(PathBuf::from(a)),
            _ => return None,
        }
    }
    Some(Args { demo: demo?, out, tracks, order, dump })
}

/// Reads a userinfo string ("\name\nnra\*sid\765...") into a map
fn userinfo(s: &str) -> HashMap<String, String> {
    let mut parts = s.trim_start_matches('\\').split('\\');
    let mut map = HashMap::new();
    while let (Some(k), Some(v)) = (parts.next(), parts.next()) {
        map.insert(k.to_string(), v.to_string());
    }
    map
}

fn cstr(b: &[u8]) -> String {
    let end = b.iter().position(|&c| c == 0).unwrap_or(b.len());
    String::from_utf8_lossy(&b[..end]).into_owned()
}

struct Parsed {
    codec: Option<String>,
    duration: f32,
    /// Players that spoke, in first-join order
    players: Vec<Player>,
}

fn parse(path: &Path) -> Result<Parsed, String> {
    let demo = dem::open_demo(path).map_err(|e| format!("{}: {e:?}", path.display()))?;
    let mut codec = None;
    let mut duration = 0f32;
    let mut players: Vec<Player> = Vec::new();
    // Identity (SteamID, or name without one) -> index in players
    let mut by_id: HashMap<String, usize> = HashMap::new();
    // Slot (0-based) -> whoever is in it right now
    let mut slots: HashMap<u8, usize> = HashMap::new();

    for entry in &demo.directory.entries {
        for frame in &entry.frames {
            let t = frame.time;
            duration = duration.max(t);
            let FrameData::NetworkMessage(nm) = &frame.frame_data else { continue };
            let Some(msgs) = nm.1.messages.get_parsed_messages() else { continue };
            for msg in msgs {
                match msg {
                    NetMessage::EngineMessage(em) => match em.as_ref() {
                        EngineMessage::SvcVoiceInit(v) => codec = Some(cstr(&v.codec_name)),
                        EngineMessage::SvcUpdateUserInfo(u) => {
                            let info = userinfo(&cstr(&u.user_info.0));
                            let Some(name) = info.get("name").filter(|n| !n.is_empty()) else {
                                // Empty userinfo: the slot was freed
                                slots.remove(&u.index);
                                continue;
                            };
                            // HLTV itself
                            if info.get("*hltv").is_some() {
                                continue;
                            }
                            let sid = info.get("*sid").cloned().unwrap_or_default();
                            let id = if sid.is_empty() || sid == "0" { format!("name:{name}") } else { sid.clone() };
                            let i = *by_id.entry(id).or_insert_with(|| {
                                players.push(Player {
                                    name: name.clone(),
                                    steamid: sid.clone(),
                                    joined: t,
                                    start_team: Team::Other,
                                    packets: Vec::new(),
                                });
                                players.len() - 1
                            });
                            // Latest name wins, renames included
                            players[i].name = name.clone();
                            slots.insert(u.index, i);
                        }
                        EngineMessage::SvcVoiceData(v) if !v.data.is_empty() => {
                            let i = *slots.entry(v.player_index).or_insert_with(|| {
                                players.push(Player {
                                    name: format!("slot {}", v.player_index + 1),
                                    steamid: String::new(),
                                    joined: t,
                                    start_team: Team::Other,
                                    packets: Vec::new(),
                                });
                                players.len() - 1
                            });
                            players[i].packets.push((t, v.data.clone()));
                        }
                        _ => {}
                    },
                    // TeamInfo: entity index (slot + 1), team name
                    NetMessage::UserMessage(um) if cstr(&um.name.0) == "TeamInfo" && !um.data.is_empty() => {
                        let team = Team::parse(&cstr(&um.data[1..]));
                        if let Some(&i) = um.data[0].checked_sub(1).and_then(|s| slots.get(&s)) {
                            if players[i].start_team == Team::Other {
                                players[i].start_team = team;
                            }
                        }
                    }
                    _ => {}
                }
            }
        }
    }
    players.retain(|p| !p.packets.is_empty());
    Ok(Parsed { codec, duration, players })
}

fn dump(p: &Parsed) {
    println!("codec: {:?}, duration {:.1}s", p.codec.as_deref().unwrap_or("(no svc_voiceinit)"), p.duration);
    for pl in &p.players {
        let bytes: usize = pl.packets.iter().map(|(_, d)| d.len()).sum();
        println!(
            "{:5} {:24} {:20} joined {:7.1}s, {:5} packets, {bytes} bytes, {:.1}s..{:.1}s",
            pl.start_team.label(),
            pl.name,
            pl.steamid,
            pl.joined,
            pl.packets.len(),
            pl.packets.first().map_or(0.0, |x| x.0),
            pl.packets.last().map_or(0.0, |x| x.0),
        );
        for (t, d) in pl.packets.iter().take(3) {
            let hex: String = d.iter().take(32).map(|b| format!("{b:02x}")).collect();
            println!("    {t:8.3}s {:4}B {hex} {}", d.len(), steamvoice::describe(d));
        }
    }
}

/// Decodes one player's packets onto a timeline of `len` samples
fn render(pl: &Player, len: usize) -> Result<Vec<f32>, String> {
    let mut pcm = vec![0f32; len];
    let mut cursor = 0usize;
    let mut dec = steamvoice::Decoder::new()?;
    for (t, data) in &pl.packets {
        let samples = dec.decode(data)?;
        // A packet lands at its demo time, or right after the previous one if that overlaps
        let at = ((*t as f64 * SAMPLE_RATE as f64) as usize).max(cursor);
        for (i, s) in samples.iter().enumerate() {
            if let Some(o) = pcm.get_mut(at + i) {
                *o += *s;
            }
        }
        cursor = at + samples.len();
    }
    Ok(pcm)
}

fn write_wav(path: &Path, pcm: &[f32]) -> std::io::Result<()> {
    let data: Vec<u8> = pcm
        .iter()
        .flat_map(|s| ((s.clamp(-1.0, 1.0) * i16::MAX as f32) as i16).to_le_bytes())
        .collect();
    let mut h = Vec::with_capacity(44 + data.len());
    h.extend_from_slice(b"RIFF");
    h.extend_from_slice(&(36 + data.len() as u32).to_le_bytes());
    h.extend_from_slice(b"WAVEfmt ");
    h.extend_from_slice(&16u32.to_le_bytes());
    h.extend_from_slice(&1u16.to_le_bytes()); // PCM
    h.extend_from_slice(&1u16.to_le_bytes()); // mono
    h.extend_from_slice(&SAMPLE_RATE.to_le_bytes());
    h.extend_from_slice(&(SAMPLE_RATE * 2).to_le_bytes());
    h.extend_from_slice(&2u16.to_le_bytes());
    h.extend_from_slice(&16u16.to_le_bytes());
    h.extend_from_slice(b"data");
    h.extend_from_slice(&(data.len() as u32).to_le_bytes());
    h.extend_from_slice(&data);
    std::fs::write(path, h)
}

fn main() -> ExitCode {
    let Some(args) = parse_args() else { return usage() };
    let parsed = match parse(&args.demo) {
        Ok(p) => p,
        Err(e) => {
            eprintln!("demo-voice: {e}");
            return ExitCode::FAILURE;
        }
    };
    if args.dump {
        dump(&parsed);
        return ExitCode::SUCCESS;
    }
    if parsed.players.is_empty() {
        eprintln!("demo-voice: no voice in {}", args.demo.display());
        return ExitCode::FAILURE;
    }

    // Already in join order; the sort is stable, so team order keeps join order within a team
    let mut players: Vec<&Player> = parsed.players.iter().collect();
    if args.order == Order::Team {
        players.sort_by_key(|p| p.start_team);
    }

    let len = ((parsed.duration as f64 + 1.0) * SAMPLE_RATE as f64) as usize;
    // (title, steamid, pcm)
    let mut tracks: Vec<(String, String, Vec<f32>)> = Vec::new();
    for pl in &players {
        let pcm = match render(pl, len) {
            Ok(p) => p,
            Err(e) => {
                eprintln!("demo-voice: {}: {e}. Run with --dump to see the packets", pl.name);
                return ExitCode::FAILURE;
            }
        };
        let (title, sid) = match args.tracks {
            // Players are already unique, so always a new track
            Tracks::Player => {
                tracks.push((pl.name.clone(), pl.steamid.clone(), pcm));
                continue;
            }
            Tracks::Team => (pl.start_team.label().to_string(), String::new()),
            Tracks::Mix => ("All".to_string(), String::new()),
        };
        match tracks.iter_mut().find(|t| t.0 == title) {
            Some(t) => t.2.iter_mut().zip(&pcm).for_each(|(a, b)| *a += b),
            None => tracks.push((title, sid, pcm)),
        }
    }

    let out = args.out.unwrap_or_else(|| args.demo.with_extension("mka"));
    let tmp = std::env::temp_dir().join(format!("demo-voice-{}", std::process::id()));
    if let Err(e) = std::fs::create_dir_all(&tmp) {
        eprintln!("demo-voice: {}: {e}", tmp.display());
        return ExitCode::FAILURE;
    }
    let mut cmd = Command::new("ffmpeg");
    cmd.args(["-hide_banner", "-loglevel", "error", "-y"]);
    for (i, t) in tracks.iter().enumerate() {
        let wav = tmp.join(format!("{i}.wav"));
        if let Err(e) = write_wav(&wav, &t.2) {
            eprintln!("demo-voice: {}: {e}", wav.display());
            return ExitCode::FAILURE;
        }
        cmd.arg("-i").arg(wav);
    }
    for (i, (title, sid, _)) in tracks.iter().enumerate() {
        cmd.args(["-map", &i.to_string()]);
        cmd.arg(format!("-metadata:s:a:{i}")).arg(format!("title={title}"));
        if !sid.is_empty() {
            cmd.arg(format!("-metadata:s:a:{i}")).arg(format!("STEAMID={sid}"));
        }
    }
    cmd.args(["-c:a", "libopus", "-b:a", "48k", "-metadata"]);
    cmd.arg(format!("title={}", args.demo.file_stem().unwrap_or_default().to_string_lossy()));
    cmd.arg(&out);
    let status = cmd.status();
    let _ = std::fs::remove_dir_all(&tmp);
    match status {
        Ok(s) if s.success() => {
            for (title, _, _) in &tracks {
                println!("{title}");
            }
            println!("-> {}", out.display());
            ExitCode::SUCCESS
        }
        Ok(s) => {
            eprintln!("demo-voice: ffmpeg failed ({s})");
            ExitCode::FAILURE
        }
        Err(e) => {
            eprintln!("demo-voice: can't run ffmpeg: {e}");
            ExitCode::FAILURE
        }
    }
}
