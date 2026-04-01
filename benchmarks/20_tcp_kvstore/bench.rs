// TCP KV Store — Rust/Tokio baseline
//
// Minimal RESP-compatible GET/SET/INCR server using DashMap.
// One Tokio task per connection. Supports pipelining.

use dashmap::DashMap;
use std::sync::Arc;
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::TcpListener;

struct State {
    store: DashMap<String, String>,
    counters: DashMap<String, i64>,
}

async fn handle_client(stream: tokio::net::TcpStream, state: Arc<State>) {
    let (rd, mut wr) = stream.into_split();
    let mut reader = BufReader::new(rd);
    let mut line_buf = String::new();

    loop {
        line_buf.clear();
        match reader.read_line(&mut line_buf).await {
            Ok(0) => return,
            Err(_) => return,
            _ => {}
        }
        let line = line_buf.trim_end_matches(&['\r', '\n'][..]);
        if line.is_empty() {
            continue;
        }

        if line.starts_with('*') {
            let arg_count: usize = line[1..].parse().unwrap_or(0);
            let mut args = Vec::with_capacity(arg_count);
            for _ in 0..arg_count {
                let mut hdr = String::new();
                if reader.read_line(&mut hdr).await.is_err() {
                    return;
                }
                let hdr = hdr.trim_end_matches(&['\r', '\n'][..]);
                if !hdr.starts_with('$') {
                    continue;
                }
                let n: usize = hdr[1..].parse().unwrap_or(0);
                let mut buf = vec![0u8; n + 2];
                if reader.read_exact(&mut buf).await.is_err() {
                    return;
                }
                args.push(String::from_utf8_lossy(&buf[..n]).to_string());
            }
            if args.is_empty() {
                continue;
            }
            let cmd = args[0].to_uppercase();
            let resp = match cmd.as_str() {
                "SET" if args.len() >= 3 => {
                    state.store.insert(args[1].clone(), args[2].clone());
                    "+OK\r\n".to_string()
                }
                "GET" if args.len() >= 2 => {
                    match state.store.get(&args[1]) {
                        Some(v) => format!("${}\r\n{}\r\n", v.len(), v.value()),
                        None => "$-1\r\n".to_string(),
                    }
                }
                "INCR" if args.len() >= 2 => {
                    let mut entry = state.counters.entry(args[1].clone()).or_insert(0);
                    *entry += 1;
                    format!(":{}\r\n", *entry)
                }
                "DECR" if args.len() >= 2 => {
                    let mut entry = state.counters.entry(args[1].clone()).or_insert(0);
                    *entry -= 1;
                    format!(":{}\r\n", *entry)
                }
                "PING" => "+PONG\r\n".to_string(),
                "COMMAND" => "*0\r\n".to_string(),
                "QUIT" => {
                    let _ = wr.write_all(b"+OK\r\n").await;
                    return;
                }
                _ => format!("-ERR unknown command '{}'\r\n", args[0]),
            };
            if wr.write_all(resp.as_bytes()).await.is_err() {
                return;
            }
        } else {
            let cmd = line.trim();
            let resp = match cmd.to_uppercase().as_str() {
                "PING" => "+PONG\r\n",
                "READY?" => "+READY\r\n",
                "QUIT" => {
                    let _ = wr.write_all(b"+OK\r\n").await;
                    return;
                }
                _ => "-ERR unknown command\r\n",
            };
            if wr.write_all(resp.as_bytes()).await.is_err() {
                return;
            }
        }
    }
}

#[tokio::main]
async fn main() {
    let listener = TcpListener::bind("0.0.0.0:6390").await.unwrap();
    println!("Rust kvstore listening on port 6390");
    let state = Arc::new(State {
        store: DashMap::new(),
        counters: DashMap::new(),
    });
    loop {
        let (stream, _) = listener.accept().await.unwrap();
        let state = Arc::clone(&state);
        tokio::spawn(handle_client(stream, state));
    }
}
