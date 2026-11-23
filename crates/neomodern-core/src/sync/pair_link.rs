//! The pairing QR code (decision K23).
//!
//! The computer shows its pairing code as a QR code that also carries its LAN
//! addresses, so the phone does not have to type anything:
//!
//! ```text
//! neomodern://pair?v=1&c=123456&a=192.168.1.20:47321,10.0.0.5:47321
//! ```
//!
//! It is the same 6-digit code with the same rules (2 minutes, 3 wrong
//! attempts, SPAKE2), so the QR changes nothing about pairing security; the
//! addresses are only hints and every one is checked to be a LAN address.
//! The phone tries them in order until one answers.
//!
//! A Jam (K27, docs/JAM.md) shows its code the same way, under its own
//! prefix so the two can never be mixed up:
//!
//! ```text
//! neomodern://jam?v=1&c=123456&a=192.168.1.20:47321
//! ```

use super::link::is_lan_address;
use qrcode::{Color, EcLevel, QrCode};
use serde::Serialize;
use std::net::SocketAddr;

const PREFIX: &str = "neomodern://pair?";
const JAM_PREFIX: &str = "neomodern://jam?";
const LINK_VERSION: &str = "1";
/// Longest link accepted (a QR from the app is far shorter).
const MAX_LINK_LEN: usize = 512;
/// Most addresses taken from one link.
const MAX_ADDRESSES: usize = 8;

/// A QR code for the UI to draw: `size`×`size` modules, row by row, `1` =
/// dark. No quiet zone; the UI adds the margin.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PairQr {
    pub link: String,
    pub size: usize,
    pub modules: String,
}

/// What a scanned link says.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PairLink {
    pub code: String,
    pub addresses: Vec<SocketAddr>,
}

/// The link for `code` and the computer's LAN `addresses`.
pub fn build_link(code: &str, addresses: &[SocketAddr]) -> String {
    build(PREFIX, code, addresses)
}

/// The Jam's link for its `code` and the computer's LAN `addresses`.
pub fn build_jam_link(code: &str, addresses: &[SocketAddr]) -> String {
    build(JAM_PREFIX, code, addresses)
}

fn build(prefix: &str, code: &str, addresses: &[SocketAddr]) -> String {
    let list: Vec<String> = addresses
        .iter()
        .filter(|a| is_lan_address(a.ip()))
        .take(MAX_ADDRESSES)
        .map(SocketAddr::to_string)
        .collect();
    format!("{prefix}v={LINK_VERSION}&c={code}&a={}", list.join(","))
}

/// The QR code of `link` (error correction M: readable off a screen).
pub fn qr(link: &str) -> Option<PairQr> {
    let code = QrCode::with_error_correction_level(link.as_bytes(), EcLevel::M).ok()?;
    let size = code.width();
    let modules = code
        .to_colors()
        .into_iter()
        .map(|c| if c == Color::Dark { '1' } else { '0' })
        .collect();
    Some(PairQr {
        link: link.to_owned(),
        size,
        modules,
    })
}

/// Reads a scanned link. Refuses anything that is not a NeoModern pairing
/// link with a 6-digit code and at least one LAN address.
pub fn parse_link(text: &str) -> Result<PairLink, String> {
    parse(PREFIX, "this is not a NeoModern pairing code", text)
}

/// Reads a scanned Jam link, with the same rules as `parse_link`.
pub fn parse_jam_link(text: &str) -> Result<PairLink, String> {
    parse(JAM_PREFIX, "this is not a NeoModern Jam code", text)
}

