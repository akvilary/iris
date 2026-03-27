mod token;
mod lexer;
mod ast;
mod parser;
mod codegen;
mod error;

use std::env;
use std::fs;
use std::path::Path;
use std::process::Command;

use codegen::CodeGen;
use error::CompileResult;
use lexer::Lexer;
use parser::Parser;

fn compile_to_ast(source: &str) -> CompileResult<Vec<ast::Stmt>> {
    let mut lexer = Lexer::new(source);
    let tokens = lexer.tokenize()?;
    let mut parser = Parser::new(tokens);
    parser.parse()
}

fn compile_to_c(source: &str) -> CompileResult<String> {
    let stmts = compile_to_ast(source)?;
    let mut codegen = CodeGen::new();
    Ok(codegen.generate(&stmts))
}

fn build_binary(source: &str, input: &Path) -> CompileResult<String> {
    let c_code = compile_to_c(source)?;
    let c_path = input.with_extension("c");
    let bin_path = input.with_extension("");

    fs::write(&c_path, &c_code).map_err(|e| {
        error::CompileError::new(format!("cannot write {}: {}", c_path.display(), e), 0, 0)
    })?;

    let status = Command::new("cc")
        .args([
            c_path.to_str().unwrap(),
            "-o", bin_path.to_str().unwrap(),
        ])
        .status()
        .map_err(|e| error::CompileError::new(format!("cannot run cc: {}", e), 0, 0))?;

    let _ = fs::remove_file(&c_path);

    if !status.success() {
        return Err(error::CompileError::new("C compilation failed", 0, 0));
    }

    Ok(bin_path.to_str().unwrap().to_string())
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
    let path = Path::new(filename);

    let source = match fs::read_to_string(filename) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("error: cannot read {}: {}", filename, e);
            std::process::exit(1);
        }
    };

    let result = match command.as_str() {
        "tokens" => {
            let mut lexer = Lexer::new(&source);
            match lexer.tokenize() {
                Ok(tokens) => {
                    for tok in &tokens {
                        println!("{:4}:{:<3} {:?}", tok.line, tok.col, tok.kind);
                    }
                    Ok(())
                }
                Err(e) => Err(e),
            }
        }
        "parse" => {
            compile_to_ast(&source).map(|stmts| {
                for stmt in &stmts {
                    println!("{:#?}", stmt);
                }
            })
        }
        "emit" => {
            compile_to_c(&source).map(|c_code| print!("{}", c_code))
        }
        "build" => {
            build_binary(&source, path).map(|bin| println!("Built: {}", bin))
        }
        "run" => {
            match build_binary(&source, path) {
                Ok(bin) => {
                    let status = Command::new(&bin)
                        .status()
                        .map_err(|e| error::CompileError::new(
                            format!("cannot run {}: {}", bin, e), 0, 0,
                        ));
                    let _ = fs::remove_file(&bin);
                    match status {
                        Ok(s) => std::process::exit(s.code().unwrap_or(1)),
                        Err(e) => Err(e),
                    }
                }
                Err(e) => Err(e),
            }
        }
        _ => {
            eprintln!("Unknown command: {}", command);
            std::process::exit(1);
        }
    };

    if let Err(e) = result {
        eprintln!("{}", e);
        std::process::exit(1);
    }
}
