use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::TcpListener;

fn heavy_compute(seed: i64, n: usize) -> i64 {
    let mut x = seed;
    for _ in 0..n {
        x = x.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        x = x.wrapping_mul(x).wrapping_add(1);
    }
    (x % 1000000000).abs()
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
                let id_num: i64 = id.parse().unwrap_or(0);
                let result = heavy_compute(id_num, n);
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
    println!("Rust pathological server listening on port 6390");

    loop {
        let (stream, _) = listener.accept().await.unwrap();
        tokio::spawn(handle_client(stream));
    }
}
