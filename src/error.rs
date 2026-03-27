/// Compiler error types for the Iris language

#[derive(Debug, Clone)]
pub struct CompileError {
    pub message: String,
    pub line: usize,
    pub col: usize,
}

impl CompileError {
    pub fn new(message: impl Into<String>, line: usize, col: usize) -> Self {
        CompileError { message: message.into(), line, col }
    }
}

impl std::fmt::Display for CompileError {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        if self.line > 0 {
            write!(f, "{}:{}: error: {}", self.line, self.col, self.message)
        } else {
            write!(f, "error: {}", self.message)
        }
    }
}

impl std::error::Error for CompileError {}

pub type CompileResult<T> = Result<T, CompileError>;
