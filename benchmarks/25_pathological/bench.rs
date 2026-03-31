use sha2::{Sha256, Digest};
use std::fmt::Write as FmtWrite;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::TcpListener;

fn hash_n(seed: &str, n: usize) -> String {
    let mut buf = Sha256::digest(seed.as_bytes());
    for _ in 1..n {
        buf = Sha256::digest(&buf);
    }
    let mut hex = String::with_capacity(16);
    for b in &buf[..8] {
        write!(hex, "{:02x}", b).unwrap();
    }
    hex
}

async fn handle_client(stream: tokio::net::TcpStream) {
    let (reader, mut writer) = stream.into_split();
    let mut lines = BufReader::new(reader).lines();

    while let Ok(Some(line)) = lines.next_line().await {
        let line = line.trim().to_string();
        if line.is_empty() {
            continue;
        }

        if line.starts_with("WORK:") {
            let rest = &line[5..];
            if let Some((id, n_str)) = rest.split_once(':') {
                let n: usize = n_str.parse().unwrap_or(1).max(1);
                let seed = format!("seed:{}", id);
                let result = hash_n(&seed, n);
                let resp = format!(":{}\r\n", result);
                let _ = writer.write_all(resp.as_bytes()).await;
            } else {
                let _ = writer.write_all(b"-ERR bad format\r\n").await;
            }
        } else if line == "QUIT" {
            let _ = writer.write_all(b"+OK\r\n").await;
            return;
        } else if line == "READY?" {
            let _ = writer.write_all(b"+READY\r\n").await;
        } else {
            let _ = writer.write_all(b"-ERR unknown command\r\n").await;
        }
    }
}

#[tokio::main]
async fn main() {
    let listener = TcpListener::bind("0.0.0.0:6390").await.unwrap();
    println!("Rust pathological server listening on port 6391");

    loop {
        let (stream, _) = listener.accept().await.unwrap();
        tokio::spawn(handle_client(stream));
    }
}
