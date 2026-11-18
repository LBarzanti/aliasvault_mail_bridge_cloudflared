use std::env;
use std::io::{BufRead, BufReader, Error, ErrorKind, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::thread;
use std::time::Duration;

const MAX_BYTES: usize = 26 * 1024 * 1024;

fn main() {
    let secret = env::var("WEBHOOK_SECRET").expect("missing WEBHOOK_SECRET");
    let listen = env::var("LISTEN").unwrap_or_else(|_| "127.0.0.1:8087".into());
    let smtp = env::var("SMTP_ADDR").unwrap_or_else(|_| "127.0.0.1:2525".into());
    let listener = TcpListener::bind(&listen).expect("bind failed");
    eprintln!("listening on... {listen}, SMTP to {smtp}");
    for stream in listener.incoming().flatten() {
        let (secret, smtp) = (secret.clone(), smtp.clone());
        thread::spawn(move || {
            let _ = handle(stream, &secret, &smtp);
        });
    }
}

fn reply(w: &mut TcpStream, code: u16, msg: &str) -> std::io::Result<()> {
    write!(
        w,
        "HTTP/1.1 {code} Status\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{msg}",
        msg.len()
    )
}

fn ct_eq(a: &[u8], b: &[u8]) -> bool {
    a.len() == b.len() && a.iter().zip(b).fold(0u8, |d, (x, y)| d | (x ^ y)) == 0
}

fn addr_ok(a: &str) -> bool {
    !a.is_empty() && a.len() <= 320 && a.bytes().all(|c| c.is_ascii_graphic() && c != b'<' && c != b'>')
}

fn handle(stream: TcpStream, secret: &str, smtp: &str) -> std::io::Result<()> {
    stream.set_read_timeout(Some(Duration::from_secs(30)))?;
    stream.set_write_timeout(Some(Duration::from_secs(30)))?;
    let mut out = stream.try_clone()?;
    let mut r = BufReader::new(stream);

    let mut line = String::new();
    r.read_line(&mut line)?;
    if !line.starts_with("POST ") {
        return reply(&mut out, 405, "method not allowed");
    }

    let mut len: Option<usize> = None;
    let mut chunked = false;
    let (mut tok, mut from, mut to) = (String::new(), String::new(), String::new());
    loop {
        line.clear();
        if r.read_line(&mut line)? == 0 {
            return Ok(());
        }
        let l = line.trim_end();
        if l.is_empty() {
            break;
        }
        if let Some((k, v)) = l.split_once(':') {
            let v = v.trim();
            match k.to_ascii_lowercase().as_str() {
                "content-length" => len = v.parse::<usize>().ok(),
                "transfer-encoding" => chunked = v.to_ascii_lowercase().contains("chunked"),
                "x-webhook-secret" => tok = v.to_string(),
                "x-mail-from" => from = v.to_string(),
                "x-mail-to" => to = v.to_string(),
                _ => {}
            }
        }
    }

    if !ct_eq(tok.as_bytes(), secret.as_bytes()) {
        let _ = discard_body(&mut r, len, chunked);
        return reply(&mut out, 401, "unauthorized");
    }
    if !addr_ok(&to) || !(from.is_empty() || addr_ok(&from)) {
        return reply(&mut out, 400, "bad address");
    }

    let body = if chunked {
        read_chunked(&mut r)?
    } else {
        let n = len.unwrap_or(0);
        if n == 0 || n > MAX_BYTES {
            return reply(&mut out, 413, "bad size");
        }
        let mut b = vec![0u8; n];
        r.read_exact(&mut b)?;
        b
    };

    match deliver(smtp, &from, &to, &body) {
        Ok(()) => {
            eprintln!("delivered {from} -> {to}");
            reply(&mut out, 200, "ok")
        }
        Err(e) => {
            eprintln!("error {from} -> {to}: {}", e.message);
            if e.permanent {
                reply(&mut out, 422, "permanent delivery failure")
            } else {
                reply(&mut out, 502, "temporary delivery failure")
            }
        }
    }
}

fn discard_body(
    r: &mut BufReader<TcpStream>,
    len: Option<usize>,
    chunked: bool,
) -> std::io::Result<()> {
    let mut buf = [0u8; 8192];
    if chunked {
        let mut total = 0usize;
        loop {
            let mut l = String::new();
            r.read_line(&mut l)?;
            let size = usize::from_str_radix(l.trim().split(';').next().unwrap_or("0"), 16)
                .map_err(|_| Error::new(ErrorKind::Other, "invalid chunk"))?;
            if size == 0 {
                loop {
                    l.clear();
                    if r.read_line(&mut l)? == 0 || l.trim().is_empty() {
                        return Ok(());
                    }
                }
            }
            if size > MAX_BYTES - total {
                return Ok(());
            }
            total += size;
            let mut remaining = size;
            while remaining > 0 {
                let n = remaining.min(buf.len());
                r.read_exact(&mut buf[..n])?;
                remaining -= n;
            }
            let mut crlf = [0u8; 2];
            r.read_exact(&mut crlf)?;
        }
    } else {
        let mut remaining = len.unwrap_or(0);
        if remaining > MAX_BYTES {
            return Ok(());
        }
        while remaining > 0 {
            let n = remaining.min(buf.len());
            r.read_exact(&mut buf[..n])?;
            remaining -= n;
        }
        Ok(())
    }
}

fn read_chunked(r: &mut BufReader<TcpStream>) -> std::io::Result<Vec<u8>> {
    let mut body = Vec::new();
    loop {
        let mut l = String::new();
        r.read_line(&mut l)?;
        let size = usize::from_str_radix(l.trim().split(';').next().unwrap_or("0"), 16)
            .map_err(|_| Error::new(ErrorKind::Other, "invalid chunk"))?;
        if size == 0 {
            loop {
                l.clear();
                if r.read_line(&mut l)? == 0 || l.trim().is_empty() {
                    break;
                }
            }
            return Ok(body);
        }
        if body.len() + size > MAX_BYTES {
            return Err(Error::new(ErrorKind::Other, "too big"));
        }
        let start = body.len();
        body.resize(start + size, 0);
        r.read_exact(&mut body[start..])?;
        let mut crlf = [0u8; 2];
        r.read_exact(&mut crlf)?;
    }
}

struct DeliveryError {
    permanent: bool,
    message: String,
}

fn temporary<E: std::fmt::Display>(e: E) -> DeliveryError {
    DeliveryError { permanent: false, message: e.to_string() }
}

fn expect(r: &mut BufReader<TcpStream>, class: &str) -> Result<(), DeliveryError> {
    loop {
        let mut l = String::new();
        if r.read_line(&mut l).map_err(temporary)? == 0 {
            return Err(temporary("connection closed"));
        }
        let last = l.as_bytes().get(3).map_or(true, |c| *c != b'-');
        if last {
            return if l.starts_with(class) {
                Ok(())
            } else {
                Err(DeliveryError {
                    permanent: l.starts_with('5'),
                    message: l.trim().to_string(),
                })
            };
        }
    }
}

fn cmd(w: &mut TcpStream, r: &mut BufReader<TcpStream>, c: &str, class: &str) -> Result<(), DeliveryError> {
    w.write_all(c.as_bytes()).map_err(temporary)?;
    expect(r, class)
}

fn deliver(smtp: &str, from: &str, to: &str, body: &[u8]) -> Result<(), DeliveryError> {
    let s = TcpStream::connect(smtp).map_err(temporary)?;
    s.set_read_timeout(Some(Duration::from_secs(60))).ok();
    s.set_write_timeout(Some(Duration::from_secs(60))).ok();
    let mut w = s.try_clone().map_err(temporary)?;
    let mut r = BufReader::new(s);

    expect(&mut r, "2")?;
    cmd(&mut w, &mut r, "EHLO bridge.local\r\n", "2")?;
    cmd(&mut w, &mut r, &format!("MAIL FROM:<{from}>\r\n"), "2")?;
    cmd(&mut w, &mut r, &format!("RCPT TO:<{to}>\r\n"), "2")?;
    cmd(&mut w, &mut r, "DATA\r\n", "3")?;

    let mut data = Vec::with_capacity(body.len() + 16);
    let mut line_start = true;
    for &b in body {
        if line_start && b == b'.' {
            data.push(b'.');
        }
        data.push(b);
        line_start = b == b'\n';
    }
    if !data.ends_with(b"\r\n") {
        data.extend_from_slice(b"\r\n");
    }
    data.extend_from_slice(b".\r\n");
    w.write_all(&data).map_err(temporary)?;
    expect(&mut r, "2")?;
    let _ = w.write_all(b"QUIT\r\n");
    Ok(())
}
