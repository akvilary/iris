mod token;
mod lexer;
mod ast;
mod parser;
mod codegen;

use std::env;
use std::fs;
use std::process::Command;

use lexer::Lexer;
use parser::Parser;
use codegen::CodeGen;

fn compile(source: &str, filename: &str) -> String {
    let mut lexer = Lexer::new(source);
    let tokens = lexer.tokenize();
    let mut parser = Parser::new(tokens);
    let stmts = parser.parse();
    let mut codegen = CodeGen::new();
    let c_code = codegen.generate(&stmts);

    // Write C file
    let c_filename = filename.replace(".is", ".c");
    fs::write(&c_filename, &c_code).expect("Failed to write C file");

    c_filename
}

fn main() {
    let args: Vec<String> = env::args().collect();

    if args.len() < 3 {
        eprintln!("Usage: irisc <command> <file.is>");
        eprintln!("Commands: build, run, tokens, parse, emit");
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
        "emit" => {
            let mut lexer = Lexer::new(&source);
            let tokens = lexer.tokenize();
            let mut parser = Parser::new(tokens);
            let stmts = parser.parse();
            let mut codegen = CodeGen::new();
            let c_code = codegen.generate(&stmts);
            println!("{}", c_code);
        }
        "build" => {
            let c_filename = compile(&source, filename);
            let out_filename = filename.replace(".is", "");

            let status = Command::new("cc")
                .args([&c_filename, "-o", &out_filename])
                .status()
                .expect("Failed to run C compiler");

            if !status.success() {
                eprintln!("C compilation failed");
                std::process::exit(1);
            }

            // Clean up C file
            let _ = fs::remove_file(&c_filename);
            println!("Built: {}", out_filename);
        }
        "run" => {
            let c_filename = compile(&source, filename);
            let out_filename = filename.replace(".is", "");

            let status = Command::new("cc")
                .args([&c_filename, "-o", &out_filename])
                .status()
                .expect("Failed to run C compiler");

            if !status.success() {
                eprintln!("C compilation failed");
                std::process::exit(1);
            }

            // Clean up C file
            let _ = fs::remove_file(&c_filename);

            // Run the binary
            let status = Command::new(&format!("./{}", out_filename))
                .status()
                .expect("Failed to run binary");

            // Clean up binary
            let _ = fs::remove_file(&out_filename);

            std::process::exit(status.code().unwrap_or(1));
        }
        _ => {
            eprintln!("Unknown command: {}", command);
            std::process::exit(1);
        }
    }
}
