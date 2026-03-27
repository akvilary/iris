mod token;
mod lexer;
mod ast;
mod parser;

use std::env;
use std::fs;

use lexer::Lexer;
use parser::Parser;

fn main() {
    let args: Vec<String> = env::args().collect();

    if args.len() < 3 {
        eprintln!("Usage: irisc <command> <file.is>");
        eprintln!("Commands: build, run, tokens, parse");
        std::process::exit(1);
    }

    let command = &args[1];
    let filename = &args[2];

    let source = match fs::read_to_string(filename) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("Error reading {}: {}", filename, e);
            std::process::exit(1);
        }
    };

    match command.as_str() {
        "tokens" => {
            let mut lexer = Lexer::new(&source);
            let tokens = lexer.tokenize();
            for tok in &tokens {
                println!("{:4}:{:<3} {:?}", tok.line, tok.col, tok.kind);
            }
        }
        "parse" => {
            let mut lexer = Lexer::new(&source);
            let tokens = lexer.tokenize();
            let mut parser = Parser::new(tokens);
            let stmts = parser.parse();
            for stmt in &stmts {
                println!("{:#?}", stmt);
            }
        }
        "build" | "run" => {
            eprintln!("Not implemented yet. Use 'tokens' or 'parse' to test.");
        }
        _ => {
            eprintln!("Unknown command: {}", command);
            std::process::exit(1);
        }
    }
}
