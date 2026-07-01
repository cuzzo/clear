// Benchmark 24: TCP JSON File Server — Rust / Tokio
//
// Same protocol as server.clear / server.go:
//   SET:N  → generate JSON file data/N.json, respond +OK\r\n
//   GET:N  → read + parse JSON, respond :SUM\r\n
//   QUIT   → close connection
//   READY? → respond +READY\r\n

use serde::{Deserialize, Serialize};
use std::io::BufRead;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::TcpListener;

fn size_for_id(id: i64) -> i64 {
    ((id * 7 + 13) % 997) + 10
}

#[derive(Serialize, Deserialize)]
struct Doc {
    id: i64,
    data: Vec<i64>,
}

fn generate_json(id: i64) -> Vec<u8> {
    let sz = size_for_id(id);
    let data: Vec<i64> = (1..=sz).collect();
    let doc = Doc { id, data };
    serde_json::to_vec(&doc).unwrap()
}

fn parse_and_sum(content: &[u8]) -> i64 {
    let doc: Doc = match serde_json::from_slice(content) {
        Ok(d) => d,
        Err(_) => return 0,
    };
    doc.data.iter().sum()
}

async fn handle_client(stream: tokio::net::TcpStream) {
    let (reader, mut writer) = stream.into_split();
    let mut reader = BufReader::new(reader);
    let mut line = String::new();

    loop {
        line.clear();
        match reader.read_line(&mut line).await {
            Ok(0) | Err(_) => break,
            Ok(_) => {}
        }
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }

        if let Some(id_str) = trimmed.strip_prefix("SET:") {
            let id: i64 = id_str.parse().unwrap_or(0);
            let json = generate_json(id);
            let path = format!("data/{}.json", id);
            tokio::fs::write(&path, &json).await.unwrap_or(());
            writer.write_all(b"+OK\r\n").await.unwrap_or(());
        } else if let Some(id_str) = trimmed.strip_prefix("GET:") {
            let id: i64 = id_str.parse().unwrap_or(0);
            let path = format!("data/{}.json", id);
            match tokio::fs::read(&path).await {
                Ok(content) => {
                    let sum = parse_and_sum(&content);
                    let resp = format!(":{}\r\n", sum);
                    writer.write_all(resp.as_bytes()).await.unwrap_or(());
                }
                Err(_) => {
                    writer.write_all(b"-ERR file not found\r\n").await.unwrap_or(());
                }
            }
        } else if trimmed == "QUIT" {
            writer.write_all(b"+OK\r\n").await.unwrap_or(());
            break;
        } else if trimmed == "READY?" {
            writer.write_all(b"+READY\r\n").await.unwrap_or(());
        } else {
            writer.write_all(b"-ERR unknown command\r\n").await.unwrap_or(());
        }
    }
}

#[tokio::main]
async fn main() {
    tokio::fs::create_dir_all("data").await.unwrap();
    let listener = TcpListener::bind("0.0.0.0:6390").await.unwrap();
    println!("Rust json-api listening on port 6390");

    loop {
        let (stream, _) = listener.accept().await.unwrap();
        tokio::spawn(handle_client(stream));
    }
}
