use std::{
    env,
    io::{self, BufRead, Write},
};

fn main() {
    let mut args = env::args().skip(1);
    match args.next().as_deref() {
        Some("dispatch") => {
            let request = args.collect::<Vec<_>>().join(" ");
            if request.trim().is_empty() {
                fail("dispatch requires one JSON command");
            }
            println!("{}", lanzouyou_core::dispatch_json(&request));
        }
        Some("serve") | None => serve(),
        Some("--help") | Some("-h") | Some("help") => print_help(),
        Some(other) => fail(&format!("unknown command: {other}")),
    }
}

fn serve() {
    let stdin = io::stdin();
    let mut stdout = io::BufWriter::new(io::stdout().lock());
    for line in stdin.lock().lines() {
        let line = match line {
            Ok(line) => line,
            Err(error) => fail(&format!("stdin read failed: {error}")),
        };
        if line.trim().is_empty() {
            continue;
        }
        let response = lanzouyou_core::dispatch_json(&line);
        if writeln!(stdout, "{response}")
            .and_then(|_| stdout.flush())
            .is_err()
        {
            std::process::exit(2);
        }
    }
}

fn print_help() {
    println!("lanzouyou [serve|dispatch <json>]\n\nserve reads one Rust-core JSON command per stdin line and writes one response per line.");
}

fn fail(message: &str) -> ! {
    eprintln!("lanzouyou: {message}");
    std::process::exit(2);
}
