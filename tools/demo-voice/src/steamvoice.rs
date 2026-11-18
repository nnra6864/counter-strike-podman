//! Steam voice packets, as sent by Steam clients when the server announces no codec
//! (ReHLDS sends an empty svc_voiceinit codec).
//!
//! Layout, as known from other Source/GoldSrc tools:
//!   u64 SteamID, then chunks until the last 4 bytes (CRC32):
//!     0x0B u16  sample rate
//!     0x0A u16  unknown, skipped
//!     0x00 u16  silence, in samples
//!     0x04 u16 len, data  SILK (frames of u16 len + data)
//!     0x06 u16 len, data  Opus PLC (frames of u16 len + u16 seq + data)
//!
//! Confirmed on a CS 1.6 demo (2026-11-18, Steam client): 24000 Hz, Opus PLC chunks, CRC ok.

pub enum Chunk<'a> {
    SampleRate(u16),
    Silence(u16),
    Silk(&'a [u8]),
    Opus(&'a [u8]),
    Unknown(u8),
}

pub struct Packet<'a> {
    pub steamid: u64,
    pub chunks: Vec<Chunk<'a>>,
    pub crc_ok: bool,
}

fn u16le(d: &[u8], i: usize) -> Option<u16> {
    Some(u16::from_le_bytes([*d.get(i)?, *d.get(i + 1)?]))
}

pub fn parse(d: &[u8]) -> Option<Packet<'_>> {
    if d.len() < 8 + 4 {
        return None;
    }
    let steamid = u64::from_le_bytes(d[..8].try_into().ok()?);
    // Individual SteamID64s start with 0x0110_0001
    if steamid >> 32 != 0x0110_0001 {
        return None;
    }
    let body = &d[..d.len() - 4];
    let crc = u32::from_le_bytes(d[d.len() - 4..].try_into().ok()?);
    let mut chunks = Vec::new();
    let mut i = 8;
    while i < body.len() {
        let op = body[i];
        i += 1;
        match op {
            0x0B => {
                chunks.push(Chunk::SampleRate(u16le(body, i)?));
                i += 2;
            }
            0x0A => i += 2,
            0x00 => {
                chunks.push(Chunk::Silence(u16le(body, i)?));
                i += 2;
            }
            0x04 | 0x06 => {
                let len = u16le(body, i)? as usize;
                i += 2;
                let data = body.get(i..i + len)?;
                i += len;
                chunks.push(if op == 0x04 { Chunk::Silk(data) } else { Chunk::Opus(data) });
            }
            _ => {
                chunks.push(Chunk::Unknown(op));
                break;
            }
        }
    }
    Some(Packet { steamid, chunks, crc_ok: crc32(body) == crc })
}

pub fn describe(d: &[u8]) -> String {
    let Some(p) = parse(d) else { return "(not a Steam voice packet)".into() };
    let chunks: Vec<String> = p
        .chunks
        .iter()
        .map(|c| match c {
            Chunk::SampleRate(r) => format!("rate={r}"),
            Chunk::Silence(n) => format!("silence={n}"),
            Chunk::Silk(x) => format!("silk={}B", x.len()),
            Chunk::Opus(x) => format!("opus={}B", x.len()),
            Chunk::Unknown(op) => format!("unknown op 0x{op:02x}"),
        })
        .collect();
    format!("steam {} crc {} [{}]", p.steamid, if p.crc_ok { "ok" } else { "BAD" }, chunks.join(" "))
}

/// Opus frames are 20 ms
const FRAME: usize = crate::SAMPLE_RATE as usize / 50;

/// One per player: Opus is stateful, and frame sequence numbers carry across packets
pub struct Decoder {
    opus: opus::Decoder,
    next_seq: Option<u16>,
}

impl Decoder {
    pub fn new() -> Result<Decoder, String> {
        let opus = opus::Decoder::new(crate::SAMPLE_RATE, opus::Channels::Mono).map_err(|e| e.to_string())?;
        Ok(Decoder { opus, next_seq: None })
    }

    fn reset(&mut self) {
        let _ = self.opus.reset_state();
        self.next_seq = None;
    }

    /// Decodes a packet to mono f32 samples at crate::SAMPLE_RATE
    pub fn decode(&mut self, d: &[u8]) -> Result<Vec<f32>, String> {
        let p = parse(d).ok_or("not a Steam voice packet (unknown codec)")?;
        let mut out = Vec::new();
        for c in &p.chunks {
            match c {
                Chunk::SampleRate(r) if *r as u32 != crate::SAMPLE_RATE => {
                    return Err(format!("sample rate {r} not supported yet"));
                }
                Chunk::SampleRate(_) => {}
                Chunk::Silence(n) => out.extend(std::iter::repeat_n(0.0, *n as usize)),
                Chunk::Opus(data) => self.opus_plc(data, &mut out)?,
                Chunk::Silk(_) => return Err("SILK decoding not implemented".into()),
                Chunk::Unknown(op) => return Err(format!("unknown chunk 0x{op:02x}")),
            }
        }
        Ok(out)
    }

    /// Frames of: u16 len, u16 seq, Opus packet. len 0xFFFF resets the decoder
    fn opus_plc(&mut self, mut d: &[u8], out: &mut Vec<f32>) -> Result<(), String> {
        let mut buf = vec![0f32; FRAME * 6];
        while d.len() >= 2 {
            let len = u16le(d, 0).unwrap();
            if len == 0xFFFF {
                self.reset();
                d = &d[2..];
                continue;
            }
            let seq = u16le(d, 2).ok_or("truncated Opus frame")?;
            let frame = d.get(4..4 + len as usize).ok_or("truncated Opus frame")?;
            d = &d[4 + len as usize..];
            if let Some(next) = self.next_seq {
                let lost = seq.wrapping_sub(next);
                if lost > 0x8000 {
                    // Went backwards: a new stream
                    self.reset();
                } else if lost > 0 {
                    // Conceal a short loss, a long one is just a gap
                    for _ in 0..lost.min(10) {
                        let n = self.opus.decode_float(&[], &mut buf, false).map_err(|e| e.to_string())?;
                        out.extend_from_slice(&buf[..n]);
                    }
                }
            }
            self.next_seq = Some(seq.wrapping_add(1));
            if frame.is_empty() {
                continue;
            }
            let n = self.opus.decode_float(frame, &mut buf, false).map_err(|e| e.to_string())?;
            out.extend_from_slice(&buf[..n]);
        }
        Ok(())
    }
}

fn crc32(d: &[u8]) -> u32 {
    let mut c = !0u32;
    for &b in d {
        c ^= b as u32;
        for _ in 0..8 {
            c = if c & 1 != 0 { (c >> 1) ^ 0xEDB8_8320 } else { c >> 1 };
        }
    }
    !c
}