fn parse(prefix: &str, not_ours: &str, text: &str) -> Result<PairLink, String> {
    let not_ours = || not_ours.to_owned();
    let text = text.trim();
    if text.len() > MAX_LINK_LEN {
        return Err(not_ours());
    }
    let query = text.strip_prefix(prefix).ok_or_else(not_ours)?;
    let (mut version, mut code, mut addrs) = (None, None, None);
    for pair in query.split('&') {
        let (key, value) = pair.split_once('=').ok_or_else(not_ours)?;
        match key {
            "v" => version = Some(value),
            "c" => code = Some(value),
            "a" => addrs = Some(value),
            // Fields a newer computer may add.
            _ => {}
        }
    }
    if version != Some(LINK_VERSION) {
        return Err("this pairing code is from a newer version: update the app".into());
    }
    let code = code
        .filter(|c| c.len() == 6 && c.bytes().all(|b| b.is_ascii_digit()))
        .ok_or_else(not_ours)?
        .to_owned();
    let addresses: Vec<SocketAddr> = addrs
        .unwrap_or("")
        .split(',')
        .filter(|a| !a.is_empty())
        .take(MAX_ADDRESSES)
        .filter_map(|a| a.parse::<SocketAddr>().ok())
        .filter(|a| is_lan_address(a.ip()) && a.port() != 0)
        .collect();
    if addresses.is_empty() {
        return Err("the code has no local network address of the computer".into());
    }
    Ok(PairLink { code, addresses })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn addr(s: &str) -> SocketAddr {
        s.parse().unwrap()
    }

    #[test]
    fn a_built_link_reads_back() {
        let addrs = [addr("192.168.1.20:47321"), addr("10.0.0.5:47321")];
        let link = build_link("012345", &addrs);
        assert_eq!(
            link,
            "neomodern://pair?v=1&c=012345&a=192.168.1.20:47321,10.0.0.5:47321"
        );
        assert_eq!(
            parse_link(&format!("  {link}\n")).unwrap(),
            PairLink {
                code: "012345".into(),
                addresses: addrs.to_vec()
            }
        );
    }

    #[test]
    fn public_addresses_never_go_into_or_come_out_of_a_link() {
        let link = build_link("111111", &[addr("8.8.8.8:47321"), addr("192.168.0.2:1")]);
        assert!(!link.contains("8.8.8.8"));
        let parsed = parse_link(
            "neomodern://pair?v=1&c=111111&a=8.8.8.8:47321,100.64.0.1:47321,[fe80::1]:47321",
        )
        .unwrap();
        assert_eq!(parsed.addresses, vec![addr("[fe80::1]:47321")]);
    }

    #[test]
    fn foreign_or_broken_links_are_refused() {
        for bad in [
            "",
            "https://example.com/?c=123456",
            "neomodern://pair?v=1&c=12345&a=192.168.1.2:47321",
            "neomodern://pair?v=1&c=abcdef&a=192.168.1.2:47321",
            "neomodern://pair?v=1&c=123456",
            "neomodern://pair?v=1&c=123456&a=8.8.8.8:47321",
            "neomodern://pair?v=1&c=123456&a=192.168.1.2:0",
            "neomodern://pair?c=123456&a=192.168.1.2:47321",
            "neomodern://pair?v=2&c=123456&a=192.168.1.2:47321",
            "neomodern://pair?v=1&novalue&c=123456&a=192.168.1.2:47321",
        ] {
            assert!(parse_link(bad).is_err(), "{bad}");
        }
        let long = format!(
            "neomodern://pair?v=1&c=123456&a=192.168.1.2:47321&x={}",
            "y".repeat(600)
        );
        assert!(parse_link(&long).is_err());
        // Unknown fields from a newer computer are fine.
        assert!(parse_link("neomodern://pair?v=1&c=123456&a=192.168.1.2:47321&n=Desk").is_ok());
    }

    #[test]
    fn jam_links_and_pairing_links_never_mix() {
        let addrs = [addr("192.168.1.20:47321")];
        let link = build_jam_link("012345", &addrs);
        assert_eq!(link, "neomodern://jam?v=1&c=012345&a=192.168.1.20:47321");
        assert_eq!(parse_jam_link(&link).unwrap().code, "012345");
        assert!(parse_link(&link).is_err());
        assert!(parse_jam_link(&build_link("012345", &addrs)).is_err());
        // The same address rules: no public address in or out.
        assert!(!build_jam_link("111111", &[addr("8.8.8.8:47321")]).contains("8.8.8.8"));
        assert!(parse_jam_link("neomodern://jam?v=1&c=123456&a=8.8.8.8:47321").is_err());
        assert!(parse_jam_link("neomodern://jam?v=2&c=123456&a=10.0.0.2:47321").is_err());
        assert!(parse_jam_link("neomodern://jam?v=1&c=12345&a=10.0.0.2:47321").is_err());
    }

    #[test]
    fn the_qr_code_is_square_and_complete() {
        let link = build_link("654321", &[addr("192.168.178.44:47321")]);
        let q = qr(&link).unwrap();
        assert!(q.size >= 21);
        assert_eq!(q.modules.len(), q.size * q.size);
        assert!(q.modules.bytes().all(|b| b == b'0' || b == b'1'));
        // Finder pattern: the top-left module is dark.
        assert_eq!(&q.modules[..1], "1");
    }
}
